import os

/// How many calls are inside a section right now, and the most there have
/// ever been at once.
///
/// Why it exists: issue #4 measured QD16 no faster than QD1, with latency
/// growing in step with depth — reads served strictly one at a time somewhere
/// between APFS and the daemon. A peak of 1 at a layer, under a load that
/// issues many reads at once, says that layer was never handed two; a peak
/// above 1 says whatever serialises is below it. The summary line carries the
/// peaks so a mount answers that by itself (docs/open-questions.md item 17).
public final class InFlightGauge: Sendable {
    private struct Counts { var now = 0; var peak = 0 }
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    public init() {}

    public func enter() {
        counts.withLock { c in
            c.now += 1
            if c.now > c.peak { c.peak = c.now }
        }
    }

    public func leave() {
        counts.withLock { $0.now -= 1 }
    }

    /// The most calls ever inside at once.
    public var peak: Int { counts.withLock { $0.peak } }

    /// Calls inside right now.
    public var current: Int { counts.withLock { $0.now } }
}
