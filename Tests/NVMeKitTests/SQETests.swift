import Foundation
import Testing
import iSCSIKit
@testable import NVMeKit

@Suite("SQE, SGL and CQE layouts")
struct SQETests {
    @Test func fieldsLandAtTheirOffsets() {
        var sqe = SQE()
        #expect(sqe.bytes.count == 64 && sqe.bytes.allSatisfy { $0 == 0 })
        sqe.opcode = 0x02
        sqe.commandID = 0xBEEF
        sqe.nsid = 7
        sqe.cdw10 = 0x1111_1111
        sqe.cdw11 = 0x2222_2222
        sqe.cdw12 = 0x3333_3333
        sqe.cdw13 = 0x4444_4444
        sqe.cdw14 = 0x5555_5555
        sqe.cdw15 = 0x6666_6666
        #expect(sqe.bytes.u8(0) == 0x02)
        #expect(sqe.bytes.leU16(2) == 0xBEEF)
        #expect(sqe.bytes.leU32(4) == 7)
        #expect(sqe.bytes.leU32(40) == 0x1111_1111)
        #expect(sqe.bytes.leU32(60) == 0x6666_6666)
        #expect(sqe.cdw12 == 0x3333_3333)
    }

    /// In-capsule data uses an SGL Data Block descriptor (type 0h) with the
    /// offset subtype (1h): byte 15 = 0x01. Data moved by the transport uses
    /// a Transport SGL Data Block (type 5h, subtype Ah): byte 15 = 0x5A.
    /// These are the exact encodings the Linux host emits.
    @Test func sglDescriptorEncodings() {
        var sqe = SQE()
        sqe.sgl = .inCapsule(length: 4096)
        #expect(sqe.flags & 0xC0 == 0x40)                 // PSDT 01b: SGL in the SQE
        #expect(sqe.bytes.leU64(24) == 0)                 // address = ICDOFF (0)
        #expect(sqe.bytes.leU32(32) == 4096)
        #expect(Array(sqe.bytes.sub(36, 4)) == [0, 0, 0, 0x01])

        sqe.sgl = .transport(length: 8192)
        #expect(sqe.bytes.leU32(32) == 8192)
        #expect(sqe.bytes.u8(39) == 0x5A)
        #expect(sqe.sgl == SGLDescriptor.transport(length: 8192))
    }

    @Test func cqeDecodesEveryField() throws {
        var bytes = Data(count: 16)
        bytes.setLE32(0x0000_0007, 0)      // DW0: e.g. CNTLID 7 from Connect
        bytes.setLE32(0xAAAA_BBBB, 4)      // DW1
        bytes.setLE16(5, 8)                // SQHD
        bytes.setLE16(1, 10)               // SQID
        bytes.setLE16(0x1234, 12)          // CID
        bytes.setLE16(0x8308 | 1, 14)      // DNR | SCT 1 | SC 0x84 | phase
        let cqe = try CQE(bytes: bytes)
        #expect(cqe.dw0 == 7 && cqe.dw1 == 0xAAAA_BBBB)
        #expect(cqe.result64 == 0xAAAA_BBBB_0000_0007)
        #expect(cqe.sqHead == 5 && cqe.sqID == 1 && cqe.commandID == 0x1234)
        #expect(cqe.status.sct == 1 && cqe.status.sc == 0x84)
        #expect(cqe.status.dnr && !cqe.status.more)
        #expect(!cqe.status.isSuccess)
        #expect(cqe.encoded == bytes)
        #expect(throws: NVMeTCPError.self) { try CQE(bytes: Data(count: 15)) }
    }

    @Test func statusDecoding() {
        #expect(NVMeStatus(field: 0x0000).isSuccess)
        #expect(NVMeStatus(field: 0x0001).isSuccess)          // phase bit is not status
        let ns = NVMeStatus(field: 0x0016)                    // SC 0x0B Invalid Namespace
        #expect(ns.sct == 0 && ns.sc == 0x0B)
        #expect(NVMeStatus(sct: 1, sc: 0x84, dnr: true).field == 0x8308)
        #expect(NVMeStatus(sct: 1, sc: 0x84).description == "sct 0x01 sc 0x84")
        #expect(NVMeStatus.success == NVMeStatus(sct: 0, sc: 0))
    }
}
