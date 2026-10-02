import Foundation
@testable import iSCSIVolume

/// An in-memory cache file that can be told to fail or to tamper, and that
/// records what it was asked to do. Reads are served at the offsets writes
/// were made at, which is all the tier ever does.
final class MemoryChunkFile: ChunkFile, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [Int64: Data] = [:]
    private var writeCount = 0
    private var readCount = 0
    private var wasDiscarded = false
    var failWrites = false
    var failReads = false
    /// Flip the first byte of everything read.
    var tamper = false
    /// Runs at the start of every read, outside this file's lock — for
    /// interleaving another operation into the middle of a lookup.
    var onRead: (() -> Void)?

    var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var discarded: Bool { lock.lock(); defer { lock.unlock() }; return wasDiscarded }
    /// One past the last byte ever written.
    var extent: Int64 {
        lock.lock(); defer { lock.unlock() }
        return blobs.map { $0.key + Int64($0.value.count) }.max() ?? 0
    }
    /// Whether any blob holds `needle` verbatim.
    func stores(_ needle: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blobs.values.contains { $0.range(of: needle) != nil }
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        onRead?()
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        if failReads { throw POSIXError(.EIO) }
        guard let blob = blobs[offset], blob.count >= count else { throw POSIXError(.EIO) }
        var data = Data(blob.prefix(count))
        if tamper, !data.isEmpty { data[data.startIndex] ^= 0xFF }
        return data
    }

    func write(_ data: Data, at offset: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw POSIXError(.ENOSPC) }
        writeCount += 1
        blobs[offset] = Data(data)
    }

    func discard() {
        lock.lock(); defer { lock.unlock() }
        wasDiscarded = true
        blobs.removeAll()
    }
}
