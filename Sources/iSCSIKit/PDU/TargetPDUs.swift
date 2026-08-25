import Foundation

// PDUs sent target → initiator (RFC 7143 §11).

/// SCSI Response (opcode 0x21), §11.4.
public struct SCSIResponsePDU: ProtocolDataUnit {
    public static let opcode = Opcode.scsiResponse

    /// §11.4.3: 0x00 completed, 0x01 target failure, 0x80–0xff vendor
    /// specific (all mapping to SERVICE DELIVERY OR TARGET FAILURE); the rest
    /// are reserved and their receipt is a protocol error.
    public enum Response: Equatable, Sendable {
        case commandCompleted
        case targetFailure
        case vendorSpecific(UInt8)

        init?(code: UInt8) {
            switch code {
            case 0x00: self = .commandCompleted
            case 0x01: self = .targetFailure
            case 0x80 ... 0xFF: self = .vendorSpecific(code)
            default: return nil
            }
        }

        var code: UInt8 {
            switch self {
            case .commandCompleted: return 0x00
            case .targetFailure: return 0x01
            case .vendorSpecific(let code): return code
            }
        }
    }

    public var bidiReadResidualOverflow = false
    public var bidiReadResidualUnderflow = false
    public var residualOverflow = false
    public var residualUnderflow = false
    public var response: Response = .commandCompleted
    /// SAM-2 SCSI status (0x00 GOOD, 0x02 CHECK CONDITION, 0x08 BUSY, ...).
    public var status: UInt8 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var snackTag: UInt32 = 0
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var expDataSN: UInt32 = 0
    public var bidiReadResidualCount: UInt32 = 0
    public var residualCount: UInt32 = 0
    /// Sense-and-response data (2-byte SenseLength prefix + sense data) when
    /// status is CHECK CONDITION.
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .scsiResponse else { throw PDUError.malformed("opcode") }
        let f = raw.bhs.u8(1)
        guard f & 0x80 != 0 else { throw PDUError.malformed("SCSI Response bit 7 must be 1") }
        bidiReadResidualOverflow = f & 0x10 != 0
        bidiReadResidualUnderflow = f & 0x08 != 0
        residualOverflow = f & 0x04 != 0
        residualUnderflow = f & 0x02 != 0
        guard let r = Response(code: raw.bhs.u8(2)) else {
            throw PDUError.malformed("SCSI response code \(raw.bhs.u8(2))")
        }
        response = r
        status = raw.bhs.u8(3)
        initiatorTaskTag = raw.bhs.beU32(16)
        snackTag = raw.bhs.beU32(20)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        expDataSN = raw.bhs.beU32(36)
        bidiReadResidualCount = raw.bhs.beU32(40)
        residualCount = raw.bhs.beU32(44)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .scsiResponse)
        b.flags = 0x80
            | (bidiReadResidualOverflow ? 0x10 : 0)
            | (bidiReadResidualUnderflow ? 0x08 : 0)
            | (residualOverflow ? 0x04 : 0)
            | (residualUnderflow ? 0x02 : 0)
        b.bytes.setU8(response.code, 2)
        b.bytes.setU8(status, 3)
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(snackTag, 20)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        b.bytes.setBE32(expDataSN, 36)
        b.bytes.setBE32(bidiReadResidualCount, 40)
        b.bytes.setBE32(residualCount, 44)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }

    /// Parse the sense data out of the data segment (2-byte length prefix).
    public var senseData: Data? {
        guard dataSegment.count >= 2 else { return nil }
        let len = Int(dataSegment.beU16(0))
        guard dataSegment.count >= 2 + len else { return nil }
        return dataSegment.sub(2, len)
    }
}

/// SCSI Data-In (opcode 0x25), §11.7.
public struct DataInPDU: ProtocolDataUnit {
    public static let opcode = Opcode.scsiDataIn

    public var final = true
    /// A bit: target requests DataACK SNACK (ERL>0 only).
    public var acknowledge = false
    public var residualOverflow = false
    public var residualUnderflow = false
    /// S bit: status is piggybacked in this PDU.
    public var statusPresent = false
    public var status: UInt8 = 0
    public var lun: UInt64 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var targetTransferTag: UInt32 = 0xFFFF_FFFF
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var dataSN: UInt32 = 0
    public var bufferOffset: UInt32 = 0
    public var residualCount: UInt32 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .scsiDataIn else { throw PDUError.malformed("opcode") }
        let f = raw.bhs.u8(1)
        final = f & 0x80 != 0
        acknowledge = f & 0x40 != 0
        residualOverflow = f & 0x04 != 0
        residualUnderflow = f & 0x02 != 0
        statusPresent = f & 0x01 != 0
        if statusPresent && !final { throw PDUError.malformed("S bit requires F bit") }
        status = raw.bhs.u8(3)
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        targetTransferTag = raw.bhs.beU32(20)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        dataSN = raw.bhs.beU32(36)
        bufferOffset = raw.bhs.beU32(40)
        residualCount = raw.bhs.beU32(44)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .scsiDataIn)
        b.flags = (final ? 0x80 : 0) | (acknowledge ? 0x40 : 0)
            | (residualOverflow ? 0x04 : 0) | (residualUnderflow ? 0x02 : 0)
            | (statusPresent ? 0x01 : 0)
        b.bytes.setU8(status, 3)
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(targetTransferTag, 20)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        b.bytes.setBE32(dataSN, 36)
        b.bytes.setBE32(bufferOffset, 40)
        b.bytes.setBE32(residualCount, 44)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// Ready To Transfer (opcode 0x31), §11.8.
public struct R2TPDU: ProtocolDataUnit {
    public static let opcode = Opcode.r2t

    public var lun: UInt64 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var targetTransferTag: UInt32 = 0
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var r2tSN: UInt32 = 0
    public var bufferOffset: UInt32 = 0
    public var desiredDataTransferLength: UInt32 = 0

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .r2t else { throw PDUError.malformed("opcode") }
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        targetTransferTag = raw.bhs.beU32(20)
        if targetTransferTag == 0xFFFF_FFFF { throw PDUError.malformed("R2T TTT must not be 0xffffffff") }
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        r2tSN = raw.bhs.beU32(36)
        bufferOffset = raw.bhs.beU32(40)
        desiredDataTransferLength = raw.bhs.beU32(44)
        if desiredDataTransferLength == 0 { throw PDUError.malformed("R2T desired length 0") }
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .r2t)
        b.flags = 0x80
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(targetTransferTag, 20)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        b.bytes.setBE32(r2tSN, 36)
        b.bytes.setBE32(bufferOffset, 40)
        b.bytes.setBE32(desiredDataTransferLength, 44)
        return RawPDU(bhs: b.bytes)
    }
}

/// Task Management Function Response (opcode 0x22), §11.6.
public struct TMFResponsePDU: ProtocolDataUnit {
    public static let opcode = Opcode.tmfResponse

    public enum Response: UInt8, Sendable {
        case functionComplete = 0
        case taskDoesNotExist = 1
        case lunDoesNotExist = 2
        case taskStillAllegiant = 3
        case taskAllegianceReassignmentNotSupported = 4
        case functionNotSupported = 5
        case functionAuthorizationFailed = 6
        case functionRejected = 255
    }

    public var response: Response = .functionComplete
    public var initiatorTaskTag: UInt32 = 0
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .tmfResponse else { throw PDUError.malformed("opcode") }
        guard let r = Response(rawValue: raw.bhs.u8(2)) else {
            throw PDUError.malformed("TMF response \(raw.bhs.u8(2))")
        }
        response = r
        initiatorTaskTag = raw.bhs.beU32(16)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .tmfResponse)
        b.flags = 0x80
        b.bytes.setU8(response.rawValue, 2)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        return RawPDU(bhs: b.bytes)
    }
}

/// Login Response (opcode 0x23), §11.13.
public struct LoginResponsePDU: ProtocolDataUnit {
    public static let opcode = Opcode.loginResponse

    public var transit = false
    public var continued = false
    public var currentStage: LoginStage = .securityNegotiation
    public var nextStage: LoginStage = .securityNegotiation
    public var versionMax: UInt8 = 0
    public var versionActive: UInt8 = 0
    public var isid: ISID = ISID()
    public var tsih: UInt16 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var statusClass: UInt8 = 0
    public var statusDetail: UInt8 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .loginResponse else { throw PDUError.malformed("opcode") }
        let f = raw.bhs.u8(1)
        transit = f & 0x80 != 0
        continued = f & 0x40 != 0
        if transit && continued { throw PDUError.malformed("T and C bits both set") }
        guard let csg = LoginStage(rawValue: (f >> 2) & 0x3), let nsg = LoginStage(rawValue: f & 0x3) else {
            throw PDUError.malformed("login stage")
        }
        currentStage = csg
        nextStage = nsg
        versionMax = raw.bhs.u8(2)
        versionActive = raw.bhs.u8(3)
        isid = ISID(raw.bhs.sub(8, 6))
        tsih = raw.bhs.beU16(14)
        initiatorTaskTag = raw.bhs.beU32(16)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        statusClass = raw.bhs.u8(36)
        statusDetail = raw.bhs.u8(37)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .loginResponse)
        b.flags = (transit ? 0x80 : 0) | (continued ? 0x40 : 0)
            | (currentStage.rawValue << 2) | nextStage.rawValue
        b.bytes.setU8(versionMax, 2)
        b.bytes.setU8(versionActive, 3)
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setSub(isid.bytes, 8)
        b.bytes.setBE16(tsih, 14)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        b.bytes.setU8(statusClass, 36)
        b.bytes.setU8(statusDetail, 37)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }

    public var isSuccess: Bool { statusClass == 0 }
    public var isRedirect: Bool { statusClass == 1 }
}

/// Text Response (opcode 0x24), §11.11.
public struct TextResponsePDU: ProtocolDataUnit {
    public static let opcode = Opcode.textResponse

    public var final = true
    public var continued = false
    public var lun: UInt64 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var targetTransferTag: UInt32 = 0xFFFF_FFFF
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .textResponse else { throw PDUError.malformed("opcode") }
        final = raw.bhs.u8(1) & 0x80 != 0
        continued = raw.bhs.u8(1) & 0x40 != 0
        if final && continued { throw PDUError.malformed("F and C bits both set") }
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        targetTransferTag = raw.bhs.beU32(20)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .textResponse)
        b.flags = (final ? 0x80 : 0) | (continued ? 0x40 : 0)
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(targetTransferTag, 20)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// NOP-In (opcode 0x20), §11.19.
public struct NopInPDU: ProtocolDataUnit {
    public static let opcode = Opcode.nopIn

    public var lun: UInt64 = 0
    /// 0xFFFFFFFF when this is a target-initiated ping.
    public var initiatorTaskTag: UInt32 = 0xFFFF_FFFF
    /// != 0xFFFFFFFF means the initiator MUST echo it with a NOP-Out.
    public var targetTransferTag: UInt32 = 0xFFFF_FFFF
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .nopIn else { throw PDUError.malformed("opcode") }
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        targetTransferTag = raw.bhs.beU32(20)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        dataSegment = raw.data
        // Both tags may be 0xffffffff (§11.19.1): a NOP-In the target sends
        // purely to update ExpCmdSN/MaxCmdSN, wanting no reply.
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .nopIn)
        b.flags = 0x80
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(targetTransferTag, 20)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }

    public var isPing: Bool { targetTransferTag != 0xFFFF_FFFF }
}

/// Logout Response (opcode 0x26), §11.15.
public struct LogoutResponsePDU: ProtocolDataUnit {
    public static let opcode = Opcode.logoutResponse

    public enum Response: UInt8, Sendable {
        case success = 0
        case cidNotFound = 1
        case recoveryNotSupported = 2
        case cleanupFailed = 3
    }

    public var response: Response = .success
    public var initiatorTaskTag: UInt32 = 0
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var time2Wait: UInt16 = 0
    public var time2Retain: UInt16 = 0

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .logoutResponse else { throw PDUError.malformed("opcode") }
        guard let r = Response(rawValue: raw.bhs.u8(2)) else {
            throw PDUError.malformed("logout response \(raw.bhs.u8(2))")
        }
        response = r
        initiatorTaskTag = raw.bhs.beU32(16)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        time2Wait = raw.bhs.beU16(40)
        time2Retain = raw.bhs.beU16(42)
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .logoutResponse)
        b.flags = 0x80
        b.bytes.setU8(response.rawValue, 2)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        b.bytes.setBE16(time2Wait, 40)
        b.bytes.setBE16(time2Retain, 42)
        return RawPDU(bhs: b.bytes)
    }
}

/// Async Message (opcode 0x32), §11.9.
public struct AsyncMessagePDU: ProtocolDataUnit {
    public static let opcode = Opcode.asyncMessage

    public enum Event: UInt8, Sendable {
        case scsiAsyncEvent = 0
        case logoutRequest = 1
        case connectionDropNotification = 2
        case sessionDropNotification = 3
        case negotiationRequest = 4
        case vendorSpecific = 255
    }

    public var lun: UInt64 = 0
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var event: Event = .scsiAsyncEvent
    public var vcode: UInt8 = 0
    public var parameter1: UInt16 = 0
    public var parameter2: UInt16 = 0
    public var parameter3: UInt16 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .asyncMessage else { throw PDUError.malformed("opcode") }
        guard raw.bhs.beU32(16) == 0xFFFF_FFFF else {
            throw PDUError.malformed("Async Message ITT must be 0xffffffff")
        }
        lun = raw.bhs.beU64(8)
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        guard let e = Event(rawValue: raw.bhs.u8(36)) else {
            throw PDUError.malformed("async event \(raw.bhs.u8(36))")
        }
        event = e
        vcode = raw.bhs.u8(37)
        parameter1 = raw.bhs.beU16(38)
        parameter2 = raw.bhs.beU16(40)
        parameter3 = raw.bhs.beU16(42)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .asyncMessage)
        b.flags = 0x80
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(0xFFFF_FFFF, 16)
        b.bytes.setBE32(0xFFFF_FFFF, 20)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        b.bytes.setU8(event.rawValue, 36)
        b.bytes.setU8(vcode, 37)
        b.bytes.setBE16(parameter1, 38)
        b.bytes.setBE16(parameter2, 40)
        b.bytes.setBE16(parameter3, 42)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// Reject (opcode 0x3f), §11.17.
public struct RejectPDU: ProtocolDataUnit {
    public static let opcode = Opcode.reject

    public enum Reason: UInt8, Sendable {
        case dataDigestError = 0x02
        case snackReject = 0x03
        case protocolError = 0x04
        case commandNotSupported = 0x05
        case immediateCommandReject = 0x06
        case taskInProgress = 0x07
        case invalidDataACK = 0x08
        case invalidPDUField = 0x09
        case longOperationReject = 0x0A
        case negotiationReset = 0x0B // deprecated
        case waitingForLogout = 0x0C
    }

    public var reason: Reason = .protocolError
    public var statSN: UInt32 = 0
    public var expCmdSN: UInt32 = 0
    public var maxCmdSN: UInt32 = 0
    public var dataSNOrR2TSN: UInt32 = 0
    /// The header of the PDU being rejected.
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .reject else { throw PDUError.malformed("opcode") }
        guard let r = Reason(rawValue: raw.bhs.u8(2)) else {
            throw PDUError.malformed("reject reason \(raw.bhs.u8(2))")
        }
        reason = r
        statSN = raw.bhs.beU32(24)
        expCmdSN = raw.bhs.beU32(28)
        maxCmdSN = raw.bhs.beU32(32)
        dataSNOrR2TSN = raw.bhs.beU32(36)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .reject)
        b.flags = 0x80
        b.bytes.setU8(reason.rawValue, 2)
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE32(0xFFFF_FFFF, 16)
        b.bytes.setBE32(statSN, 24)
        b.bytes.setBE32(expCmdSN, 28)
        b.bytes.setBE32(maxCmdSN, 32)
        b.bytes.setBE32(dataSNOrR2TSN, 36)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}
