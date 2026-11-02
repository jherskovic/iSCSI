import Foundation
import Testing
@testable import iSCSIKit

/// The read-around controller decides what a cache miss fetches around its
/// request. Each test plays a workload whose cheapest unit can be worked out
/// by hand from the cost model (round trips, plus bytes at `roundTripBytes`
/// per trip) and checks the controller lands on it.
@Suite("Read-around controller")
struct ReadAroundControllerTests {
    static let sector = 4096
    static let chunk = 256 << 10
    static let sectorsPerChunk = chunk / sector

    private func make(ghostChunks: Int = 128) -> ReadAroundController {
        ReadAroundController(sectorBytes: Self.sector, chunkBytes: Self.chunk, ghostChunks: ghostChunks)!
    }

    /// Play reads the way the cache does — the gap first, then the read —
    /// 50 ms apart, so every 20 reads are one second of activity.
    private func play(_ c: inout ReadAroundController, _ reads: [(offset: UInt64, length: Int)]) {
        for r in reads {
            c.advance(sinceLastReadNanos: 50_000_000)
            c.observe(offset: r.offset, length: r.length)
        }
    }

    /// One 4 KiB read at `sector` of chunk `chunk`.
    private func at(_ chunk: Int, _ sector: Int) -> (offset: UInt64, length: Int) {
        (UInt64(chunk * Self.chunk + sector * Self.sector), Self.sector)
    }

    // MARK: - Geometry

    @Test("there is nothing to choose when the chunk is one sector or not a power-of-two count of them")
    func refusesGeometriesItCannotExpress() {
        #expect(ReadAroundController(sectorBytes: 4096, chunkBytes: 4096, ghostChunks: 1) == nil)
        #expect(ReadAroundController(sectorBytes: 4096, chunkBytes: 3 * 4096, ghostChunks: 1) == nil)
        #expect(ReadAroundController(sectorBytes: 512, chunkBytes: 256 << 10, ghostChunks: 1) == nil,
                "512 sectors to a chunk is more than one bitmap word")
        #expect(ReadAroundController(sectorBytes: 0, chunkBytes: 4096, ghostChunks: 1) == nil)
    }

    @Test("it starts at the whole chunk, with one candidate unit per doubling")
    func startsAtTheWholeChunk() {
        let c = make()
        #expect(c.unitBytes == Self.chunk)
        #expect(c.levels == 7, "4, 8, 16, 32, 64, 128 and 256 KiB")
    }

    // MARK: - Decisions

    /// Issue #4's workload. Per read: 4 KiB costs 1 + 4/128 = 1.03 trips,
    /// 256 KiB costs 1 + 256/128 = 3.
    @Test("scattered 4 KiB reads bring the unit down to one sector")
    func scatterShrinksToTheSector() {
        var c = make()
        play(&c, (0 ..< 40).map { at($0 * 7, $0 % Self.sectorsPerChunk) })
        #expect(c.unitBytes == Self.sector)
    }

    /// Every sector of each chunk, in a shuffled order so no stream forms.
    /// Per chunk: 4 KiB costs 64 trips; 256 KiB costs 1 + 2 = 3.
    @Test("reads that cover each chunk keep the whole chunk")
    func densityKeepsTheWholeChunk() {
        var c = make()
        var reads: [(offset: UInt64, length: Int)] = []
        for chunk in 0 ..< 3 {
            for s in (0 ..< Self.sectorsPerChunk).map({ ($0 * 37) % Self.sectorsPerChunk }) {
                reads.append(at(chunk, s))
            }
        }
        play(&c, reads)
        #expect(c.lastCosts != nil, "the window must have been evaluated for this test to mean anything")
        #expect(c.unitBytes == Self.chunk)
    }

    /// Two touches, at opposite ends of each chunk: 4 KiB costs 2.06 trips,
    /// 128 KiB fetches both halves (2 + 2 = 4), 256 KiB costs 3.
    @Test("two far-apart reads per chunk are not worth a whole-chunk fetch")
    func twoScatteredTouchesShrink() {
        var c = make()
        var reads: [(offset: UInt64, length: Int)] = []
        for chunk in 0 ..< 30 { reads += [at(chunk, 0), at(chunk, 40)] }
        play(&c, reads)
        #expect(c.unitBytes == Self.sector)
    }

    /// Four reads inside one aligned 16 KiB of each chunk, out of order:
    /// 4 KiB costs 4.1 trips, 16 KiB costs 1 + 16/128 = 1.125, and 256 KiB 3.
    @Test("reads clustered inside 16 KiB settle on a 16 KiB unit")
    func clusteredReadsPickTheClusterSize() {
        var c = make()
        var reads: [(offset: UInt64, length: Int)] = []
        for chunk in 0 ..< 15 { reads += [10, 8, 11, 9].map { at(chunk, $0) } }
        play(&c, reads)
        #expect(c.unitBytes == 16 << 10)
    }

    /// The property a controller judged by its own hit rate would not have:
    /// at the floor, it still knows what bigger units would have cost.
    @Test("from one sector, dense reads bring the whole chunk back")
    func recoversFromTheFloor() {
        var c = make()
        play(&c, (0 ..< 40).map { at($0 * 7, 3) })
        #expect(c.unitBytes == Self.sector)
        var reads: [(offset: UInt64, length: Int)] = []
        for chunk in 1000 ..< 1004 {
            for s in (0 ..< Self.sectorsPerChunk).map({ ($0 * 37) % Self.sectorsPerChunk }) {
                reads.append(at(chunk, s))
            }
        }
        play(&c, reads)
        #expect(c.unitBytes == Self.chunk)
    }

    /// 70% of chunks see three far-apart reads, 30% see two: 4 KiB averages
    /// ~2.78 trips per chunk against 3 for the whole chunk — cheaper, but not
    /// by the 10% a switch needs.
    @Test("a unit only slightly cheaper than the current one is not adopted")
    func hysteresisHoldsNearTies() throws {
        var c = make()
        var reads: [(offset: UInt64, length: Int)] = []
        for chunk in 0 ..< 40 {
            reads += (chunk % 10 < 7 ? [0, 21, 42] : [0, 42]).map { at(chunk, $0) }
        }
        play(&c, reads)
        let costs = try #require(c.lastCosts)
        #expect(costs[0] < costs[6], "one sector is the cheaper unit here")
        #expect(c.unitBytes == Self.chunk, "but not cheaper by enough to move")
    }

    // MARK: - Evidence

    @Test("nothing changes until the window holds enough reads")
    func declinesOnTooFewReads() {
        var c = make()
        // A second of activity carrying ten reads, under the minimum of twenty.
        for i in 0 ..< 10 {
            c.advance(sinceLastReadNanos: 100_000_000)
            c.observe(offset: UInt64(i * 7 * Self.chunk), length: Self.sector)
        }
        c.advance(sinceLastReadNanos: 100_000_000)
        #expect(c.lastCosts == nil)
        #expect(c.unitBytes == Self.chunk)
    }

    @Test("an idle gap counts for no more than a tenth of a second")
    func idleGapIsNotActivity() {
        var c = make()
        for i in 0 ..< 30 { c.observe(offset: UInt64(i * 7 * Self.chunk), length: Self.sector) }
        let changed = c.advance(sinceLastReadNanos: 60_000_000_000)
        #expect(!changed, "a minute asleep is 100 ms of activity")
        #expect(c.lastCosts == nil)
        for _ in 0 ..< 9 { c.advance(sinceLastReadNanos: 100_000_000) }
        #expect(c.lastCosts != nil, "ten capped gaps make the second")
    }

    /// A read crossing a chunk boundary is one fetch on the wire whatever
    /// the unit, and must be scored as one: two new chunks per read at 4 KiB
    /// is 1 trip + 2 sectors, so 30 reads in the newest second weigh
    /// 0.6 × (30 + 60/32).
    @Test("a read across a chunk boundary is one round trip")
    func boundaryReadIsOneTrip() throws {
        var c = make()
        for i in 0 ..< 30 {
            let boundary = UInt64((2 * i + 1) * Self.chunk)
            c.observe(offset: boundary - UInt64(Self.sector), length: 2 * Self.sector)
        }
        let costs = try #require(c.costs)
        #expect(abs(costs[0] - 0.6 * (30 + 60.0 / 32)) < 1e-9)
    }

    @Test("a chunk the ghost still holds is a hit at every unit; one it has forgotten is a miss")
    func ghostCapacityBoundsResidency() throws {
        // Twenty re-reads of one sector: one trip at every unit.
        var held = make(ghostChunks: 4)
        for _ in 0 ..< 20 { held.observe(offset: 0, length: Self.sector) }
        let heldCosts = try #require(held.costs)
        #expect(abs(heldCosts[0] - 0.6 * (1 + 1.0 / 32)) < 1e-9)

        // The same twenty reads cycled over five chunks with room for four:
        // each one has been forgotten by the time it comes round again.
        var forgotten = make(ghostChunks: 4)
        for i in 0 ..< 20 { forgotten.observe(offset: UInt64((i % 5) * Self.chunk), length: Self.sector) }
        let forgottenCosts = try #require(forgotten.costs)
        #expect(abs(forgottenCosts[0] - 0.6 * (20 + 20.0 / 32)) < 1e-9)
    }

    @Test("a starting unit that is not a power-of-two count of sectors is ignored")
    func startRejectsOddUnits() {
        var c = make()
        c.start(atUnitBytes: 3 * Self.sector)
        #expect(c.unitBytes == Self.chunk)
        c.start(atUnitBytes: 8 * Self.sector)
        #expect(c.unitBytes == 8 * Self.sector)
    }
}
