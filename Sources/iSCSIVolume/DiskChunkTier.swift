//
//  DiskChunkTier.swift
//
//  The local disk cache: a second tier under `PrefetchChunkCache`, holding
//  chunks the RAM tier evicted after they were read. Session-scoped,
//  encrypted, and never a reason for a read to fail. Design and rationale:
//  docs/superpowers/specs/2026-10-02-local-disk-cache-design.md.
//

import CryptoKit
import Foundation

/// Positional I/O on the cache file. Injectable so tests can fail or tamper
/// with it; the real one is `UnlinkedFile`.
protocol ChunkFile: AnyObject, Sendable {
    /// Exactly `count` bytes at `offset`, or a throw.
    func read(at offset: Int64, count: Int) throws -> Data
    func write(_ data: Data, at offset: Int64) throws
    /// Give the space back. Called once, when the tier disables itself;
    /// reads after it fail, which the tier already treats as a miss.
    func discard()
}

/// A file that exists only as an open descriptor: created under a random
/// name and unlinked at once, so a detach, an exit or a crash all return its
/// space, and nothing is ever left behind to sweep.
final class UnlinkedFile: ChunkFile, @unchecked Sendable {
    private let fd: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("chunks-\(UUID().uuidString)").path
        let opened = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { throw Self.posixError() }
        unlink(path)
        // The tier sits under the buffer cache; caching its file there too
        // would spend RAM twice on one chunk.
        _ = fcntl(opened, F_NOCACHE, 1)
        fd = opened
    }

    deinit { close(fd) }

    func read(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n == count else { throw n < 0 ? Self.posixError() : POSIXError(.EIO) }
        return data
    }

    func write(_ data: Data, at offset: Int64) throws {
        let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        guard n == data.count else { throw n < 0 ? Self.posixError() : POSIXError(.EIO) }
    }

    func discard() { _ = ftruncate(fd, 0) }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
    }
}

/// Chunks on local disk, keyed by their LUN offset. Bytes arrive only by
/// `spill` — from the RAM tier, so they have already passed its write
/// generation guard — and leave by eviction, by `invalidate` (every write, at
/// both edges), or by failing authentication.
///
/// Each slot is `chunkBytes` of AES-GCM ciphertext and its 16-byte tag in a
/// page of its own. The key lives only in this object; the nonce is the slot
/// number and a per-tier seal counter, so it never repeats under the key; the
/// chunk's offset and length are the additional authenticated data, so a slot
/// read for the wrong chunk fails authentication instead of returning bytes.
public final class DiskChunkTier: @unchecked Sendable {

    public struct Stats: Sendable, Equatable {
        /// Fetches that consulted the tier, and those it served.
        public var lookups = 0
        public var hits = 0
        /// Bytes served from disk instead of fetched.
        public var savedBytes: UInt64 = 0
        /// Chunks written to the tier.
        public var spilled = 0
        /// Chunks that failed authentication.
        public var corrupt = 0
        /// Why the tier turned itself off, if it did.
        public var disabledReason: String?
    }

    /// Why no tier was made at attach. The volume mounts without one.
    enum Unavailable: Error, Equatable, CustomStringConvertible {
        case tooLittleSpace(availableBytes: Int64)
        case cannotCreate(String)

        var description: String {
            switch self {
            case .tooLittleSpace(let available): "space (\(available >> 30) GiB free)"
            case .cannotCreate(let why): "create (\(why))"
            }
        }
    }

    /// Bytes per slot beyond the chunk: the 16-byte GCM tag, in a page of its
    /// own so chunk data stays page-aligned.
    static let tagRoom = 4096
    /// Free space never handed to the tier.
    static let reserveBytes: Int64 = 10 << 30
    /// Below this, a tier is not worth its bookkeeping.
    static let minimumBytes = 1 << 30

    let chunkBytes: Int
    let slotCount: Int
    private let stride: Int
    private let file: ChunkFile
    private let key = SymmetricKey(size: .bits256)
    private let spillQueue: DispatchQueue

    private struct Slot {
        let index: Int
        let nonce: AES.GCM.Nonce
        let length: Int
        /// Unique per seal: tells a reader whether its slot was reused.
        let version: UInt64
    }

    private let lock = NSLock()
    private var slots: [UInt64: Slot] = [:]
    private var order: SegmentedLRU<UInt64>
    private var freeSlots: [Int]
    /// Chunk offset → ticket of the spill queued for it. `invalidate` removes
    /// the ticket; a queued spill lands only if its ticket is still current.
    private var tickets: [UInt64: UInt64] = [:]
    private var nextTicket: UInt64 = 0
    private var sealCount: UInt64 = 0
    private var statsStore = Stats()

    /// Chunk data the tier can hold.
    var capacityBytes: Int { slotCount * chunkBytes }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return statsStore
    }

    init(file: ChunkFile, budgetBytes: Int, chunkBytes: Int,
         spillQueue: DispatchQueue = DispatchQueue(label: "me.herko.iSCSIInitiator.fsext.spill",
                                                    qos: .utility)) {
        precondition(chunkBytes > 0)
        self.file = file
        self.chunkBytes = chunkBytes
        stride = chunkBytes + Self.tagRoom
        slotCount = max(1, budgetBytes / stride)
        freeSlots = Array((0 ..< slotCount).reversed())
        order = SegmentedLRU(protectedCapacity: slotCount * 4 / 5)
        self.spillQueue = spillQueue
    }

    /// The tier for an attach: an unlinked file under `directory`, sized to
    /// `min(budget, free space − reserve)`. A failure is a reason to log, never
    /// a reason to fail the mount.
    static func make(directory: URL, budgetBytes: Int, chunkBytes: Int,
                     freeSpace: (URL) -> Int64? = DiskChunkTier.freeSpace)
        -> Result<DiskChunkTier, Unavailable> {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.cannotCreate("\(error)"))
        }
        let available = freeSpace(directory) ?? 0
        let usable = min(Int64(budgetBytes), available - reserveBytes)
        guard usable >= Int64(minimumBytes) else {
            return .failure(.tooLittleSpace(availableBytes: available))
        }
        do {
            let file = try UnlinkedFile(directory: directory)
            return .success(DiskChunkTier(file: file, budgetBytes: Int(usable), chunkBytes: chunkBytes))
        } catch {
            return .failure(.cannotCreate("\(error)"))
        }
    }

    /// Bytes available to an unprivileged writer on the volume holding `url`.
    static func freeSpace(_ url: URL) -> Int64? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }

    // MARK: - Spill

    /// A chunk the RAM tier evicted after it was read. Records a ticket and
    /// writes it on the spill queue. Nothing to do if it is already on disk —
    /// unchanged since, because any write would have invalidated it — or
    /// already queued.
    func spill(offset: UInt64, data: Data) {
        lock.lock()
        guard statsStore.disabledReason == nil, !data.isEmpty, data.count <= chunkBytes,
              slots[offset] == nil, tickets[offset] == nil else {
            lock.unlock()
            return
        }
        nextTicket &+= 1
        let ticket = nextTicket
        tickets[offset] = ticket
        lock.unlock()
        spillQueue.async { self.store(offset: offset, data: data, ticket: ticket) }
    }

    private func store(offset: UInt64, data: Data, ticket: UInt64) {
        lock.lock()
        guard tickets[offset] == ticket, statsStore.disabledReason == nil else {
            lock.unlock()
            return
        }
        if freeSlots.isEmpty, let victim = order.evict(),
           let freed = slots.removeValue(forKey: victim) {
            freeSlots.append(freed.index)
        }
        guard let index = freeSlots.popLast() else {
            tickets[offset] = nil
            lock.unlock()
            return
        }
        sealCount &+= 1
        let seal = sealCount
        lock.unlock()

        let nonce = Self.nonce(slot: index, seal: seal)
        do {
            let sealed = try AES.GCM.seal(data, using: key, nonce: nonce,
                                          authenticating: Self.aad(offset: offset, length: data.count))
            let base = Int64(index) * Int64(stride)
            try file.write(sealed.ciphertext, at: base)
            try file.write(sealed.tag, at: base + Int64(chunkBytes))
        } catch {
            disable("write failed: \(error)")
            return
        }

        lock.lock()
        if tickets[offset] == ticket, statsStore.disabledReason == nil {
            tickets[offset] = nil
            slots[offset] = Slot(index: index, nonce: nonce, length: data.count, version: seal)
            order.insert(offset)
            statsStore.spilled += 1
        } else if statsStore.disabledReason == nil {
            // Invalidated while it was being written: the bytes are stale.
            freeSlots.append(index)
        }
        lock.unlock()
    }

    // MARK: - Lookup

    /// The bytes of `[offset, offset + length)` if every chunk of it is on
    /// disk and authentic, nil otherwise — never an error. `offset` is
    /// chunk-aligned, as every fetch the RAM tier makes is.
    func lookup(offset: UInt64, length: Int) -> Data? {
        guard length > 0 else { return nil }
        let chunk = UInt64(chunkBytes)
        let end = offset &+ UInt64(length)
        var wanted: [(offset: UInt64, slot: Slot)] = []

        lock.lock()
        guard statsStore.disabledReason == nil else {
            lock.unlock()
            return nil
        }
        statsStore.lookups += 1
        var co = offset
        while co < end {
            let clen = Int(min(chunk, end - co))
            guard let slot = slots[co], slot.length == clen else {
                lock.unlock()
                return nil
            }
            wanted.append((co, slot))
            co += chunk
        }
        lock.unlock()

        var out = Data(capacity: length)
        for (co, slot) in wanted {
            let base = Int64(slot.index) * Int64(stride)
            let ciphertext: Data
            let tag: Data
            do {
                ciphertext = try file.read(at: base, count: slot.length)
                tag = try file.read(at: base + Int64(chunkBytes), count: 16)
            } catch {
                disable("read failed: \(error)")
                return nil
            }
            guard let box = try? AES.GCM.SealedBox(nonce: slot.nonce, ciphertext: ciphertext, tag: tag),
                  let plain = try? AES.GCM.open(box, using: key,
                                                authenticating: Self.aad(offset: co, length: slot.length))
            else {
                notAuthentic(co, slot)
                return nil
            }
            out.append(plain)
        }

        lock.lock()
        statsStore.hits += 1
        statsStore.savedBytes += UInt64(length)
        for (co, slot) in wanted where slots[co]?.version == slot.version { order.hit(co) }
        lock.unlock()
        return out
    }

    /// Authentication failed. If the slot still belongs to this chunk at this
    /// version, the bytes really are bad: free and count it. If it changed —
    /// evicted and reused mid-read — it is a plain miss, and the new owner's
    /// slot must not be touched.
    private func notAuthentic(_ co: UInt64, _ slot: Slot) {
        lock.lock()
        if let current = slots[co], current.version == slot.version {
            slots[co] = nil
            order.remove(co)
            freeSlots.append(slot.index)
            statsStore.corrupt += 1
        }
        lock.unlock()
    }

    // MARK: - Invalidation

    /// Forget every chunk overlapping `[offset, offset + length)` and cancel
    /// any spill queued for one. Synchronous: no read after this returns can
    /// find the old bytes.
    func invalidate(offset: UInt64, length: Int) {
        guard length > 0 else { return }
        let chunk = UInt64(chunkBytes)
        let end = offset &+ UInt64(length)
        lock.lock()
        var co = (offset / chunk) * chunk
        while co < end {
            tickets[co] = nil
            if let slot = slots.removeValue(forKey: co) {
                order.remove(co)
                freeSlots.append(slot.index)
            }
            co += chunk
        }
        lock.unlock()
    }

    // MARK: - Failure

    /// Turn the tier off for the rest of the session: forget everything, give
    /// the file's space back, log once. Every later lookup misses without
    /// touching the file.
    private func disable(_ reason: String) {
        lock.lock()
        let first = statsStore.disabledReason == nil
        if first {
            statsStore.disabledReason = reason
            slots.removeAll()
            tickets.removeAll()
            freeSlots.removeAll()
            order = SegmentedLRU(protectedCapacity: 0)
        }
        lock.unlock()
        guard first else { return }
        file.discard()
        fsLog.error("local cache disabled: \(reason, privacy: .public); reads go to the network")
    }

    // MARK: - Crypto framing

    private static func nonce(slot: Int, seal: UInt64) -> AES.GCM.Nonce {
        let bytes = withUnsafeBytes(of: UInt32(truncatingIfNeeded: slot).bigEndian, Array.init)
            + withUnsafeBytes(of: seal.bigEndian, Array.init)
        // 12 bytes is always a valid GCM nonce.
        return try! AES.GCM.Nonce(data: bytes)
    }

    private static func aad(offset: UInt64, length: Int) -> Data {
        Data(withUnsafeBytes(of: offset.bigEndian, Array.init)
             + withUnsafeBytes(of: UInt64(length).bigEndian, Array.init))
    }
}
