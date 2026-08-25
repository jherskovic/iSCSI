import Foundation
import Testing
@testable import iSCSIKit

/// An in-memory LUN with deterministic contents and full visibility into what
/// the cache fetched, so every assertion is about real behaviour: which spans
/// were read from the "target", and whether the bytes handed back are the ones
/// that live at that offset.
private final class FakeBacking: @unchecked Sendable {
    enum AsyncMode {
        /// Speculative fetches complete inline with correct data.
        case immediate
        /// Speculative fetches complete inline with nil (a failed read).
        case fail
        /// Speculative fetches are captured for the test to complete by hand.
        case manual
    }

    let lock = NSLock()
    let capacity: UInt64
    var asyncMode: AsyncMode = .immediate
    private(set) var syncFetches: [(offset: UInt64, length: Int)] = []
    private(set) var asyncFetches: [(offset: UInt64, length: Int)] = []
    private(set) var pending: [(offset: UInt64, length: Int, done: (Data?) -> Void)] = []

    init(capacity: UInt64) { self.capacity = capacity }

    /// The byte that lives at absolute offset `i` — position-dependent, so a
    /// slice served from the wrong offset can never compare equal.
    static func byte(at i: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: i &* 2654435761 &+ (i >> 8)) }

    static func pattern(offset: UInt64, length: Int) -> Data {
        Data((0 ..< length).map { byte(at: offset &+ UInt64($0)) })
    }

    func fetchSync(offset: UInt64, length: Int) throws -> Data {
        lock.lock(); syncFetches.append((offset, length)); lock.unlock()
        return Self.pattern(offset: offset, length: length)
    }

    func fetchAsync(offset: UInt64, length: Int, done: @escaping (Data?) -> Void) {
        lock.lock()
        asyncFetches.append((offset, length))
        let mode = asyncMode
        if mode == .manual { pending.append((offset, length, done)) }
        lock.unlock()
        switch mode {
        case .immediate: done(Self.pattern(offset: offset, length: length))
        case .fail: done(nil)
        case .manual: break
        }
    }

    func completeAllPending(garbage: Bool = false) {
        lock.lock()
        let toComplete = pending
        pending = []
        lock.unlock()
        for p in toComplete {
            p.done(garbage ? Data(repeating: 0xFF, count: p.length)
                           : Self.pattern(offset: p.offset, length: p.length))
        }
    }

    var syncCount: Int { lock.lock(); defer { lock.unlock() }; return syncFetches.count }
    var asyncCount: Int { lock.lock(); defer { lock.unlock() }; return asyncFetches.count }
}

@Suite("Prefetch chunk cache")
struct PrefetchChunkCacheTests {
    static let chunk = 4096

    /// A cache over ten-and-a-half 4 KiB chunks. `minStreamBytes` of 8 KiB
    /// means two consecutive chunk-sized reads open the gate; passing
    /// `Int.max` disables speculation for tests that want a quiet cache.
    fileprivate static func makeCache(backing: FakeBacking,
                          maxCachedBytes: Int = 1 << 20,
                          minStreamBytes: Int = 8192,
                          timeout: TimeInterval = 5) -> PrefetchChunkCache {
        PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: backing.capacity,
            maxCachedBytes: maxCachedBytes,
            policy: ReadaheadPolicy(budgetBytes: 8 * chunk, maxSlots: 32,
                                    minStreamBytes: minStreamBytes, chunkBytes: chunk),
            timeout: timeout,
            fetchSync: backing.fetchSync,
            fetchAsync: backing.fetchAsync)
    }

    fileprivate static func makeBacking() -> FakeBacking { FakeBacking(capacity: UInt64(10 * chunk + 2048)) }

    @Test func missFetchesTheWholeCoveringChunk() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        let data = try cache.read(offset: 1024, length: 512)
        #expect(data == FakeBacking.pattern(offset: 1024, length: 512))
        #expect(backing.syncFetches.count == 1)
        #expect(backing.syncFetches[0].offset == 0)
        #expect(backing.syncFetches[0].length == Self.chunk)
        #expect(cache.stats.misses == 1)
        #expect(cache.stats.readAroundBytes == UInt64(Self.chunk - 512))
    }

    @Test func laterReadInTheSameChunkIsAHit() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        _ = try cache.read(offset: 0, length: 512)
        let data = try cache.read(offset: 2048, length: 1024)
        #expect(data == FakeBacking.pattern(offset: 2048, length: 1024))
        #expect(backing.syncCount == 1)
        #expect(cache.stats.hits == 1)
    }

    @Test func readSpanningChunksFetchesTheSpanInOneCall() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        let data = try cache.read(offset: 3072, length: 2048)
        #expect(data == FakeBacking.pattern(offset: 3072, length: 2048))
        #expect(backing.syncFetches.count == 1)
        #expect(backing.syncFetches[0].offset == 0)
        #expect(backing.syncFetches[0].length == 2 * Self.chunk)
        // ...and both chunks are now servable without another fetch.
        _ = try cache.read(offset: 0, length: 512)
        _ = try cache.read(offset: 4096, length: 512)
        #expect(backing.syncCount == 1)
    }

    @Test func tailChunkIsClampedToCapacity() throws {
        let backing = Self.makeBacking() // capacity = 10 chunks + 2048
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        let tailChunk = UInt64(10 * Self.chunk)
        let data = try cache.read(offset: tailChunk + 1024, length: 512)
        #expect(data == FakeBacking.pattern(offset: tailChunk + 1024, length: 512))
        #expect(backing.syncFetches[0].offset == tailChunk)
        #expect(backing.syncFetches[0].length == 2048)
    }

    @Test func gateOpensSpeculationInChunksAndHitsFollow() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        // Two consecutive chunk-sized reads cover the 8 KiB gate: 2 chunks
        // speculated beyond the read.
        #expect(backing.asyncFetches.count == 2)
        #expect(backing.asyncFetches[0].offset == UInt64(2 * Self.chunk))
        #expect(backing.asyncFetches[0].length == Self.chunk)
        #expect(backing.asyncFetches[1].offset == UInt64(3 * Self.chunk))
        #expect(backing.asyncFetches[1].length == Self.chunk)
        // The speculated chunk serves the next read without a sync fetch.
        let before = backing.syncCount
        let data = try cache.read(offset: UInt64(2 * Self.chunk), length: Self.chunk)
        #expect(data == FakeBacking.pattern(offset: UInt64(2 * Self.chunk), length: Self.chunk))
        #expect(backing.syncCount == before)
        #expect(cache.stats.speculatedUsed >= 1)
        #expect(cache.stats.maxDepth >= 2)
    }

    @Test func failedSpeculativeChunkFallsBackToARealRead() throws {
        let backing = Self.makeBacking()
        backing.asyncMode = .fail
        let cache = Self.makeCache(backing: backing)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.asyncCount == 2) // speculation was attempted and failed
        let before = backing.syncCount
        let data = try cache.read(offset: UInt64(2 * Self.chunk), length: Self.chunk)
        #expect(data == FakeBacking.pattern(offset: UInt64(2 * Self.chunk), length: Self.chunk))
        #expect(backing.syncCount == before + 1) // fetched for real
    }

    @Test func readerWaitsForAPendingSpeculativeChunk() throws {
        let backing = Self.makeBacking()
        backing.asyncMode = .manual
        let cache = Self.makeCache(backing: backing)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.pending.count == 2)
        // Complete the pending fills shortly after the reader starts waiting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            backing.completeAllPending()
        }
        let before = backing.syncCount
        let data = try cache.read(offset: UInt64(2 * Self.chunk), length: Self.chunk)
        #expect(data == FakeBacking.pattern(offset: UInt64(2 * Self.chunk), length: Self.chunk))
        #expect(backing.syncCount == before)
        #expect(cache.stats.hits >= 1)
    }

    @Test func unansweredPendingChunkTimesOut() throws {
        let backing = Self.makeBacking()
        backing.asyncMode = .manual
        let cache = Self.makeCache(backing: backing, timeout: 0.2)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.pending.count == 2)
        #expect(throws: PrefetchChunkCache.CacheError.unanswered) {
            _ = try cache.read(offset: UInt64(2 * Self.chunk), length: Self.chunk)
        }
        #expect(cache.stats.unanswered == 1)
    }

    @Test func acknowledgedWritePatchesTheCachedChunkInPlace() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        _ = try cache.read(offset: 0, length: 512) // chunk 0 cached
        #expect(backing.syncCount == 1)
        // A write inside the cached chunk patches it; nothing needs refetching.
        let written = Data(repeating: 0xAB, count: 64)
        cache.willWrite(offset: 100, length: 64)
        cache.didWrite(written, at: 100)
        let data = try cache.read(offset: 0, length: 512)
        #expect(backing.syncCount == 1) // still a hit
        #expect(data.subdata(in: 100 ..< 164) == written)
        #expect(data.subdata(in: 0 ..< 100) == FakeBacking.pattern(offset: 0, length: 100))
        #expect(data.subdata(in: 164 ..< 512)
                == FakeBacking.pattern(offset: 164, length: 512 - 164))
    }

    @Test func writeSpanningAChunkBoundaryPatchesBothChunks() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        _ = try cache.read(offset: 3072, length: 2048) // chunks 0 and 1 cached
        let start = UInt64(Self.chunk) - 128
        let written = Data(repeating: 0xCD, count: 256)
        cache.willWrite(offset: start, length: 256)
        cache.didWrite(written, at: start)
        let data = try cache.read(offset: start, length: 256)
        #expect(backing.syncCount == 1) // both chunks still hot
        #expect(data == written)
    }

    @Test func failedWriteDropsTheOverlappingChunk() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        _ = try cache.read(offset: 0, length: 512)                       // chunk 0
        _ = try cache.read(offset: UInt64(Self.chunk), length: 512)      // chunk 1
        #expect(backing.syncCount == 2)
        // The write's outcome is unknown, so the chunk's bytes are unknowable.
        cache.willWrite(offset: 100, length: 50)
        cache.writeFailed(offset: 100, length: 50)
        _ = try cache.read(offset: 512, length: 512)                     // chunk 0: refetch
        #expect(backing.syncCount == 3)
        _ = try cache.read(offset: UInt64(Self.chunk) + 512, length: 512) // chunk 1: still hot
        #expect(backing.syncCount == 3)
    }

    @Test func writeToAnUncachedRangeIsHarmless() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        cache.willWrite(offset: UInt64(5 * Self.chunk), length: 512)
        cache.didWrite(Data(repeating: 1, count: 512), at: UInt64(5 * Self.chunk))
        let data = try cache.read(offset: 0, length: 512)
        #expect(data == FakeBacking.pattern(offset: 0, length: 512))
    }

    @Test func writeResetsTheSpeculationRamp() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        let speculatedBefore = backing.asyncCount
        #expect(speculatedBefore > 0)
        cache.willWrite(offset: UInt64(9 * Self.chunk), length: 512)
        cache.didWrite(Data(repeating: 1, count: 512), at: UInt64(9 * Self.chunk))
        // The stream must re-earn the gate from nothing: the next read —
        // even one continuing the pre-write run — speculates nothing.
        _ = try cache.read(offset: UInt64(4 * Self.chunk), length: Self.chunk)
        #expect(backing.asyncCount == speculatedBefore)
    }

    @Test func writeDropsAnOverlappingPendingFetch() throws {
        let backing = Self.makeBacking()
        backing.asyncMode = .manual
        let cache = Self.makeCache(backing: backing)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.pending.count == 2) // chunks 2 and 3 pending
        // A write into pending chunk 2: that fetch is now of unknowable era
        // and must not be waited on or kept.
        cache.willWrite(offset: UInt64(2 * Self.chunk) + 64, length: 64)
        cache.didWrite(Data(repeating: 2, count: 64), at: UInt64(2 * Self.chunk) + 64)
        backing.completeAllPending(garbage: true) // orphans; must go nowhere
        let data = try cache.read(offset: UInt64(2 * Self.chunk), length: 512)
        // Served fresh from the backing, not from the orphaned garbage fill.
        #expect(data == FakeBacking.pattern(offset: UInt64(2 * Self.chunk), length: 512))
    }

    @Test func lruEvictsTheColdestReadyChunk() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing,
                                   maxCachedBytes: 2 * Self.chunk,
                                   minStreamBytes: .max)
        _ = try cache.read(offset: 0, length: 512)                        // chunk 0
        _ = try cache.read(offset: UInt64(4 * Self.chunk), length: 512)   // chunk 4
        _ = try cache.read(offset: UInt64(8 * Self.chunk), length: 512)   // chunk 8 -> evicts 0
        #expect(backing.syncCount == 3)
        _ = try cache.read(offset: UInt64(4 * Self.chunk) + 512, length: 512) // chunk 4 survives
        #expect(backing.syncCount == 3)
        _ = try cache.read(offset: 512, length: 512)                      // chunk 0 was evicted
        #expect(backing.syncCount == 4)
    }

    @Test func lateFillOfAnOverwrittenPendingChunkIsDiscarded() throws {
        let backing = Self.makeBacking()
        backing.asyncMode = .manual
        let cache = Self.makeCache(backing: backing)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.pending.count == 2) // chunks 2 and 3 pending
        // A read spanning pending chunk 2 through missing chunk 4 span-fetches
        // and replaces the pending entries.
        let spanData = try cache.read(offset: UInt64(2 * Self.chunk) + 100,
                                      length: 2 * Self.chunk)
        #expect(spanData == FakeBacking.pattern(offset: UInt64(2 * Self.chunk) + 100,
                                                length: 2 * Self.chunk))
        // The orphaned replies now land — with garbage. It must go nowhere.
        backing.completeAllPending(garbage: true)
        let data = try cache.read(offset: UInt64(2 * Self.chunk), length: 512)
        #expect(data == FakeBacking.pattern(offset: UInt64(2 * Self.chunk), length: 512))
    }

    @Test func writeDuringMissFetchPreventsCachingPreWriteData() throws {
        let backing = Self.makeBacking()
        final class Box: @unchecked Sendable { var cache: PrefetchChunkCache? }
        let box = Box()
        let cache = PrefetchChunkCache(
            chunkBytes: Self.chunk,
            capacity: backing.capacity,
            maxCachedBytes: 1 << 20,
            policy: ReadaheadPolicy(budgetBytes: 8 * Self.chunk, maxSlots: 32,
                                    minStreamBytes: .max, chunkBytes: Self.chunk),
            timeout: 5,
            fetchSync: { offset, length in
                // A write began while this fetch was on the wire: the racing
                // caller may be served these bytes, but keeping them would
                // serve pre-write data indefinitely.
                box.cache?.willWrite(offset: offset, length: 1)
                return try backing.fetchSync(offset: offset, length: length)
            },
            fetchAsync: backing.fetchAsync)
        box.cache = cache
        _ = try cache.read(offset: 0, length: 512)
        // Nothing stale was retained: the same chunk misses again.
        _ = try cache.read(offset: 1024, length: 512)
        #expect(backing.syncCount == 2)
    }

    @Test func zeroLengthReadReturnsEmpty() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, minStreamBytes: .max)
        let data = try cache.read(offset: 0, length: 0)
        #expect(data.isEmpty)
        #expect(backing.syncCount == 0)
    }
}

// MARK: - Terminal-state speculation accounting

extension PrefetchChunkCacheTests {

    /// `chunksSpeculated - speculatedUsed` would count still-resident chunks
    /// whose reader is milliseconds behind as waste — worse at greater depth,
    /// fatal for a controller that reduces depth when waste rises.
    /// `resolvedWasted` counts a chunk only once it leaves the cache unread.
    @Test func residentUntouchedSpeculationIsNotYetWaste() throws {
        let backing = Self.makeBacking()
        // Room for everything, so nothing is evicted and nothing can resolve.
        let cache = Self.makeCache(backing: backing, maxCachedBytes: 1 << 20,
                                   minStreamBytes: Self.chunk)
        // Two consecutive reads open the window and speculate ahead.
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)

        let s = cache.stats
        #expect(s.chunksSpeculated > 0, "the ramp must have speculated for this test to mean anything")
        #expect(s.chunksSpeculated - s.speculatedUsed > 0,
                "the old counter calls resident-but-unread speculation waste")
        #expect(s.resolvedWasted == 0,
                "nothing has left the cache, so no speculation has been proven wasted")
        #expect(s.resolvedUsed + s.resolvedWasted == 0)
    }

    /// And once a speculative chunk is evicted without ever being read, it is
    /// waste — that is the terminal state the controller acts on.
    @Test func evictedUntouchedSpeculationResolvesAsWaste() throws {
        let backing = Self.makeBacking()
        // One chunk of residency: every new chunk evicts the previous one.
        let cache = Self.makeCache(backing: backing, maxCachedBytes: Self.chunk,
                                   minStreamBytes: Self.chunk)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        // Jump far away repeatedly to push the speculated chunks out.
        for i in 5 ..< 10 {
            _ = try cache.read(offset: UInt64(i * Self.chunk), length: 512)
        }

        let s = cache.stats
        #expect(s.resolvedWasted > 0, "evicted, never touched — that is waste")
    }

    /// A speculative chunk a reader did reach is not waste, however long it
    /// lingers afterwards.
    @Test func touchedSpeculationResolvesAsUsed() throws {
        let backing = Self.makeBacking()
        let cache = Self.makeCache(backing: backing, maxCachedBytes: Self.chunk,
                                   minStreamBytes: Self.chunk)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        // Walk into what was speculated, so it is used before being evicted.
        _ = try cache.read(offset: UInt64(2 * Self.chunk), length: Self.chunk)
        _ = try cache.read(offset: UInt64(3 * Self.chunk), length: Self.chunk)
        for i in 20 ..< 25 {
            _ = try cache.read(offset: UInt64(i * Self.chunk), length: 512)
        }

        let s = cache.stats
        #expect(s.resolvedUsed > 0, "speculation that was read must resolve as used, not waste")
    }
}
