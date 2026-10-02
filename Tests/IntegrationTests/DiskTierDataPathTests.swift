import Foundation
import Testing
@testable import iSCSIKit
@testable import iSCSIVolume

/// The disk tier inside the real volume data path, against the in-memory
/// daemon: what reaches the "network", and whether every byte read back is
/// the byte last written.
@Suite("Disk tier in the volume data path", .timeLimit(.minutes(1)))
struct DiskTierDataPathTests {

    private static let blockSize: UInt64 = 4096
    private static let chunk = 256 << 10
    private static let capacity = 32 * chunk          // 8 MiB

    private struct Rig {
        let store: DaemonStore
        let daemon: FakeDaemon
        let tier: DiskChunkTier
        let file: MemoryChunkFile
        let spills: DispatchQueue
        func drain() { spills.sync {} }
        var daemonReads: Int { daemon.log.filter { $0.kind == "read" }.count }
    }

    /// RAM tier of two chunks, so a third distinct chunk evicts the first.
    private func makeRig() -> Rig {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        let file = MemoryChunkFile()
        let spills = DispatchQueue(label: "test.spill")
        let tier = DiskChunkTier(file: file, budgetBytes: 64 * (Self.chunk + DiskChunkTier.tagRoom),
                                 chunkBytes: Self.chunk, spillQueue: spills)
        let store = DaemonStore(daemon: daemon, session: "s1", blockSize: Self.blockSize,
                                byteCount: UInt64(Self.capacity),
                                ramCacheBytes: 2 * Self.chunk, diskTier: tier)
        return Rig(store: store, daemon: daemon, tier: tier, file: file, spills: spills)
    }

    private func read(_ store: DaemonStore, at offset: Int, length: Int = 4096) throws -> Data {
        var out = Data(count: length)
        let got: Int = try out.withUnsafeMutableBytes { raw in
            try store.read(into: raw, at: UInt64(offset), length: length)
        }
        return out.prefix(got)
    }

    private static func pattern(_ seed: UInt8) -> Data {
        Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }

    /// Reads chunk 0, then chunks 4 and 8 (never consecutive, so nothing is
    /// speculated): the two-chunk RAM tier evicts 0 to disk.
    private func evictChunkZero(_ rig: Rig) throws {
        _ = try read(rig.store, at: 0)
        _ = try read(rig.store, at: 4 * Self.chunk)
        _ = try read(rig.store, at: 8 * Self.chunk)
        rig.drain()
    }

    @Test("a chunk re-read after RAM eviction costs no daemon call")
    func rereadIsServedFromDisk() throws {
        let rig = makeRig()
        _ = try rig.store.write(Self.pattern(1), at: 0)
        try evictChunkZero(rig)
        let before = rig.daemonReads
        #expect(try read(rig.store, at: 0) == Self.pattern(1))
        #expect(rig.daemonReads == before)
        #expect(rig.tier.stats.hits == 1)
        #expect(rig.store.summary.contains("disk=1/"))
        #expect(rig.store.summary.contains("diskSaved=\(Self.chunk)B"))
    }

    @Test("a write to a chunk held only on disk is read back new, from the daemon")
    func writeAfterEvictionReadsBackNew() throws {
        let rig = makeRig()
        _ = try rig.store.write(Self.pattern(1), at: 0)
        try evictChunkZero(rig)
        _ = try rig.store.write(Self.pattern(2), at: 0)
        #expect(rig.tier.lookup(offset: 0, length: Self.chunk) == nil, "the write invalidated it")
        let before = rig.daemonReads
        #expect(try read(rig.store, at: 0) == Self.pattern(2))
        #expect(rig.daemonReads == before + 1)
    }

    /// The spill of chunk 0 is queued (held) when the write lands; the write's
    /// invalidation must cancel it, or pre-write bytes reach disk after it.
    @Test("a write racing a pending spill is read back new")
    func writeRacingPendingSpill() throws {
        let rig = makeRig()
        _ = try rig.store.write(Self.pattern(1), at: 0)
        rig.spills.suspend()
        _ = try read(rig.store, at: 0)
        _ = try read(rig.store, at: 4 * Self.chunk)
        _ = try read(rig.store, at: 8 * Self.chunk)        // evicts 0: spill queued, held
        _ = try rig.store.write(Self.pattern(2), at: 0)
        rig.spills.resume()
        rig.drain()
        #expect(try read(rig.store, at: 0) == Self.pattern(2))
    }

    @Test("reads keep working after the tier disables itself")
    func readsSurviveDisable() throws {
        let rig = makeRig()
        rig.file.failWrites = true
        _ = try rig.store.write(Self.pattern(1), at: 0)
        try evictChunkZero(rig)
        #expect(rig.tier.stats.disabledReason != nil)
        #expect(try read(rig.store, at: 0) == Self.pattern(1))
        #expect(rig.store.summary.contains("diskOff="))
    }

    /// Chunks 2 and 3 are put on disk; then a full-chunk sequential pair
    /// (0, 1) opens the readahead gate and speculates 2 and 3 — which must
    /// come from disk, not the daemon.
    @Test("speculation is served from disk when the chunk is there")
    func speculationFromDisk() throws {
        let rig = makeRig()
        _ = try read(rig.store, at: 3 * Self.chunk, length: Self.chunk)
        _ = try read(rig.store, at: 2 * Self.chunk, length: Self.chunk)
        _ = try read(rig.store, at: 10 * Self.chunk)
        _ = try read(rig.store, at: 12 * Self.chunk)
        rig.drain()
        let logIndex = rig.daemon.log.count
        _ = try read(rig.store, at: 0, length: Self.chunk)
        _ = try read(rig.store, at: Self.chunk, length: Self.chunk)
        _ = try read(rig.store, at: 2 * Self.chunk, length: Self.chunk)   // waits on the speculation
        let after = rig.daemon.log.dropFirst(logIndex)
        #expect(!after.contains { $0.kind == "read" && $0.offset == UInt64(2 * Self.chunk) })
        #expect(rig.tier.stats.hits >= 1)
    }

    @Test("a daemon that never answers the cache-size call does not stall the mount")
    func unansweredCacheSizeIsOff() {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        daemon.answersLocalCache = false
        let start = Date()
        #expect(DaemonStore.localCacheSetting(from: daemon, session: "s1", timeout: 0.2) == 0)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("the cache size the daemon reports is what the store asks for")
    func answeredCacheSize() {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        daemon.localCache = 4 << 30
        #expect(DaemonStore.localCacheSetting(from: daemon, session: "s1") == 4 << 30)
    }
}
