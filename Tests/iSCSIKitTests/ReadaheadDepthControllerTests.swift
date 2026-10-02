import Foundation
import Testing
@testable import iSCSIKit

/// The depth controller replaces the per-target workload rungs: hit rate is
/// flat across a 16× depth range, so waste is the only signal and the choice
/// belongs to the machine.
@Suite("Readahead depth controller")
struct ReadaheadDepthControllerTests {

    /// One second of *activity*: ten reads 100 ms apart. Anything longer than
    /// the idle cap between reads is not activity and must not advance the
    /// window, which is what `idleGapDoesNotAdvanceTheWindow` pins down.
    private func activeSecond(_ c: inout ReadaheadDepthController,
                              used: Int = 0, wasted: Int = 0) {
        c.recordResolved(used: used, wasted: wasted)
        for _ in 0 ..< 10 { c.advance(sinceLastReadNanos: 100_000_000) }
    }

    @Test("waste inside the deadband leaves depth alone")
    func steadyStateHolds() {
        var c = ReadaheadDepthController(initialCap: 8, ceiling: 32)
        // 10% waste: above the 6% floor, below the 15% trigger.
        for _ in 0 ..< 4 { activeSecond(&c, used: 90, wasted: 10) }
        #expect(c.cap == 8)
    }

    @Test("waste above the high-water mark halves the depth")
    func highWasteHalvesDepth() {
        var c = ReadaheadDepthController(initialCap: 16, ceiling: 32)
        activeSecond(&c, used: 70, wasted: 30)   // 30%
        #expect(c.cap == 8)
        activeSecond(&c, used: 70, wasted: 30)
        #expect(c.cap == 4)
    }

    @Test("waste between the stream mark and the low-water mark raises the depth by one")
    func lowWasteRaisesDepthAdditively() {
        var c = ReadaheadDepthController(initialCap: 8, ceiling: 32)
        activeSecond(&c, used: 97, wasted: 3)    // 3%
        #expect(c.cap == 9, "a mixed workload creeps up; only a clean stream earns a doubling")
        activeSecond(&c, used: 97, wasted: 3)
        #expect(c.cap == 10)
    }

    /// The symptom this exists for: a big copy spent ~24 s of reading at +1/s
    /// climbing from the seed of 8 to the ceiling, while depth is what moves
    /// FSKit throughput (391 / 636 / 1099 MB/s at depths 4 / 16 / 32).
    @Test("a clean stream doubles depth from the floor to the ceiling")
    func cleanStreamDoublesToCeiling() {
        var c = ReadaheadDepthController(initialCap: 2, ceiling: 32)
        var caps: [Int] = []
        for _ in 0 ..< 4 {
            activeSecond(&c, used: 100, wasted: 0)
            caps.append(c.cap)
        }
        #expect(caps == [4, 8, 16, 32])
    }

    @Test("waste just under the stream mark still doubles")
    func nearlyCleanStreamDoubles() {
        var c = ReadaheadDepthController(initialCap: 8, ceiling: 32)
        activeSecond(&c, used: 99, wasted: 1)    // 1%
        #expect(c.cap == 16)
    }

    /// Why this is not TCP-style slow start, which grows additively for good
    /// after its first cut: a copy that starts after a VM workload has pulled
    /// depth down is exactly the case that was slow. The halving seconds stay
    /// in the window for a while — 12% (hold), then 3% (+1) — before the clean
    /// seconds alone decide it.
    @Test("a clean stream regains the ceiling after waste has halved depth")
    func cleanStreamRecoversAfterHalving() {
        var c = ReadaheadDepthController(initialCap: 16, ceiling: 32)
        activeSecond(&c, used: 70, wasted: 30)
        activeSecond(&c, used: 70, wasted: 30)
        #expect(c.cap == 4)
        for _ in 0 ..< 5 { activeSecond(&c, used: 100, wasted: 0) }
        #expect(c.cap == 32, "additive increase would have reached only 8")
    }

    /// A VM guest at ~80 reads/s resolves only a handful of chunks per second.
    /// Acting on a sample of three would thrash on noise.
    @Test("too few resolved chunks means no adjustment at all")
    func sampleFloorSuppressesAction() {
        var c = ReadaheadDepthController(initialCap: 8, ceiling: 32)
        for _ in 0 ..< 4 { activeSecond(&c, used: 1, wasted: 4) }  // 80% waste, 5 samples
        #expect(c.cap == 8, "80% waste on five chunks is noise, not evidence")
    }

    @Test("depth never falls below the floor or rises above the ceiling")
    func boundsAreRespected() {
        var low = ReadaheadDepthController(initialCap: 4, ceiling: 32)
        for _ in 0 ..< 10 { activeSecond(&low, used: 0, wasted: 100) }
        #expect(low.cap == 2)

        var high = ReadaheadDepthController(initialCap: 30, ceiling: 32)
        for _ in 0 ..< 10 { activeSecond(&high, used: 100, wasted: 0) }
        #expect(high.cap == 32)
    }

    /// The whole point of measuring active time rather than wall time: a volume
    /// nobody is using must not advance the window, and must not be steered by
    /// counts from before it went quiet.
    @Test("an idle gap does not advance the window")
    func idleGapDoesNotAdvanceTheWindow() {
        var c = ReadaheadDepthController(initialCap: 16, ceiling: 32)
        c.recordResolved(used: 0, wasted: 100)
        // An hour of nothing, delivered as one enormous gap: capped, so it
        // contributes a fraction of a second and rolls no bucket.
        c.advance(sinceLastReadNanos: 3_600_000_000_000)
        #expect(c.cap == 16, "an idle volume has no new evidence and must not be steered")
    }

    /// The most recent *completed* second must carry the 0.6 weight. Evaluating
    /// after rolling puts 0.6 on the fresh empty bucket, slides the real seconds
    /// to 0.3 and 0.1, and drops the oldest — a two-second window at 0.75/0.25
    /// wearing three-second weights.
    ///
    /// Asserts on the share, not `cap`: both orderings move `cap` the same
    /// way on most inputs. The share differs unambiguously — 10% correctly
    /// weighted, 0% one slot late.
    @Test("the newest completed second carries the 0.6 weight")
    func weightsCoverThreeCompletedSeconds() {
        var c = ReadaheadDepthController(initialCap: 16, ceiling: 32)
        activeSecond(&c, used: 0, wasted: 100)
        activeSecond(&c, used: 100, wasted: 0)
        activeSecond(&c, used: 100, wasted: 0)

        // 0.6·0 + 0.3·0 + 0.1·100, over 0.6·100 + 0.3·100 + 0.1·100.
        let share = try! #require(c.lastEvaluatedShare)
        #expect(abs(share - 0.10) < 1e-9,
                "one slot late this reads 0% — the oldest second falls out of the window")
    }

    /// Weighting the ratios instead of the counts would let a bucket holding
    /// three chunks outvote one holding three hundred.
    @Test("weighting applies to counts, not to per-second ratios")
    func weightsApplyToCounts() {
        var c = ReadaheadDepthController(initialCap: 16, ceiling: 32)
        // Oldest seconds: tiny samples, all waste. Most recent: large sample,
        // no waste. Weighted by count this is 0.5%, under the stream mark;
        // weighted by ratio the 0.3 + 0.1 all-waste tail reads 40% and halves.
        activeSecond(&c, used: 0, wasted: 3)
        activeSecond(&c, used: 0, wasted: 3)
        activeSecond(&c, used: 400, wasted: 0)
        #expect(c.cap == 32, "the large recent sample should dominate and raise depth")
    }
}
