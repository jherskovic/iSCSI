import Foundation
import Testing
@testable import iSCSIKit

/// The depth controller replaces the per-target workload rungs. Those asked the
/// user to choose between settings that measurement showed differ only in
/// wasted bandwidth — hit rate was flat at 93% across a 16x range of depth, and
/// throughput tracked array state rather than the setting. Nobody would
/// knowingly choose more waste, so the choice belongs to the machine.
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

    @Test("waste below the low-water mark raises the depth by one")
    func lowWasteRaisesDepthAdditively() {
        var c = ReadaheadDepthController(initialCap: 8, ceiling: 32)
        activeSecond(&c, used: 98, wasted: 2)    // 2%
        #expect(c.cap == 9, "additive increase — a doubling here would oscillate against the halving")
        activeSecond(&c, used: 98, wasted: 2)
        #expect(c.cap == 10)
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
    /// Asserting on the share rather than on `cap`: both orderings happen to
    /// move `cap` the same way on most inputs, which is how the original bug
    /// survived seven tests. The share is the number the loop acted on, and it
    /// differs unambiguously — 10% correctly weighted, 0% one slot late,
    /// because the only wasteful second has fallen out of the window.
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
        // Oldest second: tiny sample, all waste. Most recent: large sample,
        // no waste. Weighted by count this is far under the low-water mark;
        // weighted by ratio the 0.1 * 100% tail would drag it upward.
        activeSecond(&c, used: 0, wasted: 3)
        activeSecond(&c, used: 0, wasted: 3)
        activeSecond(&c, used: 400, wasted: 0)
        #expect(c.cap == 17, "the large recent sample should dominate and raise depth")
    }
}
