import Foundation
import Testing
@testable import iSCSIKit

/// Encode → decode round trips for every PDU type, plus byte-exact golden
/// vectors for representative PDUs (layouts per RFC 7143 §11).
@Suite("PDU round trips and golden vectors")
struct PDURoundTripTests {
    func roundTrip<T: ProtocolDataUnit>(_ pdu: T) throws -> T {
        let raw = pdu.encode()
        // Serialize through the framer so DataSegmentLength is stamped.
        var deframer = PDUDeframer()
        deframer.append(PDUSerializer().serialize(raw))
        let framed = try #require(try deframer.next())
        return try T(raw: framed)
    }

    @Test func nopOutGoldenBytes() throws {
        var pdu = NopOutPDU()
        pdu.initiatorTaskTag = 0x1122_3344
        pdu.targetTransferTag = 0xFFFF_FFFF
        pdu.cmdSN = 5
        pdu.expStatSN = 6
        let wire = PDUSerializer().serialize(pdu)
        var expected = Data(count: 48)
        expected.setU8(0x00, 0) // NOP-Out, not immediate
        expected.setU8(0x80, 1)
        expected.setBE32(0x1122_3344, 16)
        expected.setBE32(0xFFFF_FFFF, 20)
        expected.setBE32(5, 24)
        expected.setBE32(6, 28)
        #expect(wire == expected)
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func scsiCommandGoldenRead10() throws {
        var pdu = SCSICommandPDU()
        pdu.read = true
        pdu.attribute = .simple
        pdu.lun = 0x0001_0000_0000_0000 // LUN 1 in flat addressing
        pdu.initiatorTaskTag = 0xCAFE_F00D
        pdu.expectedDataTransferLength = 4096
        pdu.cmdSN = 0x10
        pdu.expStatSN = 0x20
        // READ(10), LBA 0x100, 8 blocks
        pdu.cdb = Data([0x28, 0, 0, 0, 0x01, 0, 0, 0, 0x08, 0])
        let wire = PDUSerializer().serialize(pdu)
        #expect(wire.count == 48)
        #expect(wire.u8(0) == 0x01)
        #expect(wire.u8(1) == 0b1100_0001) // F=1 R=1 W=0 attr=simple
        #expect(wire.beU64(8) == 0x0001_0000_0000_0000)
        #expect(wire.beU32(16) == 0xCAFE_F00D)
        #expect(wire.beU32(20) == 4096)
        #expect(wire.beU32(24) == 0x10)
        #expect(wire.beU32(28) == 0x20)
        #expect(wire.sub(32, 16) == Data([0x28, 0, 0, 0, 0x01, 0, 0, 0, 0x08, 0, 0, 0, 0, 0, 0, 0]))
        let decoded = try roundTrip(pdu)
        // CDB comes back zero-padded to 16 bytes.
        #expect(decoded.cdb.prefix(10) == pdu.cdb)
        #expect(decoded.read && !decoded.write && decoded.final)
    }

    @Test func loginRequestGoldenBytes() throws {
        var pdu = LoginRequestPDU()
        pdu.transit = true
        pdu.currentStage = .loginOperationalNegotiation
        pdu.nextStage = .fullFeaturePhase
        pdu.isid = ISID(Data([0x80, 0xAB, 0xCD, 0xEF, 0x00, 0x01]))
        pdu.tsih = 0
        pdu.initiatorTaskTag = 1
        pdu.cid = 0
        pdu.cmdSN = 1
        pdu.expStatSN = 2
        var params = TextParameters()
        params.append("InitiatorName", "iqn.2026-08.com.example:mac")
        pdu.dataSegment = params.encode()

        let wire = PDUSerializer().serialize(pdu)
        #expect(wire.u8(0) == 0x43) // immediate bit always set on login
        #expect(wire.u8(1) == 0b1000_0111) // T=1 C=0 CSG=1 NSG=3
        #expect(wire.beU24(5) == UInt32(params.encode().count))
        #expect(wire.sub(8, 6) == pdu.isid.bytes)
        #expect(wire.count == 48 + padded4(params.encode().count))
        // Padding bytes must be zero.
        let pad = padded4(params.encode().count) - params.encode().count
        if pad > 0 {
            #expect(wire.suffix(pad).allSatisfy { $0 == 0 })
        }
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func dataOutRoundTrip() throws {
        var pdu = DataOutPDU()
        pdu.final = false
        pdu.lun = 2 << 48
        pdu.initiatorTaskTag = 7
        pdu.targetTransferTag = 0x0102_0304
        pdu.expStatSN = 9
        pdu.dataSN = 3
        pdu.bufferOffset = 8192
        pdu.dataSegment = Data((0 ..< 517).map { UInt8($0 & 0xFF) }) // odd size → padding
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func dataInRoundTrip() throws {
        var pdu = DataInPDU()
        pdu.final = true
        pdu.statusPresent = true
        pdu.status = 0
        pdu.residualUnderflow = true
        pdu.initiatorTaskTag = 11
        pdu.statSN = 100
        pdu.expCmdSN = 5
        pdu.maxCmdSN = 37
        pdu.dataSN = 2
        pdu.bufferOffset = 4096
        pdu.residualCount = 512
        pdu.dataSegment = Data(repeating: 0xA5, count: 4096)
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func dataInStatusRequiresFinal() {
        var pdu = DataInPDU()
        pdu.final = false
        pdu.statusPresent = true
        let raw = pdu.encode()
        #expect(throws: PDUError.self) { try DataInPDU(raw: raw) }
    }

    @Test func r2tRoundTrip() throws {
        var pdu = R2TPDU()
        pdu.lun = 0
        pdu.initiatorTaskTag = 21
        pdu.targetTransferTag = 0xBEEF
        pdu.statSN = 1
        pdu.expCmdSN = 2
        pdu.maxCmdSN = 3
        pdu.r2tSN = 0
        pdu.bufferOffset = 65536
        pdu.desiredDataTransferLength = 262_144
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func r2tRejectsReservedTTT() {
        var pdu = R2TPDU()
        pdu.targetTransferTag = 0xFFFF_FFFF
        pdu.desiredDataTransferLength = 1
        #expect(throws: PDUError.self) { try R2TPDU(raw: pdu.encode()) }
    }

    @Test func scsiResponseRoundTripWithSense() throws {
        var pdu = SCSIResponsePDU()
        pdu.response = .commandCompleted
        pdu.status = 0x02 // CHECK CONDITION
        pdu.initiatorTaskTag = 33
        pdu.statSN = 8
        pdu.expCmdSN = 9
        pdu.maxCmdSN = 41
        pdu.residualUnderflow = true
        pdu.residualCount = 100
        let sense = Data([0x70, 0, 0x05, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0x24, 0, 0, 0, 0, 0])
        var seg = Data(count: 2)
        seg.setBE16(UInt16(sense.count), 0)
        seg.append(sense)
        pdu.dataSegment = seg
        let decoded = try roundTrip(pdu)
        #expect(decoded == pdu)
        #expect(decoded.senseData == sense)
    }

    @Test func tmfRoundTrips() throws {
        var req = TMFRequestPDU()
        req.function = .lunReset
        req.lun = 3 << 48
        req.initiatorTaskTag = 50
        req.referencedTaskTag = 0xFFFF_FFFF
        req.cmdSN = 12
        req.expStatSN = 13
        #expect(try roundTrip(req) == req)

        var resp = TMFResponsePDU()
        resp.response = .functionComplete
        resp.initiatorTaskTag = 50
        resp.statSN = 14
        resp.expCmdSN = 13
        resp.maxCmdSN = 45
        #expect(try roundTrip(resp) == resp)
    }

    @Test func loginResponseRoundTrip() throws {
        var pdu = LoginResponsePDU()
        pdu.transit = true
        pdu.currentStage = .securityNegotiation
        pdu.nextStage = .loginOperationalNegotiation
        pdu.versionMax = 0
        pdu.versionActive = 0
        pdu.isid = ISID(Data([0x80, 1, 2, 3, 4, 5]))
        pdu.tsih = 0x1234
        pdu.initiatorTaskTag = 1
        pdu.statSN = 1
        pdu.expCmdSN = 2
        pdu.maxCmdSN = 3
        var params = TextParameters()
        params.append("TargetPortalGroupTag", "1")
        pdu.dataSegment = params.encode()
        #expect(try roundTrip(pdu) == pdu)
        #expect(pdu.isSuccess)
    }

    @Test func loginRedirectStatus() throws {
        var pdu = LoginResponsePDU()
        pdu.statusClass = 1
        pdu.statusDetail = 2 // redirect: permanent
        #expect(try roundTrip(pdu).isRedirect)
    }

    @Test func textRoundTrips() throws {
        var req = TextRequestPDU()
        req.initiatorTaskTag = 60
        req.cmdSN = 20
        req.expStatSN = 21
        var params = TextParameters()
        params.append("SendTargets", "All")
        req.dataSegment = params.encode()
        #expect(try roundTrip(req) == req)

        var resp = TextResponsePDU()
        resp.initiatorTaskTag = 60
        resp.statSN = 22
        resp.expCmdSN = 21
        resp.maxCmdSN = 53
        var out = TextParameters()
        out.append("TargetName", "iqn.2026-08.com.example:disk0")
        out.append("TargetAddress", "192.168.1.50:3260,1")
        resp.dataSegment = out.encode()
        #expect(try roundTrip(resp) == resp)
    }

    @Test func textFAndCBitsConflict() {
        var req = TextRequestPDU()
        req.final = true
        req.continued = true
        #expect(throws: PDUError.self) { try TextRequestPDU(raw: req.encode()) }
    }

    @Test func nopInRoundTrip() throws {
        var pdu = NopInPDU()
        pdu.initiatorTaskTag = 0xFFFF_FFFF
        pdu.targetTransferTag = 0x77
        pdu.statSN = 5
        pdu.expCmdSN = 6
        pdu.maxCmdSN = 38
        pdu.dataSegment = Data("ping".utf8)
        let decoded = try roundTrip(pdu)
        #expect(decoded == pdu)
        #expect(decoded.isPing)
    }

    @Test func logoutRoundTrips() throws {
        var req = LogoutRequestPDU()
        req.reason = .closeSession
        req.initiatorTaskTag = 70
        req.cid = 1
        req.cmdSN = 30
        req.expStatSN = 31
        #expect(try roundTrip(req) == req)

        var resp = LogoutResponsePDU()
        resp.response = .success
        resp.initiatorTaskTag = 70
        resp.statSN = 32
        resp.expCmdSN = 31
        resp.maxCmdSN = 63
        resp.time2Wait = 2
        resp.time2Retain = 20
        #expect(try roundTrip(resp) == resp)
    }

    @Test func asyncMessageRoundTrip() throws {
        var pdu = AsyncMessagePDU()
        pdu.event = .logoutRequest
        pdu.statSN = 40
        pdu.expCmdSN = 41
        pdu.maxCmdSN = 73
        pdu.parameter3 = 5 // seconds until target logs us out
        #expect(try roundTrip(pdu) == pdu)
    }

    @Test func rejectRoundTrip() throws {
        var pdu = RejectPDU()
        pdu.reason = .invalidPDUField
        pdu.statSN = 50
        pdu.expCmdSN = 51
        pdu.maxCmdSN = 83
        pdu.dataSegment = Data(count: 48) // offending header
        let decoded = try roundTrip(pdu)
        #expect(decoded == pdu)
    }

    @Test func decodeDispatchesAllOpcodes() throws {
        let pdus: [AnyPDU] = [
            .nopOut(NopOutPDU()),
            .tmfRequest(TMFRequestPDU()),
            .loginRequest(LoginRequestPDU()),
            .textRequest(TextRequestPDU()),
            .scsiDataOut(DataOutPDU()),
            .logoutRequest(LogoutRequestPDU()),
            .scsiResponse(SCSIResponsePDU()),
            .tmfResponse(TMFResponsePDU()),
            .loginResponse(LoginResponsePDU()),
            .textResponse(TextResponsePDU()),
            .scsiDataIn(DataInPDU()),
            .logoutResponse(LogoutResponsePDU()),
            .asyncMessage(AsyncMessagePDU()),
        ]
        for pdu in pdus {
            let decoded = try AnyPDU.decode(pdu.encode())
            #expect(decoded == pdu)
        }
    }

    @Test func unknownOpcodeRejected() {
        var bhs = Data(count: 48)
        bhs.setU8(0x3A, 0) // not a defined opcode
        #expect(throws: PDUError.unknownOpcode(0x3A)) {
            try AnyPDU.decode(RawPDU(bhs: bhs))
        }
    }
}
