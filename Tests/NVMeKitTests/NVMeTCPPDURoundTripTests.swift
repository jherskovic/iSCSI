import Foundation
import Testing
import iSCSIKit
@testable import NVMeKit

@Suite("NVMe/TCP PDU encode/decode")
struct NVMeTCPPDURoundTripTests {
    func roundTrip<P: NVMeTCPPDU>(_ pdu: P, digests: NVMeTCPDigests = NVMeTCPDigests()) throws -> P {
        let wire = NVMeTCPSerializer(digests: digests).serialize(pdu.encode())
        var deframer = NVMeTCPDeframer(digests: digests)
        deframer.append(wire)
        let raw = try #require(try deframer.next())
        #expect(raw.pduType == P.pduType)
        return try P(raw: raw)
    }

    @Test func icReqGoldenBytes() throws {
        var pdu = ICReqPDU()
        pdu.digests = NVMeTCPDigests(header: true, data: false)
        pdu.maxR2T = 0
        let wire = NVMeTCPSerializer().serialize(pdu.encode())
        #expect(wire.count == 128)
        #expect(Array(wire.prefix(16)) ==
                [0x00, 0x00, 128, 0, 128, 0, 0, 0,   // CH: type 0, HLEN 128, PDO 0, PLEN 128
                 0x00, 0x00,                          // PFV 0
                 0x00,                                // HPDA 0: we never ask for alignment
                 0x01,                                // DGST: HDGST_ENABLE only
                 0x00, 0x00, 0x00, 0x00])             // MAXR2T (0's based)
        #expect(wire.suffix(112).allSatisfy { $0 == 0 })
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func icRespDecodesControllerLimits() throws {
        var psh = Data(count: 120)
        psh.setLE16(0, 0)             // PFV
        psh.setU8(0, 2)               // CPDA
        psh.setU8(0x03, 3)            // DGST: both
        psh.setLE32(65536, 4)         // MAXH2CDATA
        let pdu = try ICRespPDU(raw: RawNVMeTCPPDU(type: .icResp, psh: psh))
        #expect(pdu.pfv == 0)
        #expect(pdu.cpda == 0)
        #expect(pdu.digests == NVMeTCPDigests(header: true, data: true))
        #expect(pdu.maxH2CData == 65536)
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func wrongPSHSizeIsMalformed() {
        #expect(throws: NVMeTCPError.self) {
            try ICRespPDU(raw: RawNVMeTCPPDU(type: .icResp, psh: Data(count: 16)))
        }
        #expect(throws: NVMeTCPError.self) {
            try CapsuleCmdPDU(raw: RawNVMeTCPPDU(type: .capsuleCmd, psh: Data(count: 32)))
        }
    }

    @Test func capsuleCommandCarriesSQEAndInCapsuleData() throws {
        let sqe = Data((0 ..< 64).map { UInt8($0) })
        let icd = Data(repeating: 0x5A, count: 512)
        let pdu = CapsuleCmdPDU(sqe: sqe, inCapsuleData: icd)
        let raw = pdu.encode()
        #expect(raw.hlen == 72)
        #expect(raw.psh == sqe)
        #expect(raw.data == icd)
        let back = try roundTrip(pdu, digests: NVMeTCPDigests(header: true, data: true))
        #expect(back == pdu)
    }

    @Test func capsuleResponseCarriesTheCQE() throws {
        let cqe = Data((0 ..< 16).map { UInt8(0xF0 | $0) })
        let pdu = CapsuleRespPDU(cqe: cqe)
        #expect(pdu.encode().hlen == 24)
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func h2cDataGoldenHeader() throws {
        let data = Data(repeating: 0x11, count: 4096)
        let pdu = H2CDataPDU(cccid: 0x1234, ttag: 0x0001, dataOffset: 8192, data: data, last: true)
        let raw = pdu.encode()
        #expect(raw.flags == [.lastPDU])
        #expect(Array(raw.psh) ==
                [0x34, 0x12,               // CCCID
                 0x01, 0x00,               // TTAG
                 0x00, 0x20, 0x00, 0x00,   // DATAO 8192
                 0x00, 0x10, 0x00, 0x00,   // DATAL 4096
                 0, 0, 0, 0])
        let back = try roundTrip(pdu, digests: NVMeTCPDigests(data: true))
        #expect(back == pdu)
    }

    @Test func c2hDataDecodesFlagsAndRejectsALengthMismatch() throws {
        var psh = Data(count: 16)
        psh.setLE16(0x0042, 0)        // CCCID
        psh.setLE32(0, 4)             // DATAO
        psh.setLE32(8, 8)             // DATAL
        let good = try C2HDataPDU(raw: RawNVMeTCPPDU(type: .c2hData, flags: [.lastPDU, .success],
                                                     psh: psh, data: Data(count: 8)))
        #expect(good.cccid == 0x42)
        #expect(good.last && good.success)
        #expect(good.dataOffset == 0)
        #expect(good.data.count == 8)

        #expect(throws: NVMeTCPError.self) {
            try C2HDataPDU(raw: RawNVMeTCPPDU(type: .c2hData, psh: psh, data: Data(count: 7)))
        }
    }

    @Test func r2tRoundTrip() throws {
        let pdu = NVMeR2TPDU(cccid: 7, ttag: 3, offset: 16384, length: 65536)
        let raw = pdu.encode()
        #expect(raw.data.isEmpty)
        #expect(raw.psh.leU16(0) == 7 && raw.psh.leU16(2) == 3)
        #expect(raw.psh.leU32(4) == 16384 && raw.psh.leU32(8) == 65536)
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func terminationRequestsCarryTheOffendingHeader() throws {
        let offending = Data([0x07, 0x00, 24, 24, 24, 0, 0, 0])
        let c2h = C2HTermReqPDU(fes: .headerDigestError, fei: 0, offendingHeader: offending)
        let raw = c2h.encode()
        #expect(raw.hlen == 24)
        #expect(raw.psh.leU16(0) == 0x0003)
        #expect(raw.data == offending)
        #expect(try roundTrip(c2h) == c2h)

        let h2c = H2CTermReqPDU(fes: .invalidPDUHeader, fei: 0x0000_0002, offendingHeader: offending)
        #expect(try roundTrip(h2c) == h2c)
        #expect(h2c.fes.rawValue == 0x0001)
    }

    @Test func anyPDUDispatchesOnType() throws {
        let cases: [any NVMeTCPPDU] = [
            ICReqPDU(), ICRespPDU(),
            CapsuleCmdPDU(sqe: Data(count: 64)), CapsuleRespPDU(cqe: Data(count: 16)),
            H2CDataPDU(cccid: 1, ttag: 0, dataOffset: 0, data: Data(count: 4), last: true),
            C2HDataPDU(cccid: 1, dataOffset: 0, data: Data(count: 4), last: true, success: false),
            NVMeR2TPDU(cccid: 1, ttag: 0, offset: 0, length: 4),
            H2CTermReqPDU(fes: .pduSequenceError, fei: 0, offendingHeader: Data()),
            C2HTermReqPDU(fes: .unsupportedParameter, fei: 0, offendingHeader: Data()),
        ]
        for pdu in cases {
            let any = try AnyNVMeTCPPDU.decode(pdu.encode())
            #expect(any.pduType == type(of: pdu).pduType)
            #expect(any.encode() == pdu.encode())
        }
    }

    @Test func unknownTypeIsReportedNotCrashed() {
        #expect(throws: NVMeTCPError.unknownType(0x08)) {
            try AnyNVMeTCPPDU.decode(RawNVMeTCPPDU(rawType: 0x08, psh: Data(count: 16)))
        }
    }
}
