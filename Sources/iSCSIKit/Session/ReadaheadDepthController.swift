import Foundation

/// Chooses the speculation depth cap from what speculation is actually
/// costing: measured, depth changed only wasted bandwidth (hit rate stayed
/// flat), so raise it while speculation pays off and cut it when it doesn't
/// (docs/soak-results-0.4.0.md). Additive increase, multiplicative decrease,
/// so the loop converges instead of hunting across the deadband.
///
/// Pure state and no clock of its own — the caller feeds it elapsed time,
/// which is what makes every rule testable without a mounted volume.
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
    /// Never speculate less than this; at depth 1 the mechanism is off, which
    /// measured ~5x slower.
    public static let floor = 2

    private static let bucketNanos: UInt64 = 1_000_000_000
    /// Longest read gap that still counts as activity: an idle volume must
    /// neither advance the window nor be steered by counts from before it
    /// went quiet.
    private static let idleCapNanos: UInt64 = 100_000_000

    /// Most recent second first. Weights below line up with this order.
    private static let weights = [0.6, 0.3, 0.1]

    private var buckets = [(used: 0, wasted: 0), (used: 0, wasted: 0), (used: 0, wasted: 0)]
    private var activeNanos: UInt64 = 0

    public private(set) var cap: Int
    /// The weighted waste share the last evaluation acted on (nil: declined).
    /// Exposed so tests can see the window weighting, which `cap` alone hides.
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
        // Evaluate *before* rolling, while the just-completed second is still
        // index 0 and carries the 0.6 weight.
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
