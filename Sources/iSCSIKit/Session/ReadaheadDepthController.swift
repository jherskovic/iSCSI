import Foundation

/// Chooses the speculation depth cap from what speculation is actually costing,
/// instead of asking the user to guess.
///
/// The per-target workload rungs this replaces were measured against a 256 KiB
/// soak on real hardware, and the measurement is why they are gone: hit rate
/// was flat at 93% across a 16x range of depth, and throughput tracked the
/// array's state — up to 2.4x day over day, 48% within one morning at a fixed
/// depth — rather than the setting. The only thing depth reliably changed was
/// wasted bandwidth, which rose roughly linearly with it (5.9% of speculative
/// chunks unused at depth 2, 11.1% at 4, 32.4% at 16, 48.8% at 32) and which
/// reproduced to the digit across runs. A setting whose options differ only in
/// how much bandwidth they waste is not a choice worth offering.
///
/// So: raise depth while speculation is paying off, cut it when it is not.
/// A pure stream uses everything it speculates and earns more depth; scattered
/// or write-punctuated I/O strands speculation and loses it.
///
/// Additive increase, multiplicative decrease — the standard shape for a
/// control loop that must converge rather than oscillate. Doubling on the way
/// up against halving on the way down would hunt across the deadband forever.
///
/// Pure state and no clock of its own: the caller feeds it elapsed time, which
/// is what makes every rule here testable without a mounted volume.
public struct ReadaheadDepthController: Sendable {

    /// Above this share of settled speculation being wasted, depth is costing
    /// more than it returns.
    public static let highWaterMark = 0.15
    /// Below this, speculation is nearly all being used and there is room to
    /// reach further.
    public static let lowWaterMark = 0.06
    /// Settled chunks the window must hold before any adjustment. A VM guest
    /// resolves only a handful per second; 80% waste on five chunks is noise.
    public static let minSamples = 20
    /// Never speculate less than this. At depth 1 the mechanism is off, and the
    /// extension measured 206 MB/s with no readahead against 1099 with it.
    public static let floor = 2

    private static let bucketNanos: UInt64 = 1_000_000_000
    /// The longest gap between two reads that still counts as the volume being
    /// busy. Under load, reads are milliseconds apart and this never binds;
    /// when nobody is using the volume it is the whole point, capping an
    /// arbitrarily long silence at a tenth of a second so an idle volume
    /// neither advances the window nor is steered by counts from before it went
    /// quiet.
    private static let idleCapNanos: UInt64 = 100_000_000

    /// Most recent second first. Weights below line up with this order.
    private static let weights = [0.6, 0.3, 0.1]

    private var buckets = [(used: 0, wasted: 0), (used: 0, wasted: 0), (used: 0, wasted: 0)]
    private var activeNanos: UInt64 = 0

    public private(set) var cap: Int
    /// The weighted waste share the last evaluation acted on, or nil if it
    /// declined to act. Exposed because `cap` alone cannot distinguish "saw 4%
    /// and raised depth" from "saw 0% and raised depth" — and the difference
    /// between those is exactly whether the window is weighted over the seconds
    /// it claims to be.
    public private(set) var lastEvaluatedShare: Double?
    private let ceiling: Int

    public init(initialCap: Int, ceiling: Int) {
        self.ceiling = max(Self.floor, ceiling)
        self.cap = min(max(initialCap, Self.floor), self.ceiling)
    }

    /// A speculative chunk reached a terminal state: read at least once before
    /// it left the cache, or evicted having never been wanted. Chunks still
    /// resident are deliberately not counted — see `Stats.resolvedUsed`.
    public mutating func recordResolved(used: Int, wasted: Int) {
        buckets[0].used += used
        buckets[0].wasted += wasted
    }

    /// Feed the gap since the previous read. Rolls the window and re-evaluates
    /// each time a second of *activity* has accumulated.
    @discardableResult
    public mutating func advance(sinceLastReadNanos: UInt64) -> Bool {
        activeNanos &+= min(sinceLastReadNanos, Self.idleCapNanos)
        guard activeNanos >= Self.bucketNanos else { return false }
        activeNanos -= Self.bucketNanos
        // Evaluate *before* rolling, while the second that just completed is
        // still index 0 and so carries the 0.6 weight. Rolling first would put
        // that weight on the new, empty bucket, slide the real seconds to
        // 0.3/0.1, and drop the oldest one — a two-second window at 0.75/0.25
        // wearing three-second weights.
        adjust()
        buckets = [(used: 0, wasted: 0), buckets[0], buckets[1]]
        return true
    }

    /// The weighted waste share over the window, or nil when the window holds
    /// too little to act on.
    public var wasteShare: Double? {
        let settled = buckets.reduce(0) { $0 + $1.used + $1.wasted }
        guard settled >= Self.minSamples else { return nil }
        // Weighted over *counts*, not over per-bucket ratios: a second holding
        // three chunks must not outvote one holding three hundred.
        var wasted = 0.0, total = 0.0
        for (i, b) in buckets.enumerated() {
            wasted += Self.weights[i] * Double(b.wasted)
            total += Self.weights[i] * Double(b.used + b.wasted)
        }
        guard total > 0 else { return nil }
        return wasted / total
    }

    private mutating func adjust() {
        lastEvaluatedShare = wasteShare
        guard let share = wasteShare else { return }
        if share > Self.highWaterMark {
            cap = max(Self.floor, cap / 2)
        } else if share < Self.lowWaterMark {
            cap = min(ceiling, cap + 1)
        }
    }
}
