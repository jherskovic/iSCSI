//
//  GeometryValidationTests.swift
//  Regression tests for the READ CAPACITY(16) parser.
//
//  Every case below aborted the process before `geometry(fromReadCapacity16:)`
//  existed — not "returned a wrong answer", but killed a root daemon with one
//  reply. Swift's `+` and `*` trap on overflow, and the four lines this parser
//  replaced used the trapping operators on numbers taken straight off the wire.
//  They are unit tests rather than integration tests because the parser is pure,
//  which is also what finally made this surface fuzzable.
//

import Foundation
import Testing
@testable import iSCSIKit

@Suite("READ CAPACITY(16) geometry validation")
struct GeometryValidationTests {

    /// A well-formed 32-byte READ CAPACITY(16) Data-In.
    private func reply(lastLBA: UInt64, blockSize: UInt32) -> Data {
        var d = Data(count: 32)
        withUnsafeBytes(of: lastLBA.bigEndian) { src in
            for i in 0 ..< 8 { d[i] = src[i] }
        }
        withUnsafeBytes(of: blockSize.bigEndian) { src in
            for i in 0 ..< 4 { d[8 + i] = src[i] }
        }
        return d
    }

    @Test("ordinary geometry parses")
    func happyPath() throws {
        let (bs, count) = try ISCSIBlockDevice.geometry(
            fromReadCapacity16: reply(lastLBA: 2_097_151, blockSize: 512))
        #expect(bs == 512)
        #expect(count == 2_097_152)
    }

    @Test("4K native parses")
    func fourKNative() throws {
        let (bs, count) = try ISCSIBlockDevice.geometry(
            fromReadCapacity16: reply(lastLBA: 999, blockSize: 4096))
        #expect(bs == 4096)
        #expect(count == 1000)
    }

    /// B2. Eight 0xFF bytes made `lastLBA + 1` overflow a trapping add. This is
    /// the whole exploit: one reply, no groundwork, and `DaemonCore.login` calls
    /// READ CAPACITY on every login so it landed on the first command.
    @Test("an all-ones last LBA is refused rather than overflowing")
    func allOnesLastLBA() {
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: .max, blockSize: 512))
        }
    }

    /// The divide-by-zero half: `maxTransferBytes / blockSize` on any path that
    /// did not go through `validate`, which `iscsictl` did not.
    @Test("a zero block size is refused")
    func zeroBlockSize() {
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: 1023, blockSize: 0))
        }
    }

    /// B3. blockSize x blockCount is exactly 2^64 here, which trapped in the
    /// FSKit extension *before* its own `> 0` guard could run — killing the
    /// extension mid-mount, so the volume wedged instead of failing cleanly.
    /// Note this lastLBA deliberately does not trip the B2 check.
    @Test("a block count that overflows the byte count is refused")
    func byteCountOverflow() {
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: (1 << 48) - 1, blockSize: 65536))
        }
    }

    /// B6, and the reason the power-of-two rule is load-bearing rather than
    /// tidy. `BlockAligner.alignUp` computes `((v &+ blockSize &- 1) / blockSize)
    /// * blockSize`. For a power of two the largest multiple below 2^64 leaves
    /// exactly `blockSize - 1` of headroom, so the wrapping add cannot roll
    /// over. For 3 it can: 2^64-1 is itself a multiple of 3, leaving none.
    ///
    /// If this test is ever failing because someone widened the block-size rule,
    /// that change reopens a remote abort — re-run the sweep in
    /// `~/iSCSI-audit-2026-08-16/fuzz-harnesses/alignfuzz/fixcheck.swift`.
    @Test("a non-power-of-two block size is refused, which is what keeps alignUp safe")
    func nonPowerOfTwoBlockSize() {
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: 1023, blockSize: 3))
        }
        // 520 and 528 are real formats on DIF/DIX drives, and still refused:
        // the aligner's headroom argument does not hold for them either.
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: 1023, blockSize: 520))
        }
    }

    @Test("absurd block sizes are refused at both ends")
    func blockSizeBounds() {
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: 1023, blockSize: 256))
        }
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: 1023, blockSize: 1 << 21))
        }
        // 0xFFFFFFFF is the one that produced a 4 GiB zero-filled allocation per
        // outstanding command, before a single byte of Data-In had arrived.
        #expect(throws: BlockDeviceError.self) {
            try ISCSIBlockDevice.geometry(
                fromReadCapacity16: reply(lastLBA: 1023, blockSize: 0xFFFF_FFFF))
        }
    }

    @Test("a truncated reply is refused rather than read past its end")
    func truncatedReply() {
        for n in 0 ..< 12 {
            #expect(throws: BlockDeviceError.self) {
                try ISCSIBlockDevice.geometry(fromReadCapacity16: Data(count: n))
            }
        }
    }

    /// The parser must survive anything, since every byte is target-supplied.
    /// A cheap stand-in for the fuzzers, so `swift test` alone would have caught
    /// all of the above.
    @Test("no input traps the parser")
    func noInputTraps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 20_000 {
            let n = Int.random(in: 0 ... 40, using: &rng)
            let bytes = (0 ..< n).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
            _ = try? ISCSIBlockDevice.geometry(fromReadCapacity16: Data(bytes))
        }
        // Plus the corners a random sweep will essentially never hit.
        let lastLBAs: [UInt64] = [.max, .max - 1, 0, 1, 1 << 63]
        let blockSizes: [UInt32] = [0, 1, 511, 512, 4096, .max, 1 << 20]
        for lastLBA in lastLBAs {
            for blockSize in blockSizes {
                _ = try? ISCSIBlockDevice.geometry(
                    fromReadCapacity16: reply(lastLBA: lastLBA, blockSize: blockSize))
            }
        }
    }
}
