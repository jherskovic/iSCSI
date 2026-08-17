import Foundation

/// Decides how far to read ahead of a stream, earning depth instead of
/// assuming it.
///
/// The readahead window used to open at full depth as soon as two consecutive
/// reads were consecutive. That is the right shape for a benchmark and the
/// wrong shape for a VM image: guest I/O is short sequential bursts that jump,
/// and every jump strands the whole window in flight — speculative reads that
/// cannot be recalled, queued at the target in front of the I/O that is real.
/// Worse, a write invalidated the window without resetting the stream, so the
/// read after the write re-issued the same ranges a second time.
///
/// So depth is earned exponentially, and only after a run has proven itself
/// for `minStreamBytes` of consecutive reads: then 2 chunks, 4, 8, ... up to
/// whichever comes first of the slot cap and the byte budget. A short burst
/// speculates nothing at all, while a genuinely sequential stream reaches
/// full depth within a handful of reads past the gate. Any out-of-sequence
/// read resets the ramp and the gate; a write (`reset()`) forgets the stream
/// entirely.
///
/// Depth is counted in fixed-size *chunks* (`chunkBytes`), not in caller
/// requests. Speculation is issued chunk-wise by `PrefetchChunkCache`, and a
/// budget divided by the caller's request size was wrong in both directions:
/// tiny requests opened hundreds of slots, huge ones pinned depth at 1.
///
/// Pure state, no locking — the caller serialises access. It lives here, like
/// `BlockAligner`, so the arithmetic can be tested without a mounted volume
/// and a live target.
public struct ReadaheadPolicy: Sendable {
    /// Most bytes of speculation in flight.
    public let budgetBytes: Int
    /// Most chunks in flight, however small the chunks are configured. Each
    /// is an outstanding daemon call and a buffer.
    public let maxSlots: Int
    /// Consecutive bytes a run must cover before the first speculation.
    ///
    /// The gate is in bytes, not requests, for the same reason the budget is:
    /// "two consecutive reads" is 512 KiB of evidence when a benchmark streams
    /// in 256 KiB pieces and 32 KiB of evidence when a VM guest reads in
    /// 16 KiB pieces. Measured under a real VM, the 32 KiB kind was wrong
    /// essentially always — a 12-minute window of interleaved 16 KiB reads and
    /// writes wasted 100% of what it speculated, because two small reads
    /// between writes kept re-opening a window the next write threw away. A
    /// byte threshold makes small requests earn proportionally more proof
    /// while leaving large-request streams exactly as fast to trigger.
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
