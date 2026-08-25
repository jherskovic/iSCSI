import Foundation

/// Decides how far to read ahead of a stream, earning depth instead of
/// assuming it: nothing until a run covers `minStreamBytes` of consecutive
/// reads, then 2, 4, 8, ... chunks up to the slot cap and byte budget. An
/// out-of-sequence read resets the ramp; a write (`reset()`) forgets the
/// stream — speculative reads cannot be recalled once queued at the target,
/// so a short burst must speculate nothing.
///
/// Depth is counted in fixed-size *chunks*, not caller requests: a budget
/// divided by request size opened hundreds of slots for tiny requests and
/// pinned huge ones at depth 1.
///
/// Pure state, no locking — the caller serialises access; testable without a
/// mounted volume.
public struct ReadaheadPolicy: Sendable {
    /// Most bytes of speculation in flight.
    public let budgetBytes: Int
    /// Most chunks in flight, however small the chunks are configured. Each
    /// is an outstanding daemon call and a buffer.
    public let maxSlots: Int
    /// Consecutive bytes a run must cover before the first speculation. In
    /// bytes, not requests: "two consecutive reads" is strong evidence from a
    /// 256 KiB streamer and none at all from a guest's 16 KiB reads, so small
    /// requests must earn proportionally more proof.
    public let minStreamBytes: Int
    /// The unit speculation is issued in.
    public let chunkBytes: Int

    /// Depth cap chosen by `ReadaheadDepthController`, when one is steering.
    /// nil leaves the budget in charge, which is what a target with an explicit
    /// `workloadProfile` override wants.
    public var adaptiveCap: Int?

    /// Most chunks allowed in flight: the controller's figure when it is
    /// steering, otherwise whatever the byte budget affords. `maxSlots` bounds
    /// both — it is a limit on outstanding XPC calls and buffers, so no policy
    /// may exceed it.
    public var chunkCap: Int {
        guard chunkBytes > 0 else { return 0 }
        if let adaptiveCap { return max(1, min(maxSlots, adaptiveCap)) }
        return max(1, min(maxSlots, budgetBytes / chunkBytes))
    }

    /// Reads granted depth since the gate opened: the ramp's exponent.
    private var rampStep = 0
    /// Bytes covered by the current consecutive run, this read included.
    private var runBytes = 0
    /// Where the previous read finished, which is the only evidence available
    /// that the next one continues it.
    private var lastServedEnd: UInt64?

    public init(budgetBytes: Int, maxSlots: Int, minStreamBytes: Int, chunkBytes: Int) {
        self.budgetBytes = budgetBytes
        self.maxSlots = maxSlots
        self.minStreamBytes = minStreamBytes
        self.chunkBytes = chunkBytes
    }

    /// Records a served read and returns how many chunks to keep in flight
    /// beyond it: nothing until the run both continues the previous read and
    /// has covered `minStreamBytes`, then 2, 4, ... doubling per consecutive
    /// read, capped by `chunkCap`. A read that does not continue the previous
    /// one returns 0 and demands fresh proof.
    public mutating func noteServed(offset: UInt64, length: Int) -> Int {
        guard length > 0 else { return 0 }
        let continues = (lastServedEnd == offset)
        runBytes = continues ? runBytes + length : length
        lastServedEnd = offset &+ UInt64(length)

        guard continues, runBytes >= minStreamBytes else {
            rampStep = 0
            return 0
        }
        rampStep += 1
        // Bounded shift: past 2^6 = 64 the cap has long since won, and a long
        // stream would otherwise walk the shift past 63 and trap.
        guard rampStep < 7 else { return chunkCap }
        return min(1 << rampStep, chunkCap)
    }

    /// Forget the stream. For writes: anything read ahead is now suspect, and
    /// the pattern that earned the depth ended with the write, so the next
    /// read starts from nothing rather than inheriting the old ramp.
    public mutating func reset() {
        rampStep = 0
        runBytes = 0
        lastServedEnd = nil
    }
}
