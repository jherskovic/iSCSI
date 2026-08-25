import Foundation

// PDUs sent initiator → target (RFC 7143 §11).

/// SCSI Command (opcode 0x01), §11.3.
public struct SCSICommandPDU: ProtocolDataUnit {
    public static let opcode = Opcode.scsiCommand

    public enum TaskAttribute: UInt8, Sendable {
        case untagged = 0, simple = 1, ordered = 2, headOfQueue = 3, aca = 4
    }

    public var immediate = false
    public var final = true
    public var read = false
    public var write = false
    public var attribute: TaskAttribute = .simple
    public var lun: UInt64 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var expectedDataTransferLength: UInt32 = 0
    public var cmdSN: UInt32 = 0
    public var expStatSN: UInt32 = 0
    /// CDB, 1–16 bytes (zero-padded on the wire; longer CDBs need AHS — unsupported).
    public var cdb: Data = Data()
    /// Immediate (unsolicited first-burst) write data.
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .scsiCommand else { throw PDUError.malformed("opcode") }
        immediate = raw.immediate
        let f = raw.bhs.u8(1)
        final = f & 0x80 != 0
        read = f & 0x40 != 0
        write = f & 0x20 != 0
        attribute = TaskAttribute(rawValue: f & 0x07) ?? .simple
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        expectedDataTransferLength = raw.bhs.beU32(20)
        cmdSN = raw.bhs.beU32(24)
        expStatSN = raw.bhs.beU32(28)
        cdb = Data(raw.bhs.sub(32, 16))
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        precondition(cdb.count <= 16, "CDBs longer than 16 bytes require AHS")
        var b = BHSBuilder(opcode: .scsiCommand, immediate: immediate)
        b.flags = (final ? 0x80 : 0) | (read ? 0x40 : 0) | (write ? 0x20 : 0) | attribute.rawValue
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(expectedDataTransferLength, 20)
        b.bytes.setBE32(cmdSN, 24)
        b.bytes.setBE32(expStatSN, 28)
        var paddedCDB = cdb
        paddedCDB.append(Data(count: 16 - cdb.count))
        b.bytes.setSub(paddedCDB, 32)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// SCSI Data-Out (opcode 0x05), §11.7.
public struct DataOutPDU: ProtocolDataUnit {
    public static let opcode = Opcode.scsiDataOut

    public var final = true
    public var lun: UInt64 = 0
    public var initiatorTaskTag: UInt32 = 0
    /// Target Transfer Tag from the R2T being answered, or 0xFFFFFFFF for unsolicited data.
    public var targetTransferTag: UInt32 = 0xFFFF_FFFF
    public var expStatSN: UInt32 = 0
    public var dataSN: UInt32 = 0
    public var bufferOffset: UInt32 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .scsiDataOut else { throw PDUError.malformed("opcode") }
        final = raw.bhs.u8(1) & 0x80 != 0
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        targetTransferTag = raw.bhs.beU32(20)
        expStatSN = raw.bhs.beU32(28)
        dataSN = raw.bhs.beU32(36)
        bufferOffset = raw.bhs.beU32(40)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .scsiDataOut)
        b.flags = final ? 0x80 : 0
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(targetTransferTag, 20)
        b.bytes.setBE32(expStatSN, 28)
        b.bytes.setBE32(dataSN, 36)
        b.bytes.setBE32(bufferOffset, 40)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// Task Management Function Request (opcode 0x02), §11.5.
public struct TMFRequestPDU: ProtocolDataUnit {
    public static let opcode = Opcode.tmfRequest

    public enum Function: UInt8, Sendable {
        case abortTask = 1
        case abortTaskSet = 2
        case clearACA = 3
        case clearTaskSet = 4
        case lunReset = 5
        case targetWarmReset = 6
        case targetColdReset = 7
        case taskReassign = 8
    }

    public var immediate = true
    public var function: Function = .abortTask
    public var lun: UInt64 = 0
    public var initiatorTaskTag: UInt32 = 0
    /// ITT of the task being aborted (ABORT TASK / TASK REASSIGN), else 0xFFFFFFFF.
    public var referencedTaskTag: UInt32 = 0xFFFF_FFFF
    public var cmdSN: UInt32 = 0
    public var expStatSN: UInt32 = 0
    /// CmdSN of the referenced command (ABORT TASK), else reserved.
    public var refCmdSN: UInt32 = 0
    public var expDataSN: UInt32 = 0

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .tmfRequest else { throw PDUError.malformed("opcode") }
        immediate = raw.immediate
        guard let f = Function(rawValue: raw.bhs.u8(1) & 0x7F) else {
            throw PDUError.malformed("TMF function \(raw.bhs.u8(1) & 0x7F)")
        }
        function = f
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        referencedTaskTag = raw.bhs.beU32(20)
        cmdSN = raw.bhs.beU32(24)
        expStatSN = raw.bhs.beU32(28)
        refCmdSN = raw.bhs.beU32(32)
        expDataSN = raw.bhs.beU32(36)
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .tmfRequest, immediate: immediate)
        b.flags = 0x80 | function.rawValue
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(referencedTaskTag, 20)
        b.bytes.setBE32(cmdSN, 24)
        b.bytes.setBE32(expStatSN, 28)
        b.bytes.setBE32(refCmdSN, 32)
        b.bytes.setBE32(expDataSN, 36)
        return RawPDU(bhs: b.bytes)
    }
}

/// Login Request (opcode 0x03), §11.12. Always marked immediate on the wire.
public struct LoginRequestPDU: ProtocolDataUnit {
    public static let opcode = Opcode.loginRequest

    public var transit = false
    /// C bit: text continued in next PDU.
    public var continued = false
    public var currentStage: LoginStage = .securityNegotiation
    public var nextStage: LoginStage = .securityNegotiation
    public var versionMax: UInt8 = 0
    public var versionMin: UInt8 = 0
    public var isid: ISID = ISID()
    public var tsih: UInt16 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var cid: UInt16 = 0
    public var cmdSN: UInt32 = 0
    public var expStatSN: UInt32 = 0
    /// Login text keys.
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .loginRequest else { throw PDUError.malformed("opcode") }
        let f = raw.bhs.u8(1)
        transit = f & 0x80 != 0
        continued = f & 0x40 != 0
        guard let csg = LoginStage(rawValue: (f >> 2) & 0x3), let nsg = LoginStage(rawValue: f & 0x3) else {
            throw PDUError.malformed("login stage")
        }
        if transit && continued { throw PDUError.malformed("T and C bits both set") }
        currentStage = csg
        nextStage = nsg
        versionMax = raw.bhs.u8(2)
        versionMin = raw.bhs.u8(3)
        isid = ISID(raw.bhs.sub(8, 6))
        tsih = raw.bhs.beU16(14)
        initiatorTaskTag = raw.bhs.beU32(16)
        cid = raw.bhs.beU16(20)
        cmdSN = raw.bhs.beU32(24)
        expStatSN = raw.bhs.beU32(28)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .loginRequest, immediate: true)
        b.flags = (transit ? 0x80 : 0) | (continued ? 0x40 : 0)
            | (currentStage.rawValue << 2) | nextStage.rawValue
        b.bytes.setU8(versionMax, 2)
        b.bytes.setU8(versionMin, 3)
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setSub(isid.bytes, 8)
        b.bytes.setBE16(tsih, 14)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE16(cid, 20)
        b.bytes.setBE32(cmdSN, 24)
        b.bytes.setBE32(expStatSN, 28)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// Text Request (opcode 0x04), §11.10.
public struct TextRequestPDU: ProtocolDataUnit {
    public static let opcode = Opcode.textRequest

    public var immediate = false
    public var final = true
    public var continued = false
    public var lun: UInt64 = 0
    public var initiatorTaskTag: UInt32 = 0
    public var targetTransferTag: UInt32 = 0xFFFF_FFFF
    public var cmdSN: UInt32 = 0
    public var expStatSN: UInt32 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .textRequest else { throw PDUError.malformed("opcode") }
        immediate = raw.immediate
        final = raw.bhs.u8(1) & 0x80 != 0
        continued = raw.bhs.u8(1) & 0x40 != 0
        if final && continued { throw PDUError.malformed("F and C bits both set") }
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        targetTransferTag = raw.bhs.beU32(20)
        cmdSN = raw.bhs.beU32(24)
        expStatSN = raw.bhs.beU32(28)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .textRequest, immediate: immediate)
        b.flags = (final ? 0x80 : 0) | (continued ? 0x40 : 0)
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(targetTransferTag, 20)
        b.bytes.setBE32(cmdSN, 24)
        b.bytes.setBE32(expStatSN, 28)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// NOP-Out (opcode 0x00), §11.18.
public struct NopOutPDU: ProtocolDataUnit {
    public static let opcode = Opcode.nopOut

    public var immediate = false
    public var lun: UInt64 = 0
    /// 0xFFFFFFFF when no response is wanted (only valid as a NOP-In echo).
    public var initiatorTaskTag: UInt32 = 0
    /// Echoes the TTT of a target NOP-In ping, else 0xFFFFFFFF.
    public var targetTransferTag: UInt32 = 0xFFFF_FFFF
    public var cmdSN: UInt32 = 0
    public var expStatSN: UInt32 = 0
    public var dataSegment: Data = Data()

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .nopOut else { throw PDUError.malformed("opcode") }
        immediate = raw.immediate
        guard raw.bhs.u8(1) == 0x80 else { throw PDUError.malformed("NOP-Out flags") }
        lun = raw.bhs.beU64(8)
        initiatorTaskTag = raw.bhs.beU32(16)
        targetTransferTag = raw.bhs.beU32(20)
        cmdSN = raw.bhs.beU32(24)
        expStatSN = raw.bhs.beU32(28)
        dataSegment = raw.data
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .nopOut, immediate: immediate)
        b.flags = 0x80
        b.setDataSegmentLength(dataSegment.count)
        b.bytes.setBE64(lun, 8)
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE32(targetTransferTag, 20)
        b.bytes.setBE32(cmdSN, 24)
        b.bytes.setBE32(expStatSN, 28)
        return RawPDU(bhs: b.bytes, data: dataSegment)
    }
}

/// Logout Request (opcode 0x06), §11.14.
public struct LogoutRequestPDU: ProtocolDataUnit {
    public static let opcode = Opcode.logoutRequest

    public enum Reason: UInt8, Sendable {
        case closeSession = 0
        case closeConnection = 1
        case removeConnectionForRecovery = 2
    }

    public var immediate = true
    public var reason: Reason = .closeSession
    public var initiatorTaskTag: UInt32 = 0
    public var cid: UInt16 = 0
    public var cmdSN: UInt32 = 0
    public var expStatSN: UInt32 = 0

    public init() {}

    public init(raw: RawPDU) throws {
        guard raw.opcode == .logoutRequest else { throw PDUError.malformed("opcode") }
        immediate = raw.immediate
        guard let r = Reason(rawValue: raw.bhs.u8(1) & 0x7F) else {
            throw PDUError.malformed("logout reason")
        }
        reason = r
        initiatorTaskTag = raw.bhs.beU32(16)
        cid = raw.bhs.beU16(20)
        cmdSN = raw.bhs.beU32(24)
        expStatSN = raw.bhs.beU32(28)
    }

    public func encode() -> RawPDU {
        var b = BHSBuilder(opcode: .logoutRequest, immediate: immediate)
        b.flags = 0x80 | reason.rawValue
        b.bytes.setBE32(initiatorTaskTag, 16)
        b.bytes.setBE16(cid, 20)
        b.bytes.setBE32(cmdSN, 24)
        b.bytes.setBE32(expStatSN, 28)
        return RawPDU(bhs: b.bytes)
    }
}

/// Login negotiation stages (CSG/NSG values).
public enum LoginStage: UInt8, Sendable {
    case securityNegotiation = 0
    case loginOperationalNegotiation = 1
    case fullFeaturePhase = 3
}

/// 6-byte Initiator Session ID.
public struct ISID: Sendable, Equatable, Hashable {
    public var bytes: Data // exactly 6

    public init() {
        // 0x80 = T=10b ("Random" format, RFC 7143 §11.12.5); B/C random, D qualifier.
        bytes = Data([0x80, 0, 0, 0, 0, 0])
    }

    public init(_ data: Data) {
        precondition(data.count == 6)
        bytes = Data(data)
    }

    public static func random(qualifier: UInt16 = 0) -> ISID {
        var d = Data(count: 6)
        d.setU8(0x80, 0)
        d.setU8(UInt8.random(in: 0 ... 255), 1)
        d.setU8(UInt8.random(in: 0 ... 255), 2)
        d.setU8(UInt8.random(in: 0 ... 255), 3)
        d.setBE16(qualifier, 4)
        return ISID(d)
    }
}
