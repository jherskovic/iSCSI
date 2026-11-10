import Foundation
import Testing
@testable import iSCSIKit

/// Which block size a LUN's GPT was written with, from its first 8 KiB —
/// the rule behind attaching a 4Kn disk so DiskImages finds its partitions
/// (GitHub issue #2).
@Suite("Partition table probe")
struct PartitionTableProbeTests {

    /// A GPT header as it lands on disk: "EFI PART", revision 1.0, a 92-byte
    /// header, and `myLBA` at offset 24.
    private func header(myLBA: UInt64 = 1) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 92)
        bytes.replaceSubrange(0 ..< 8, with: Array("EFI PART".utf8))
        bytes.replaceSubrange(8 ..< 12, with: [0x00, 0x00, 0x01, 0x00])
        bytes.replaceSubrange(12 ..< 16, with: [92, 0, 0, 0])
        withUnsafeBytes(of: myLBA.littleEndian) { bytes.replaceSubrange(24 ..< 32, with: $0) }
        return bytes
    }

    /// The first 8 KiB of a disk: a protective MBR in sector 0, and GPT
    /// headers wherever the case puts them.
    private func disk(headersAt offsets: [Int], myLBA: UInt64 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8192)
        bytes[450] = 0xEE                       // protective MBR partition type
        bytes[510] = 0x55; bytes[511] = 0xAA    // MBR signature
        for offset in offsets {
            bytes.replaceSubrange(offset ..< offset + 92, with: header(myLBA: myLBA))
        }
        return Data(bytes)
    }

    /// Primary headers exactly as `diskutil partitionDisk … GPT APFS` wrote
    /// them on a 64 MiB raw image attached at each block size (macOS 27.0,
    /// 2026-10-05). The rest of each 8 KiB prefix is a protective MBR and,
    /// for 512, the start of the entry array — zeros at byte 4096.
    private static let diskutilHeader512 =
        "4546492050415254000001005c000000bbede371000000000100000000000000ffff0100000000002200000000000000deff010000000000d5582abd3ed31f48848ebbe74bde59a702000000000000008000000080000000f4a9819f"
    private static let diskutilHeader4096 =
        "4546492050415254000001005c00000055c38c7b000000000100000000000000ff3f0000000000000600000000000000fa3f000000000000574fcccae4201b49a9e9059540dc5aeb02000000000000008000000080000000a61c668b"

    private func bytes(hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    @Test("the headers diskutil actually writes, at each block size")
    func diskutilHeaders() {
        for (hex, offset) in [(Self.diskutilHeader512, 512), (Self.diskutilHeader4096, 4096)] {
            var prefix = disk(headersAt: [])
            prefix.replaceSubrange(offset ..< offset + 92, with: bytes(hex: hex))
            #expect(PartitionTableProbe.gptBlockSize(prefix: prefix) == offset)
        }
    }

    @Test("a GPT written with 512-byte blocks — what this app's attach has always produced")
    func gpt512() {
        #expect(PartitionTableProbe.gptBlockSize(prefix: disk(headersAt: [512])) == 512)
    }

    @Test("a GPT written with 4096-byte blocks — a 4Kn LUN partitioned by a 4Kn-aware initiator")
    func gpt4096() {
        #expect(PartitionTableProbe.gptBlockSize(prefix: disk(headersAt: [4096])) == 4096)
    }

    @Test("a blank disk has no answer")
    func blank() {
        #expect(PartitionTableProbe.gptBlockSize(prefix: Data(count: 8192)) == nil)
    }

    @Test("a protective MBR alone has no answer")
    func protectiveMBROnly() {
        #expect(PartitionTableProbe.gptBlockSize(prefix: disk(headersAt: [])) == nil)
    }

    @Test("a signature whose header does not place itself at LBA 1 is not a primary GPT")
    func wrongMyLBA() {
        #expect(PartitionTableProbe.gptBlockSize(prefix: disk(headersAt: [4096], myLBA: 7)) == nil)
    }

    @Test("a buffer too short to hold a header is read as far as it goes")
    func shortBuffer() {
        let full = disk(headersAt: [4096])
        #expect(PartitionTableProbe.gptBlockSize(prefix: full.prefix(4100)) == nil)
        #expect(PartitionTableProbe.gptBlockSize(prefix: disk(headersAt: [512]).prefix(604)) == 512)
        #expect(PartitionTableProbe.gptBlockSize(prefix: Data()) == nil)
    }

    @Test("with valid headers at both offsets, 512 wins — the layout attached today")
    func bothOffsets() {
        #expect(PartitionTableProbe.gptBlockSize(prefix: disk(headersAt: [512, 4096])) == 512)
    }

    // MARK: - The block size to attach at

    private var blankDisk: Data { Data(count: PartitionTableProbe.prefixLength) }

    @Test("a GPT at 4096 attaches at 4096, whatever the LUN reports")
    func attachFollowsGPT4096() {
        var prefix = blankDisk
        prefix.replaceSubrange(0 ..< 8192, with: disk(headersAt: [4096]))
        #expect(PartitionTableProbe.attachBlockSize(prefix: prefix, lunBlockSize: 4096) == 4096)
        #expect(PartitionTableProbe.attachBlockSize(prefix: prefix, lunBlockSize: 512) == 4096)
        #expect(PartitionTableProbe.attachBlockSize(prefix: prefix, lunBlockSize: nil) == 4096)
    }

    @Test("a GPT at 512 on a 4Kn LUN keeps the default — every disk this app partitioned until now")
    func attachKeepsGPT512() {
        var prefix = blankDisk
        prefix.replaceSubrange(0 ..< 8192, with: disk(headersAt: [512]))
        #expect(PartitionTableProbe.attachBlockSize(prefix: prefix, lunBlockSize: 4096) == nil)
    }

    @Test("a blank 4Kn LUN attaches at 4096, so it is partitioned the way other initiators read it")
    func blank4Kn() {
        #expect(PartitionTableProbe.attachBlockSize(prefix: blankDisk, lunBlockSize: 4096) == 4096)
    }

    @Test("a blank LUN that is not 4Kn, or of unknown block size, keeps the default")
    func blankOther() {
        #expect(PartitionTableProbe.attachBlockSize(prefix: blankDisk, lunBlockSize: 512) == nil)
        #expect(PartitionTableProbe.attachBlockSize(prefix: blankDisk, lunBlockSize: nil) == nil)
        #expect(PartitionTableProbe.attachBlockSize(prefix: blankDisk, lunBlockSize: 8192) == nil)
    }

    @Test("anything written in the first MiB is not blank: MBR, HFS+, a byte near the end")
    func notBlank() {
        var mbrOnly = blankDisk
        mbrOnly.replaceSubrange(0 ..< 8192, with: disk(headersAt: []))
        var hfsPlus = blankDisk
        hfsPlus[1024] = UInt8(ascii: "H"); hfsPlus[1025] = UInt8(ascii: "+")
        var lastByte = blankDisk
        lastByte[PartitionTableProbe.prefixLength - 1] = 1
        for prefix in [mbrOnly, hfsPlus, lastByte] {
            #expect(PartitionTableProbe.attachBlockSize(prefix: prefix, lunBlockSize: 4096) == nil)
        }
    }

    @Test("a short read cannot prove a disk blank")
    func shortReadIsNotBlank() {
        #expect(PartitionTableProbe.attachBlockSize(prefix: Data(count: 8192), lunBlockSize: 4096) == nil)
    }

    @Test("the probe reads from wherever the Data's indices start")
    func slicedData() {
        let padded = Data(count: 100) + disk(headersAt: [4096])
        #expect(PartitionTableProbe.gptBlockSize(prefix: padded.dropFirst(100)) == 4096)
    }

    // MARK: - APFS

    private static let efiType: [UInt8] = [0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                                           0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B]
    private static let hfsPlusType: [UInt8] = [0x00, 0x53, 0x46, 0x48, 0x00, 0x00, 0xAA, 0x11,
                                               0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC]

    /// The start of a disk `diskutil` partitioned at `blockSize`: its real
    /// header, and the entry array at LBA 2 holding `types` in order.
    private func partitioned(blockSize: Int, types: [[UInt8]]) -> Data {
        var prefix = [UInt8](repeating: 0, count: 64 << 10)
        let hex = blockSize == 512 ? Self.diskutilHeader512 : Self.diskutilHeader4096
        prefix.replaceSubrange(blockSize ..< blockSize + 92, with: bytes(hex: hex))
        for (index, type) in types.enumerated() {
            let entry = 2 * blockSize + index * 128
            prefix.replaceSubrange(entry ..< entry + 16, with: type)
        }
        return Data(prefix)
    }

    @Test("a disk partitioned as APFS holds APFS, at either block size")
    func apfsPartition() {
        for blockSize in [512, 4096] {
            let prefix = partitioned(blockSize: blockSize, types: [PartitionTableProbe.apfsPartitionType])
            #expect(PartitionTableProbe.holdsAPFS(prefix: prefix), "block size \(blockSize)")
        }
    }

    @Test("an EFI partition first, then APFS: what a larger disk gets")
    func efiThenAPFS() {
        let prefix = partitioned(blockSize: 512, types: [Self.efiType, PartitionTableProbe.apfsPartitionType])
        #expect(PartitionTableProbe.holdsAPFS(prefix: prefix))
    }

    @Test("a GPT of other partitions does not hold APFS")
    func otherPartitions() {
        let prefix = partitioned(blockSize: 4096, types: [Self.efiType, Self.hfsPlusType])
        #expect(!PartitionTableProbe.holdsAPFS(prefix: prefix))
    }

    @Test("an APFS container written to the whole disk holds APFS")
    func wholeDiskContainer() {
        var prefix = [UInt8](repeating: 0, count: 4096)
        prefix.replaceSubrange(32 ..< 36, with: Array("NXSB".utf8))
        #expect(PartitionTableProbe.holdsAPFS(prefix: Data(prefix)))
    }

    @Test("blank, MBR-only and nonsense tables do not hold APFS, and do not trap")
    func noAPFS() {
        #expect(!PartitionTableProbe.holdsAPFS(prefix: Data(count: 1 << 20)))
        #expect(!PartitionTableProbe.holdsAPFS(prefix: disk(headersAt: [])))
        #expect(!PartitionTableProbe.holdsAPFS(prefix: Data()))
        // A header that puts its entries past what was read, or claims
        // absurd sizes, is not followed.
        var far = [UInt8](partitioned(blockSize: 512, types: [PartitionTableProbe.apfsPartitionType]))
        far.replaceSubrange((512 + 72) ..< (512 + 80), with: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(!PartitionTableProbe.holdsAPFS(prefix: Data(far)))
        var huge = [UInt8](partitioned(blockSize: 512, types: [PartitionTableProbe.apfsPartitionType]))
        huge.replaceSubrange((512 + 84) ..< (512 + 88), with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(!PartitionTableProbe.holdsAPFS(prefix: Data(huge)))
    }
}
