import Foundation
import Testing
@testable import iSCSIVolume

/// The disk tier on its own: storage, encryption, sizing, coherence tickets,
/// and the rule that no cache failure is ever more than a miss.
@Suite("Disk chunk tier", .timeLimit(.minutes(1)))
struct DiskChunkTierTests {

    private static let chunk = 4096
    private static let stride = chunk + DiskChunkTier.tagRoom

    private static func pattern(_ seed: UInt8, _ count: Int = chunk) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// A tier over `slots` slots of an in-memory file, spilling on `queue`
    /// so a test can hold or drain it.
    private func makeTier(slots: Int, file: MemoryChunkFile = MemoryChunkFile(),
                          queue: DispatchQueue = DispatchQueue(label: "test.spill"))
        -> (DiskChunkTier, MemoryChunkFile, DispatchQueue) {
        let tier = DiskChunkTier(file: file, budgetBytes: slots * Self.stride,
                                 chunkBytes: Self.chunk, spillQueue: queue)
        return (tier, file, queue)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Storage

    @Test("a spilled chunk reads back")
    func spillThenLookup() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: Self.chunk) == Self.pattern(1))
        let stats = tier.stats
        #expect(stats.spilled == 1 && stats.hits == 1 && stats.lookups == 1)
        #expect(stats.savedBytes == UInt64(Self.chunk))
    }

    @Test("a span is served only when every chunk of it is on disk")
    func partialSpanMisses() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: 2 * Self.chunk) == nil)
        tier.spill(offset: UInt64(Self.chunk), data: Self.pattern(2))
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: 2 * Self.chunk) == Self.pattern(1) + Self.pattern(2))
    }

    @Test("the file holds ciphertext, never the chunk itself")
    func storedBytesAreEncrypted() {
        let (tier, file, queue) = makeTier(slots: 4)
        let plain = Self.pattern(7)
        tier.spill(offset: 0, data: plain)
        queue.sync {}
        #expect(file.writes == 2, "ciphertext and tag")
        #expect(!file.stores(plain))
    }

    /// The LUN's last chunk is short when its size is not a multiple of the
    /// chunk size.
    @Test("a short final chunk round-trips at its own length")
    func shortChunk() {
        let (tier, _, queue) = makeTier(slots: 4)
        let tail = Self.pattern(3, 1000)
        tier.spill(offset: UInt64(8 * Self.chunk), data: tail)
        queue.sync {}
        #expect(tier.lookup(offset: UInt64(8 * Self.chunk), length: 1000) == tail)
        #expect(tier.lookup(offset: UInt64(8 * Self.chunk), length: Self.chunk) == nil)
    }

    @Test("the slots never outgrow the budget")
    func budgetIsRespected() {
        let (tier, file, queue) = makeTier(slots: 3)
        for i in 0 ..< 5 { tier.spill(offset: UInt64(i * Self.chunk), data: Self.pattern(UInt8(i))) }
        queue.sync {}
        #expect(tier.slotCount == 3)
        #expect(file.extent <= Int64(3 * Self.stride))
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil, "oldest evicted")
        #expect(tier.lookup(offset: UInt64(4 * Self.chunk), length: Self.chunk) == Self.pattern(4))
    }

    @Test("re-spilling a chunk already on disk writes nothing")
    func unchangedChunkIsNotRewritten() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(file.writes == 2)
        #expect(tier.stats.spilled == 1)
    }

    @Test("a chunk hit on disk survives a scan of new chunks")
    func hitChunkSurvivesScan() {
        let (tier, _, queue) = makeTier(slots: 5)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        _ = tier.lookup(offset: 0, length: Self.chunk)
        for i in 1 ... 20 { tier.spill(offset: UInt64(i * Self.chunk), data: Self.pattern(UInt8(i))) }
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: Self.chunk) == Self.pattern(1))
    }

    // MARK: - Coherence

    @Test("an invalidated chunk misses, and its neighbours stay")
    func invalidateIsPrecise() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        tier.spill(offset: UInt64(Self.chunk), data: Self.pattern(2))
        queue.sync {}
        tier.invalidate(offset: 10, length: 100)
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(tier.lookup(offset: UInt64(Self.chunk), length: Self.chunk) == Self.pattern(2))
    }

    /// The race the tickets exist for: a spill queued before a write must not
    /// land after the write's invalidation and serve pre-write bytes.
    @Test("a pending spill cancelled by an invalidation never lands")
    func invalidationCancelsPendingSpill() {
        let (tier, file, queue) = makeTier(slots: 4)
        queue.suspend()
        tier.spill(offset: 0, data: Self.pattern(1))
        tier.invalidate(offset: 0, length: Self.chunk)
        queue.resume()
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(file.writes == 0)
        #expect(tier.stats.spilled == 0)
    }

    // MARK: - Writes in flight (review finding: Critical #1)

    @Test("a chunk being written is never spilled")
    func noSpillWhileFenced() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.beginWrite(offset: 0, length: Self.chunk)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        tier.endWrite(offset: 0, length: Self.chunk)
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(file.writes == 0)
    }

    @Test("a chunk being written is never served, and is gone once the write ends")
    func noLookupWhileFenced() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        tier.beginWrite(offset: 0, length: Self.chunk)
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        tier.endWrite(offset: 0, length: Self.chunk)
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
    }

    /// A lookup copies its slot and reads without the lock; a write that
    /// begins in between must still stop those bytes from being returned.
    @Test("a lookup whose chunk starts being written mid-read returns nothing")
    func lookupRechecksAfterReading() {
        let file = MemoryChunkFile()
        let (tier, _, queue) = makeTier(slots: 4, file: file)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        var once = true
        file.onRead = {
            guard once else { return }
            once = false
            tier.beginWrite(offset: 0, length: Self.chunk)
        }
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        file.onRead = nil
        tier.endWrite(offset: 0, length: Self.chunk)
    }

    @Test("overlapping writes keep a chunk fenced until the last one ends")
    func fencesCount() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.beginWrite(offset: 0, length: Self.chunk)
        tier.beginWrite(offset: 0, length: 100)
        tier.endWrite(offset: 0, length: 100)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.stats.spilled == 0, "still fenced by the first write")
        tier.endWrite(offset: 0, length: Self.chunk)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: Self.chunk) == Self.pattern(1))
    }

    // MARK: - Resource bounds (review findings: Important #2-#4)

    @Test("spills beyond the queue cap are dropped, not buffered")
    func spillQueueIsBounded() {
        let (tier, _, queue) = makeTier(slots: 100)
        queue.suspend()
        for i in 0 ..< 70 { tier.spill(offset: UInt64(i * Self.chunk), data: Self.pattern(UInt8(i))) }
        queue.resume()
        queue.sync {}
        #expect(tier.stats.spilled == DiskChunkTier.maxQueuedSpills)
    }

    @Test("releasing the tier returns its space and turns it off quietly")
    func releaseReturnsSpace() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        tier.release()
        #expect(file.discarded)
        #expect(tier.stats.disabledReason == "detached")
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
    }

    /// Free space is rechecked as the file grows, not only at attach: two
    /// tiers sized against the same free space, or other apps filling the
    /// disk, must not take the boot volume below the reserve.
    @Test("the tier stops growing once free space reaches the reserve")
    func growthStopsAtReserve() {
        var checks = 0
        let file = MemoryChunkFile()
        let queue = DispatchQueue(label: "test.growth")
        let tier = DiskChunkTier(
            file: file, budgetBytes: 100 * Self.stride, chunkBytes: Self.chunk, spillQueue: queue,
            freeSpace: {
                checks += 1
                return checks == 1 ? DiskChunkTier.reserveBytes + (1 << 30) : DiskChunkTier.reserveBytes
            },
            growthCheckSlots: 4)
        for i in 0 ..< 20 { tier.spill(offset: UInt64(i * Self.chunk), data: Self.pattern(UInt8(i))) }
        queue.sync {}
        #expect(file.extent <= Int64(4 * Self.stride))
        #expect(tier.lookup(offset: UInt64(19 * Self.chunk), length: Self.chunk) == Self.pattern(19))
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
    }

    // MARK: - Never more than a miss

    @Test("a tampered slot is a miss, freed and counted, never data")
    func tamperedSlotIsAMiss() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        file.tamper = true
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(tier.stats.corrupt == 1)
        file.tamper = false
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil, "the slot was freed")
    }

    /// A lookup copies its slot under the lock and reads without it. Here the
    /// only slot is evicted and rewritten for another chunk mid-read:
    /// authentication fails (the AAD names the chunk asked for), and that is a
    /// plain miss — not corruption, and the new owner keeps its slot.
    @Test("a slot reused mid-read is a plain miss, not corruption")
    func slotReusedMidRead() {
        let file = MemoryChunkFile()
        let (tier, _, queue) = makeTier(slots: 1, file: file)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        var once = true
        file.onRead = {
            guard once else { return }
            once = false
            tier.spill(offset: UInt64(Self.chunk), data: Self.pattern(2))
            queue.sync {}
        }
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        file.onRead = nil
        #expect(tier.stats.corrupt == 0)
        #expect(tier.lookup(offset: UInt64(Self.chunk), length: Self.chunk) == Self.pattern(2))
    }

    @Test("a write failure disables the tier and returns its space")
    func writeFailureDisables() {
        let (tier, file, queue) = makeTier(slots: 4)
        file.failWrites = true
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.stats.disabledReason != nil)
        #expect(file.discarded)
        file.failWrites = false
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        let readsBefore = file.reads
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(file.reads == readsBefore, "a disabled tier never touches its file")
    }

    @Test("a read failure disables the tier")
    func readFailureDisables() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        file.failReads = true
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(tier.stats.disabledReason != nil)
    }

    // MARK: - The real file, and sizing

    @Test("the cache file is gone from the directory the moment it exists")
    func fileIsUnlinked() throws {
        let dir = try temporaryDirectory()
        let file = try UnlinkedFile(directory: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        try file.write(Data([1, 2, 3]), at: 8192)
        #expect(try file.read(at: 8192, count: 3) == Data([1, 2, 3]))
    }

    @Test("two tiers in one process keep their own files and bytes")
    func twoTiersDoNotMix() throws {
        let dir = try temporaryDirectory()
        let qa = DispatchQueue(label: "a"), qb = DispatchQueue(label: "b")
        let a = DiskChunkTier(file: try UnlinkedFile(directory: dir), budgetBytes: 4 * Self.stride,
                              chunkBytes: Self.chunk, spillQueue: qa)
        let b = DiskChunkTier(file: try UnlinkedFile(directory: dir), budgetBytes: 4 * Self.stride,
                              chunkBytes: Self.chunk, spillQueue: qb)
        a.spill(offset: 0, data: Self.pattern(1))
        b.spill(offset: 0, data: Self.pattern(2))
        qa.sync {}; qb.sync {}
        #expect(a.lookup(offset: 0, length: Self.chunk) == Self.pattern(1))
        #expect(b.lookup(offset: 0, length: Self.chunk) == Self.pattern(2))
    }

    @Test("the tier is sized to free space minus the reserve")
    func sizedToFreeSpace() throws {
        let dir = try temporaryDirectory()
        let result = DiskChunkTier.make(directory: dir, budgetBytes: 16 << 30, chunkBytes: 256 << 10,
                                        freeSpace: { _ in 12 << 30 })
        let tier = try result.get()
        // 2 GiB of slots, each a 256 KiB chunk plus a 4 KiB tag page.
        #expect(tier.capacityBytes <= 2 << 30)
        #expect(tier.capacityBytes > (2 << 30) * 9 / 10)
    }

    @Test("too little free space leaves the tier off")
    func tooLittleSpace() throws {
        let dir = try temporaryDirectory()
        let result = DiskChunkTier.make(directory: dir, budgetBytes: 4 << 30, chunkBytes: 256 << 10,
                                        freeSpace: { _ in (10 << 30) + (512 << 20) })
        guard case .failure(.tooLittleSpace) = result else {
            Issue.record("expected tooLittleSpace, got \(result)")
            return
        }
    }
}
