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

/// Every chunk the cache hands to `onEvict`, in order.
private final class EvictLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(offset: UInt64, data: Data)] = []
    func add(_ offset: UInt64, _ data: Data) { lock.lock(); seen.append((offset, data)); lock.unlock() }
    var offsets: [UInt64] { lock.lock(); defer { lock.unlock() }; return seen.map(\.offset) }
    var all: [(offset: UInt64, data: Data)] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Suite("Prefetch chunk cache")
struct PrefetchChunkCacheTests {
    static let chunk = 4096

    // MARK: - Eviction hook (the disk tier's only source)

    private static func makeEvictingCache(backing: FakeBacking, log: EvictLog,
                                          maxCachedBytes: Int,
                                          minStreamBytes: Int = .max) -> PrefetchChunkCache {
        PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: backing.capacity,
            maxCachedBytes: maxCachedBytes,
            policy: ReadaheadPolicy(budgetBytes: 8 * chunk, maxSlots: 32,
                                    minStreamBytes: minStreamBytes, chunkBytes: chunk),
            timeout: 5,
            fetchSync: backing.fetchSync,
            fetchAsync: backing.fetchAsync,
            onEvict: { log.add($0, $1) })
    }

    @Test("a chunk that was read is handed to onEvict with its bytes when evicted")
    func readChunkIsHandedToOnEvict() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log, maxCachedBytes: 2 * Self.chunk)
        for i in [0, 4, 8] { _ = try cache.read(offset: UInt64(i * Self.chunk), length: 100) }
        #expect(log.offsets == [0])
        #expect(log.all.first?.data == FakeBacking.pattern(offset: 0, length: Self.chunk))
    }

    /// Reads chunks 0 and 1 back to back (16 KiB stream gate at 8 KiB), which
    /// speculates 2 and 3; then four far reads evict everything older. Only
    /// the two chunks a caller read reach the hook — speculation nobody read
    /// was never wanted the first time and must not cost a disk write.
    @Test("unread speculation is never handed to onEvict")
    func unreadSpeculationIsNotHandedOn() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log,
                                           maxCachedBytes: 4 * Self.chunk, minStreamBytes: 8192)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.asyncCount == 2, "chunks 2 and 3 speculated")
        for i in [7, 8, 9, 10] { _ = try cache.read(offset: UInt64(i * Self.chunk), length: 100) }
        #expect(log.offsets == [0, UInt64(Self.chunk)])
    }

    @Test("a speculative chunk that was read is handed to onEvict")
    func usedSpeculationIsHandedOn() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log,
                                           maxCachedBytes: 4 * Self.chunk, minStreamBytes: 8192)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        _ = try cache.read(offset: UInt64(2 * Self.chunk), length: 100)   // speculated, now read
        for i in [7, 8, 9, 10] { _ = try cache.read(offset: UInt64(i * Self.chunk), length: 100) }
        #expect(log.offsets.contains(UInt64(2 * Self.chunk)))
    }

    @Test("chunks dropped by a failed write are not handed to onEvict")
    func writeRemovalsAreNotSpills() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log, maxCachedBytes: 4 * Self.chunk)
        _ = try cache.read(offset: 0, length: 100)
        cache.writeFailed(offset: 0, length: Self.chunk)
        #expect(log.offsets.isEmpty)
    }

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

// MARK: - Read-around below the chunk

/// A clock the test moves. `step` is added on every reading, so each cache
/// read is that much activity after the previous one; 0 freezes it, which
/// keeps the read-around controller from ever deciding anything.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: UInt64 = 1
    let step: UInt64
    init(step: UInt64) { self.step = step }
    func now() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nanos &+= step
        return nanos
    }
}

/// A LUN that takes writes, for checking the cache against the truth.
private final class MutableBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]
    var capacity: UInt64 { UInt64(bytes.count) }
    init(capacity: Int) { bytes = (0 ..< capacity).map { FakeBacking.byte(at: UInt64($0)) } }
    func read(_ offset: UInt64, _ length: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        return Data(bytes[Int(offset) ..< Int(offset) + length])
    }
    func write(_ data: Data, at offset: UInt64) {
        lock.lock(); defer { lock.unlock() }
        bytes.replaceSubrange(Int(offset) ..< Int(offset) + data.count, with: data)
    }
}

/// Deterministic, so a failure names a reproducible sequence.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Entries that hold only part of a chunk. The geometry is the suite above's
/// 4 KiB chunk cut into eight 512-byte sectors, with the clock frozen so the
/// unit stays wherever the test puts it.
@Suite("Prefetch chunk cache: read-around below the chunk")
struct PrefetchChunkCacheReadAroundTests {
    static let chunk = PrefetchChunkCacheTests.chunk
    static let sector = 512

    private static func make(backing: FakeBacking, unit: Int = sector,
                             maxCachedBytes: Int = 1 << 20, minStreamBytes: Int = .max,
                             onEvict: ((UInt64, Data) -> Void)? = nil) -> PrefetchChunkCache {
        PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: backing.capacity,
            maxCachedBytes: maxCachedBytes,
            policy: ReadaheadPolicy(budgetBytes: 8 * chunk, maxSlots: 32,
                                    minStreamBytes: minStreamBytes, chunkBytes: chunk),
            timeout: 5,
            sectorBytes: sector,
            readAroundStartBytes: unit,
            clock: { 1 },
            fetchSync: backing.fetchSync,
            fetchAsync: backing.fetchAsync,
            onEvict: onEvict)
    }

    @Test("a miss fetches only the sectors it needs")
    func missFetchesOnlyItsSectors() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let cache = Self.make(backing: backing)
        let data = try cache.read(offset: 1124, length: 200)
        #expect(data == FakeBacking.pattern(offset: 1124, length: 200))
        #expect(backing.syncFetches.count == 1)
        #expect(backing.syncFetches[0].offset == 1024)
        #expect(backing.syncFetches[0].length == 512)
        #expect(cache.stats.readAroundBytes == 312)
        #expect(cache.stats.readAroundUnit == 512)
    }

    @Test("a read inside what a partial entry holds is a hit; one outside it fetches just its own part")
    func partialEntryHitsInsideAndMissesOutside() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let cache = Self.make(backing: backing)
        _ = try cache.read(offset: 1024, length: 512)
        let inside = try cache.read(offset: 1100, length: 100)
        #expect(inside == FakeBacking.pattern(offset: 1100, length: 100))
        #expect(backing.syncCount == 1)
        #expect(cache.stats.hits == 1)
        let outside = try cache.read(offset: 3072, length: 512)
        #expect(outside == FakeBacking.pattern(offset: 3072, length: 512))
        #expect(backing.syncCount == 2)
        #expect(backing.syncFetches[1].offset == 3072 && backing.syncFetches[1].length == 512)
    }

    @Test("neighbouring pieces of one chunk merge into one entry")
    func adjacentPiecesMerge() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let cache = Self.make(backing: backing)
        _ = try cache.read(offset: 1024, length: 512)
        _ = try cache.read(offset: 1536, length: 512)
        #expect(backing.syncCount == 2)
        let both = try cache.read(offset: 1024, length: 1024)
        #expect(both == FakeBacking.pattern(offset: 1024, length: 1024))
        #expect(backing.syncCount == 2, "the merged entry covers both pieces")
    }

    /// One contiguous range per chunk: the newer, disjoint piece wins.
    @Test("a disjoint piece of the same chunk replaces the older one")
    func disjointPieceReplaces() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let cache = Self.make(backing: backing)
        _ = try cache.read(offset: 0, length: 512)
        _ = try cache.read(offset: 2048, length: 512)
        let again = try cache.read(offset: 0, length: 512)
        #expect(again == FakeBacking.pattern(offset: 0, length: 512))
        #expect(backing.syncCount == 3)
    }

    @Test("a write is patched into a partial entry at the entry's own offset")
    func writePatchesAPartialEntry() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let cache = Self.make(backing: backing)
        _ = try cache.read(offset: 1024, length: 512)   // holds [1024, 1536)
        let inside = Data(repeating: 0xAB, count: 64)
        cache.willWrite(offset: 1100, length: 64)
        cache.didWrite(inside, at: 1100)
        // Straddles the entry's end: only [1500, 1536) lands in it.
        let straddling = Data(repeating: 0xCD, count: 100)
        cache.willWrite(offset: 1500, length: 100)
        cache.didWrite(straddling, at: 1500)

        let data = try cache.read(offset: 1024, length: 512)
        #expect(backing.syncCount == 1, "still a hit")
        #expect(data.subdata(in: 0 ..< 76) == FakeBacking.pattern(offset: 1024, length: 76))
        #expect(data.subdata(in: 76 ..< 140) == inside)
        #expect(data.subdata(in: 140 ..< 476) == FakeBacking.pattern(offset: 1164, length: 336))
        #expect(data.subdata(in: 476 ..< 512) == Data(repeating: 0xCD, count: 36))
    }

    @Test("a read across a chunk boundary is one fetch, served back in order")
    func boundaryReadIsOneFetch() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let cache = Self.make(backing: backing)
        _ = try cache.read(offset: 3584, length: 1024)
        #expect(backing.syncFetches.count == 1)
        #expect(backing.syncFetches[0].offset == 3584 && backing.syncFetches[0].length == 1024)
        let data = try cache.read(offset: 3700, length: 700)
        #expect(data == FakeBacking.pattern(offset: 3700, length: 700))
        #expect(backing.syncCount == 1)
    }

    /// The disk tier keys a slot by its chunk and serves it from the chunk's
    /// first byte, so handing it part of a chunk would later serve the wrong
    /// bytes at the right offset.
    @Test("only whole chunks reach onEvict, including one merged up from pieces")
    func onlyWholeChunksReachOnEvict() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let log = EvictLog()
        let cache = Self.make(backing: backing, maxCachedBytes: Self.chunk,
                              onEvict: { log.add($0, $1) })
        // Chunk 0 a sector at a time, until the pieces merge into all of it.
        for s in 0 ..< Self.chunk / Self.sector {
            _ = try cache.read(offset: UInt64(s * Self.sector), length: Self.sector)
        }
        #expect(backing.syncCount == 8)
        // A piece of chunk 4 pushes the cache over budget: chunk 0 goes, whole.
        _ = try cache.read(offset: UInt64(4 * Self.chunk), length: Self.sector)
        #expect(log.offsets == [0])
        #expect(log.all.first?.data == FakeBacking.pattern(offset: 0, length: Self.chunk))
        // Eight more pieces evict chunk 4's, which must not be handed on.
        for c in [1, 2, 3, 5, 6, 7, 8, 9] {
            _ = try cache.read(offset: UInt64(c * Self.chunk), length: Self.sector)
        }
        let before = backing.syncCount
        _ = try cache.read(offset: UInt64(4 * Self.chunk), length: Self.sector)
        #expect(backing.syncCount == before + 1, "chunk 4's piece was evicted")
        #expect(log.offsets == [0])
    }

    @Test("speculation fetches the whole of a chunk a miss left partly cached")
    func speculationCompletesAPartialChunk() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        let cache = Self.make(backing: backing, minStreamBytes: 2 * Self.chunk)
        _ = try cache.read(offset: UInt64(2 * Self.chunk) + 512, length: 512)  // a piece of chunk 2
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)    // opens the gate
        #expect(backing.asyncFetches.map(\.offset) == [UInt64(2 * Self.chunk), UInt64(3 * Self.chunk)])
        #expect(backing.asyncFetches.allSatisfy { $0.length == Self.chunk })
        let before = backing.syncCount
        let data = try cache.read(offset: UInt64(2 * Self.chunk), length: Self.chunk)
        #expect(data == FakeBacking.pattern(offset: UInt64(2 * Self.chunk), length: Self.chunk))
        #expect(backing.syncCount == before)
    }

    @Test("a miss that only touches a chunk still being speculated leaves that speculation in place")
    func partialMissKeepsPendingSpeculation() throws {
        let backing = PrefetchChunkCacheTests.makeBacking()
        backing.asyncMode = .manual
        let cache = Self.make(backing: backing, minStreamBytes: 2 * Self.chunk)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.pending.count == 2, "chunks 2 and 3 on their way")
        // The tail of pending chunk 3 and the head of absent chunk 4: a miss.
        let edge = try cache.read(offset: UInt64(4 * Self.chunk) - 512, length: 1024)
        #expect(edge == FakeBacking.pattern(offset: UInt64(4 * Self.chunk) - 512, length: 1024))
        backing.completeAllPending()
        let before = backing.syncCount
        let head = try cache.read(offset: UInt64(3 * Self.chunk), length: 512)
        #expect(head == FakeBacking.pattern(offset: UInt64(3 * Self.chunk), length: 512))
        #expect(backing.syncCount == before, "served by the speculation the miss left alone")
    }

    /// Everything above, at once and at random: reads that wander and reads
    /// that stream (so speculation runs), writes acknowledged and writes
    /// whose outcome is unknown, under eviction pressure, at every fixed unit
    /// and with the controller free to move. Every read is checked against
    /// the LUN itself.
    @Test("every read matches the LUN, at any unit, whatever the mix of operations",
          arguments: [512, 1024, 2048, 4096], [false, true])
    func readsMatchTheLUN(unit: Int, adaptive: Bool) throws {
        let lun = MutableBacking(capacity: 10 * Self.chunk + 2048)
        let clock = TestClock(step: adaptive ? 50_000_000 : 0)
        let cache = PrefetchChunkCache(
            chunkBytes: Self.chunk,
            capacity: lun.capacity,
            maxCachedBytes: 3 * Self.chunk,
            policy: ReadaheadPolicy(budgetBytes: 4 * Self.chunk, maxSlots: 32,
                                    minStreamBytes: 2 * Self.chunk, chunkBytes: Self.chunk),
            timeout: 5,
            adaptiveDepth: adaptive,
            sectorBytes: Self.sector,
            readAroundStartBytes: unit,
            clock: { clock.now() },
            fetchSync: { offset, length in lun.read(offset, length) },
            fetchAsync: { offset, length, done in done(lun.read(offset, length)) })

        var rng = SplitMix64(state: UInt64(unit) &* 31 &+ (adaptive ? 7 : 0))
        let capacity = Int(lun.capacity)
        var lastEnd = 0
        var units: Set<Int> = []
        for step in 0 ..< 3000 {
            let roll = Int.random(in: 0 ..< 100, using: &rng)
            if roll < 55 {
                let offset: Int
                switch Int.random(in: 0 ..< 10, using: &rng) {
                case 0 ..< 3: offset = lastEnd < capacity ? lastEnd : 0              // continue a stream
                case 3 ..< 5: offset = Int.random(in: 0 ..< capacity, using: &rng)   // any byte
                default: offset = Int.random(in: 0 ..< capacity / Self.sector, using: &rng) * Self.sector
                }
                let length = Int.random(in: 1 ... 6, using: &rng) * Self.sector
                let count = min(length, capacity - offset)
                let got = try cache.read(offset: UInt64(offset), length: length)
                #expect(got == lun.read(UInt64(offset), count), "step \(step): read \(count) at \(offset)")
                lastEnd = offset + count
                units.insert(cache.stats.readAroundUnit)
            } else {
                let offset = Int.random(in: 0 ..< capacity - Self.sector, using: &rng)
                let length = min(Int.random(in: 1 ... 8192, using: &rng), capacity - offset)
                let data = Data((0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
                cache.willWrite(offset: UInt64(offset), length: length)
                if roll < 90 {
                    lun.write(data, at: UInt64(offset))
                    cache.didWrite(data, at: UInt64(offset))
                } else {
                    // Outcome unknown: it may or may not have reached the media.
                    if Bool.random(using: &rng) { lun.write(data, at: UInt64(offset)) }
                    cache.writeFailed(offset: UInt64(offset), length: length)
                }
            }
        }
        if !adaptive { #expect(units == [unit], "a frozen clock never moves the unit") }
    }
}

/// The adaptation end to end, at the shipping geometry: 256 KiB chunks,
/// 4 KiB sectors, a 32 MiB cache, reads 50 ms of activity apart.
@Suite("Prefetch chunk cache: read-around adapts")
struct PrefetchChunkCacheAdaptationTests {
    static let chunk = 256 << 10
    static let sector = 4096

    private func make(_ backing: FakeBacking) -> PrefetchChunkCache {
        let clock = TestClock(step: 50_000_000)
        return PrefetchChunkCache(
            chunkBytes: Self.chunk,
            capacity: backing.capacity,
            maxCachedBytes: 32 << 20,
            policy: ReadaheadPolicy(budgetBytes: 8 << 20, maxSlots: 32,
                                    minStreamBytes: Self.chunk, chunkBytes: Self.chunk),
            timeout: 5,
            sectorBytes: Self.sector,
            clock: { clock.now() },
            fetchSync: backing.fetchSync,
            fetchAsync: backing.fetchAsync)
    }

    /// Issue #4: each 4 KiB random read fetched the whole 256 KiB chunk.
    @Test("scattered 4 KiB reads stop fetching whole chunks within a second of activity")
    func scatterStopsFetchingWholeChunks() throws {
        let backing = FakeBacking(capacity: 1 << 30)
        let cache = make(backing)
        func scattered(_ i: Int) -> UInt64 { UInt64((i * 7) * Self.chunk + (i % 64) * Self.sector) }

        // Twenty reads make the first second; the twenty-first is decided on it.
        for i in 0 ..< 20 { _ = try cache.read(offset: scattered(i), length: Self.sector) }
        #expect(backing.syncFetches.allSatisfy { $0.length == Self.chunk }, "it starts at the whole chunk")

        for i in 20 ..< 60 {
            let data = try cache.read(offset: scattered(i), length: Self.sector)
            #expect(data == FakeBacking.pattern(offset: scattered(i), length: Self.sector))
        }
        #expect(cache.stats.readAroundUnit == Self.sector)
        let after = backing.syncFetches.dropFirst(20)
        #expect(after.count == 40)
        #expect(after.allSatisfy { $0.length == Self.sector }, "fetched exactly what was asked")
    }

    @Test("dense reads after a scatter bring whole-chunk read-around back")
    func densityRestoresTheWholeChunk() throws {
        let backing = FakeBacking(capacity: 1 << 30)
        let cache = make(backing)
        for i in 0 ..< 40 {
            _ = try cache.read(offset: UInt64((i * 7) * Self.chunk), length: Self.sector)
        }
        #expect(cache.stats.readAroundUnit == Self.sector)

        // Every sector of each of four chunks, shuffled so no stream forms.
        for c in 1000 ..< 1004 {
            for s in (0 ..< 64).map({ ($0 * 37) % 64 }) {
                let offset = UInt64(c * Self.chunk + s * Self.sector)
                let data = try cache.read(offset: offset, length: Self.sector)
                #expect(data == FakeBacking.pattern(offset: offset, length: Self.sector))
            }
        }
        #expect(cache.stats.readAroundUnit == Self.chunk)
        _ = try cache.read(offset: UInt64(2000 * Self.chunk), length: Self.sector)
        #expect(backing.syncFetches.last?.length == Self.chunk)
    }
}
