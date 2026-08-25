import Foundation
import iSCSIKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Where committed blocks live.
public enum TargetBacking: Sendable {
    /// Everything in the process's address space. Fast, and the capacity has
    /// to fit in RAM.
    case memory
    /// A sparse file, so a LUN can be far larger than memory.
    case file(path: String)
}

public enum TargetDiskError: Error, Sendable {
    case cannotOpen(path: String, errno: Int32)
    case cannotSize(path: String, errno: Int32)
}

/// The simulated LUN: committed storage plus a **volatile write cache** —
/// the cache is the point. With `WCE=1` a write is acknowledged from cache;
/// only FUA and SYNCHRONIZE CACHE reach stable media, and `crash()` throws
/// the cache away like a target power cut.
///
/// Deliberate choices: nothing writes back on its own (deterministic crash
/// tests beat realistic ones; `maxDirtyBytes` exists only to bound a long
/// non-FUA soak and bumps `pressureCommits` so tests can assert a clean
/// window), and the cache answers reads (volatile is not invisible — a read
/// missing a cached write looks like corruption). "Stable media" means the
/// backing store as this process sees it; model power loss with `crash()`,
/// not by killing the process.
public actor RAMDisk {
    public let blockSize: Int
    public let capacityBlocks: UInt64

    /// `.memory` backing.
    private var storage: Data
    /// `.file` backing; -1 when in memory.
    private let fd: Int32

    /// Volatile write cache: LBA → one block. Writes without FUA land here.
    private var dirty: [UInt64: Data] = [:]
    private let maxDirtyBlocks: Int

    public private(set) var flushCount = 0
    public private(set) var fuaWrites = 0
    public private(set) var cachedWrites = 0
    public private(set) var crashCount = 0
    public private(set) var blocksLostToCrash = 0
    /// Commits forced by `maxDirtyBytes` rather than by the initiator.
    public private(set) var pressureCommits = 0

    public init(
        blockSize: Int = 512,
        capacityBlocks: UInt64 = 8192,
        maxDirtyBytes: Int = 256 << 20
    ) {
        self.blockSize = blockSize
        self.capacityBlocks = capacityBlocks
        self.storage = Data(count: blockSize * Int(capacityBlocks))
        self.fd = -1
        self.maxDirtyBlocks = max(1, maxDirtyBytes / blockSize)
    }

    /// File-backed LUN. The file is created if absent and sized to capacity;
    /// on APFS that costs nothing until blocks are written.
    public init(
        blockSize: Int,
        capacityBlocks: UInt64,
        filePath: String,
        maxDirtyBytes: Int = 256 << 20
    ) throws {
        self.blockSize = blockSize
        self.capacityBlocks = capacityBlocks
        self.storage = Data()
        self.maxDirtyBlocks = max(1, maxDirtyBytes / blockSize)
        let handle = open(filePath, O_RDWR | O_CREAT, 0o600)
        guard handle >= 0 else {
            throw TargetDiskError.cannotOpen(path: filePath, errno: errno)
        }
        let wanted = off_t(capacityBlocks * UInt64(blockSize))
        var info = stat()
        if fstat(handle, &info) == 0, info.st_size < wanted {
            guard ftruncate(handle, wanted) == 0 else {
                let code = errno
                close(handle)
                throw TargetDiskError.cannotSize(path: filePath, errno: code)
            }
        }
        self.fd = handle
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    // MARK: - Block access

    public func read(lba: UInt64, blocks: UInt32) -> Data? {
        guard lba + UInt64(blocks) <= capacityBlocks else { return nil }
        guard blocks > 0 else { return Data() }
        var out = readCommitted(lba: lba, blocks: blocks)
        if !dirty.isEmpty {
            for i in 0 ..< UInt64(blocks) {
                if let block = dirty[lba + i] {
                    out.setSub(block, Int(i) * blockSize)
                }
            }
        }
        return out
    }

    /// `fua` defaults to true so anything calling this directly (tests, setup
    /// code) gets durable data without having to think about the cache.
    @discardableResult
    public func write(lba: UInt64, data: Data, fua: Bool = true) -> Bool {
        guard data.count % blockSize == 0,
              lba + UInt64(data.count / blockSize) <= capacityBlocks else { return false }
        let blocks = data.count / blockSize
        if fua {
            writeCommitted(lba: lba, data)
            // Drop any cached copy of these blocks, or the next flush would
            // resurrect the stale version over the one we just committed.
            if !dirty.isEmpty {
                for i in 0 ..< UInt64(blocks) { dirty.removeValue(forKey: lba + i) }
            }
            fuaWrites += 1
        } else {
            for i in 0 ..< blocks {
                dirty[lba + UInt64(i)] = data.sub(i * blockSize, blockSize)
            }
            cachedWrites += 1
            if dirty.count > maxDirtyBlocks {
                pressureCommits += 1
                commitDirty()
            }
        }
        return true
    }

    // MARK: - Cache lifecycle

    /// SYNCHRONIZE CACHE: everything acknowledged so far becomes durable.
    public func flush() {
        flushCount += 1
        commitDirty()
    }

    /// Older name kept because the counter it bumps is asserted in tests.
    public func recordFlush() { flush() }

    /// Target power loss: the cache evaporates, committed blocks survive.
    /// Returns how many blocks were lost.
    @discardableResult
    public func crash() -> Int {
        let lost = dirty.count
        dirty.removeAll()
        crashCount += 1
        blocksLostToCrash += lost
        return lost
    }

    /// Orderly restart: nothing is lost, but the cache is empty afterwards.
    public func reboot() {
        commitDirty()
    }

    public var dirtyBlocks: Int { dirty.count }

    private func commitDirty() {
        guard !dirty.isEmpty else { return }
        // Coalesce runs of consecutive LBAs: a cached megabyte is one write to
        // the backing store rather than 256 of them.
        let lbas = dirty.keys.sorted()
        var runStart = lbas[0]
        var expected = lbas[0]
        var run = Data()
        for lba in lbas {
            if lba != expected {
                writeCommitted(lba: runStart, run)
                run.removeAll(keepingCapacity: true)
                runStart = lba
            }
            run.append(dirty[lba]!)
            expected = lba + 1
        }
        if !run.isEmpty { writeCommitted(lba: runStart, run) }
        dirty.removeAll()
    }

    // MARK: - Backing store

    private func readCommitted(lba: UInt64, blocks: UInt32) -> Data {
        let count = Int(blocks) * blockSize
        if fd < 0 { return storage.sub(Int(lba) * blockSize, count) }
        // Zero-filled to start with, so a short read off the end of a sparse
        // file yields the hole's zeros rather than garbage.
        var out = Data(count: count)
        let base = off_t(lba * UInt64(blockSize))
        out.withUnsafeMutableBytes { raw in
            guard let address = raw.baseAddress else { return }
            var done = 0
            while done < count {
                let n = pread(fd, address.advanced(by: done), count - done, base + off_t(done))
                if n <= 0 { break }
                done += n
            }
        }
        return out
    }

    private func writeCommitted(lba: UInt64, _ data: Data) {
        if fd < 0 {
            storage.setSub(data, Int(lba) * blockSize)
            return
        }
        let base = off_t(lba * UInt64(blockSize))
        data.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else { return }
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, address.advanced(by: done), raw.count - done, base + off_t(done))
                if n <= 0 { break }
                done += n
            }
        }
    }
}
