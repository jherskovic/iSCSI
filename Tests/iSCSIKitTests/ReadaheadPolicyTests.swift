import Foundation
import Testing
@testable import iSCSIKit

@Suite("Readahead ramp")
struct ReadaheadPolicyTests {
    // Production values: 8 MiB budget, 32 slots, 256 KiB chunks, speculation
    // only after 256 KiB of proven consecutive stream.
    static func makePolicy() -> ReadaheadPolicy {
        ReadaheadPolicy(budgetBytes: 8 << 20, maxSlots: 32,
                        minStreamBytes: 256 << 10, chunkBytes: 256 << 10)
    }

    /// A large sequential caller's request size.
    let req = 256 << 10

    @Test func firstReadPrefetchesNothing() {
        var p = Self.makePolicy()
        #expect(p.noteServed(offset: 0, length: req) == 0)
    }

    @Test func secondSequentialReadOpensTwoChunks() {
        var p = Self.makePolicy()
        _ = p.noteServed(offset: 0, length: req)
        #expect(p.noteServed(offset: UInt64(req), length: req) == 2)
    }

    @Test func rampDoublesPerSequentialRead() {
        var p = Self.makePolicy()
        var depths: [Int] = []
        for i in 0 ..< 7 {
            depths.append(p.noteServed(offset: UInt64(i * req), length: req))
        }
        // 256 KiB chunks against an 8 MiB budget allow 32 chunks, so the ramp
        // runs 0, 2, 4, 8, 16, 32 and then holds.
        #expect(depths == [0, 2, 4, 8, 16, 32, 32])
    }

    @Test func byteBudgetCapsRampForLargeChunks() {
        // 1 MiB chunks: the 8 MiB budget allows only 8 in flight, well under
        // the 32-slot cap — the ramp must flatten there.
        var p = ReadaheadPolicy(budgetBytes: 8 << 20, maxSlots: 32,
                                minStreamBytes: 256 << 10, chunkBytes: 1 << 20)
        let mib = 1 << 20
        var depths: [Int] = []
        for i in 0 ..< 6 {
            depths.append(p.noteServed(offset: UInt64(i * mib), length: mib))
        }
        #expect(depths == [0, 2, 4, 8, 8, 8])
    }

    @Test func outOfSequenceReadResetsToNothing() {
        var p = Self.makePolicy()
        for i in 0 ..< 4 {
            _ = p.noteServed(offset: UInt64(i * req), length: req)
        }
        // A jump: not where the stream left off.
        #expect(p.noteServed(offset: 1 << 30, length: req) == 0)
    }

    @Test func rampRestartsAfterJump() {
        var p = Self.makePolicy()
        for i in 0 ..< 4 {
            _ = p.noteServed(offset: UInt64(i * req), length: req)
        }
        let jump: UInt64 = 1 << 30
        _ = p.noteServed(offset: jump, length: req)
        // The ramp starts over: the read after the jump is worth 2, not 16.
        #expect(p.noteServed(offset: jump + UInt64(req), length: req) == 2)
    }

    @Test func repeatedReadIsNotSequential() {
        var p = Self.makePolicy()
        _ = p.noteServed(offset: 0, length: req)
        #expect(p.noteServed(offset: 0, length: req) == 0)
    }

    @Test func resetForgetsTheStreamEntirely() {
        var p = Self.makePolicy()
        for i in 0 ..< 4 {
            _ = p.noteServed(offset: UInt64(i * req), length: req)
        }
        p.reset() // a write landed
        // Even a read that continues the pre-write stream is a first read
        // again: nothing gets read ahead...
        #expect(p.noteServed(offset: UInt64(4 * req), length: req) == 0)
        // ...and the one after that re-enters the ramp at 2.
        #expect(p.noteServed(offset: UInt64(5 * req), length: req) == 2)
    }

    @Test func longStreakDoesNotOverflow() {
        var p = Self.makePolicy()
        var depth = 0
        // Far past 63 consecutive reads, where a naive 1 << streak would trap.
        for i in 0 ..< 200 {
            depth = p.noteServed(offset: UInt64(i * req), length: req)
        }
        #expect(depth == 32)
    }

    @Test func hugeRequestsStillRampInChunks() {
        var p = Self.makePolicy()
        let huge = 16 << 20
        // Speculation is issued in chunks, so a request bigger than the whole
        // budget no longer pins depth at 1 — the second consecutive read opens
        // the usual 2 chunks behind it.
        _ = p.noteServed(offset: 0, length: huge)
        #expect(p.noteServed(offset: UInt64(huge), length: huge) == 2)
    }

    @Test func zeroLengthReadIsIgnored() {
        var p = Self.makePolicy()
        _ = p.noteServed(offset: 0, length: req)
        // A degenerate zero-length read neither prefetches nor breaks the
        // stream it landed inside.
        #expect(p.noteServed(offset: UInt64(req), length: 0) == 0)
        #expect(p.noteServed(offset: UInt64(req), length: req) == 2)
    }

    @Test func smallRequestsNeedBytesOfProofNotJustTwoReads() {
        var p = Self.makePolicy()
        let small = 16 << 10
        // A 16 KiB stream: nothing opens until the run has covered 256 KiB
        // of proof — the 16th consecutive read.
        var depths: [Int] = []
        for i in 0 ..< 17 {
            depths.append(p.noteServed(offset: UInt64(i * small), length: small))
        }
        #expect(depths[0 ..< 15].allSatisfy { $0 == 0 })
        #expect(depths[15] == 2)
        #expect(depths[16] == 4)
    }

    @Test func shortBurstOfSmallReadsSpeculatesNothing() {
        var p = Self.makePolicy()
        let small = 16 << 10
        // The boot pattern: a handful of consecutive small reads, then a jump.
        for i in 0 ..< 5 {
            #expect(p.noteServed(offset: UInt64(i * small), length: small) == 0)
        }
    }

    @Test func jumpResetsTheBytesGate() {
        var p = Self.makePolicy()
        let small = 16 << 10
        for i in 0 ..< 16 {
            _ = p.noteServed(offset: UInt64(i * small), length: small)
        }
        let jump: UInt64 = 1 << 30
        #expect(p.noteServed(offset: jump, length: small) == 0)
        // The gate demands a fresh 256 KiB of proof, not just a continuation.
        #expect(p.noteServed(offset: jump + UInt64(small), length: small) == 0)
    }

    @Test func chunkCapMatchesBudgetArithmetic() {
        #expect(Self.makePolicy().chunkCap == 32)
        let big = ReadaheadPolicy(budgetBytes: 8 << 20, maxSlots: 32,
                                  minStreamBytes: 256 << 10, chunkBytes: 1 << 20)
        #expect(big.chunkCap == 8)
        let huge = ReadaheadPolicy(budgetBytes: 8 << 20, maxSlots: 32,
                                   minStreamBytes: 256 << 10, chunkBytes: 16 << 20)
        #expect(huge.chunkCap == 1)
    }
}
