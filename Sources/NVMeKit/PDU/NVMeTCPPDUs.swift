import Foundation
import iSCSIKit

/// One concrete PDU type. `encode()` produces the PSH and data; digests,
/// PDO and PLEN are the serializer's job. Layouts follow NVMe/TCP 1.0 §3.6.
public protocol NVMeTCPPDU: Sendable, Equatable {
    static var pduType: NVMeTCPPDUType { get }
    init(raw: RawNVMeTCPPDU) throws
    func encode() -> RawNVMeTCPPDU
}

extension RawNVMeTCPPDU {
    /// Every PDU type has a fixed PSH length; anything else is a peer we
    /// cannot talk to, not a value to be lenient about.
    func requirePSH(_ count: Int, for type: NVMeTCPPDUType) throws {
        guard self.type == type.rawValue else {
            throw NVMeTCPError.malformed("expected \(type) PDU, got type \(self.type)")
        }
        guard psh.count == count else {
            throw NVMeTCPError.malformed("\(type) PSH must be \(count) bytes, got \(psh.count)")
        }
    }
}

extension NVMeTCPDigests {
    /// The DGST byte of ICReq/ICResp: bit 0 HDGST_ENABLE, bit 1 DDGST_ENABLE.
    init(dgstByte: UInt8) {
        self.init(header: dgstByte & 0x01 != 0, data: dgstByte & 0x02 != 0)
    }

    var dgstByte: UInt8 { (header ? 0x01 : 0) | (data ? 0x02 : 0) }
}

// MARK: - Initialize connection

/// ICReq (host → controller), 128 bytes. PFV 0 is the only version; HPDA is
/// always 0 because we never want padded data; DGST offers digests; MAXR2T
/// is 0's based (0 = one outstanding R2T per command, which is what Linux
/// offers too).
public struct ICReqPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.icReq
    static let pshSize = 120

    public var pfv: UInt16 = 0
    public var hpda: UInt8 = 0
    public var digests = NVMeTCPDigests()
    public var maxR2T: UInt32 = 0

    public init() {}

    public init(raw: RawNVMeTCPPDU) throws {
        try raw.requirePSH(Self.pshSize, for: .icReq)
        pfv = raw.psh.leU16(0)
        hpda = raw.psh.u8(2)
        digests = NVMeTCPDigests(dgstByte: raw.psh.u8(3))
        maxR2T = raw.psh.leU32(4)
    }

    public func encode() -> RawNVMeTCPPDU {
        var psh = Data(count: Self.pshSize)
        psh.setLE16(pfv, 0)
        psh.setU8(hpda, 2)
        psh.setU8(digests.dgstByte, 3)
        psh.setLE32(maxR2T, 4)
        return RawNVMeTCPPDU(type: .icReq, psh: psh)
    }
}

/// ICResp (controller → host), 128 bytes. CPDA is the controller's data
/// alignment demand (we refuse anything but 0); DGST is the digests it
/// accepted; MAXH2CDATA bounds each H2CData PDU we may send.
public struct ICRespPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.icResp
    static let pshSize = 120

    public var pfv: UInt16
    public var cpda: UInt8
    public var digests: NVMeTCPDigests
    public var maxH2CData: UInt32

    public init(pfv: UInt16 = 0, cpda: UInt8 = 0, digests: NVMeTCPDigests = NVMeTCPDigests(),
                maxH2CData: UInt32 = 0) {
        self.pfv = pfv
        self.cpda = cpda
        self.digests = digests
        self.maxH2CData = maxH2CData
    }

    public init(raw: RawNVMeTCPPDU) throws {
        try raw.requirePSH(Self.pshSize, for: .icResp)
        pfv = raw.psh.leU16(0)
        cpda = raw.psh.u8(2)
        digests = NVMeTCPDigests(dgstByte: raw.psh.u8(3))
        maxH2CData = raw.psh.leU32(4)
    }

    public func encode() -> RawNVMeTCPPDU {
        var psh = Data(count: Self.pshSize)
        psh.setLE16(pfv, 0)
        psh.setU8(cpda, 2)
        psh.setU8(digests.dgstByte, 3)
        psh.setLE32(maxH2CData, 4)
        return RawNVMeTCPPDU(type: .icResp, psh: psh)
    }
}

// MARK: - Termination

/// Fatal Error Status of a termination request. A struct rather than an
/// enum so a value this implementation does not know still decodes and can
/// be logged.
public struct NVMeTCPFatalErrorStatus: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let invalidPDUHeader = Self(rawValue: 0x01)
    public static let pduSequenceError = Self(rawValue: 0x02)
    public static let headerDigestError = Self(rawValue: 0x03)
    public static let dataTransferOutOfRange = Self(rawValue: 0x04)
    public static let dataTransferLimitExceeded = Self(rawValue: 0x05)
    public static let unsupportedParameter = Self(rawValue: 0x06)
}

/// The fields common to H2CTermReq and C2HTermReq: FES, 4 bytes of FEI, and
/// the header of the PDU that caused the error as data (up to 128 bytes).
struct TermReqFields: Sendable, Equatable {
    static let pshSize = 16
    var fes: NVMeTCPFatalErrorStatus
    var fei: UInt32
    var offendingHeader: Data

    init(fes: NVMeTCPFatalErrorStatus, fei: UInt32, offendingHeader: Data) {
        self.fes = fes
        self.fei = fei
        self.offendingHeader = offendingHeader
    }

    init(raw: RawNVMeTCPPDU, type: NVMeTCPPDUType) throws {
        try raw.requirePSH(Self.pshSize, for: type)
        fes = NVMeTCPFatalErrorStatus(rawValue: raw.psh.leU16(0))
        fei = raw.psh.leU32(2)
        offendingHeader = raw.data
    }

    func encode(as type: NVMeTCPPDUType) -> RawNVMeTCPPDU {
        var psh = Data(count: Self.pshSize)
        psh.setLE16(fes.rawValue, 0)
        psh.setLE32(fei, 2)
        return RawNVMeTCPPDU(type: type, psh: psh, data: offendingHeader)
    }
}

public struct H2CTermReqPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.h2cTermReq
    var fields: TermReqFields

    public var fes: NVMeTCPFatalErrorStatus { fields.fes }
    public var fei: UInt32 { fields.fei }
    public var offendingHeader: Data { fields.offendingHeader }

    public init(fes: NVMeTCPFatalErrorStatus, fei: UInt32 = 0, offendingHeader: Data = Data()) {
        fields = TermReqFields(fes: fes, fei: fei, offendingHeader: offendingHeader)
    }

    public init(raw: RawNVMeTCPPDU) throws {
        fields = try TermReqFields(raw: raw, type: .h2cTermReq)
    }

    public func encode() -> RawNVMeTCPPDU { fields.encode(as: .h2cTermReq) }
}

public struct C2HTermReqPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.c2hTermReq
    var fields: TermReqFields

    public var fes: NVMeTCPFatalErrorStatus { fields.fes }
    public var fei: UInt32 { fields.fei }
    public var offendingHeader: Data { fields.offendingHeader }

    public init(fes: NVMeTCPFatalErrorStatus, fei: UInt32 = 0, offendingHeader: Data = Data()) {
        fields = TermReqFields(fes: fes, fei: fei, offendingHeader: offendingHeader)
    }

    public init(raw: RawNVMeTCPPDU) throws {
        fields = try TermReqFields(raw: raw, type: .c2hTermReq)
    }

    public func encode() -> RawNVMeTCPPDU { fields.encode(as: .c2hTermReq) }
}

// MARK: - Capsules

/// CapsuleCmd: a 64-byte SQE, optionally followed by in-capsule data. The
/// SQE is carried as bytes here; `SQE` in the Capsule layer builds it.
public struct CapsuleCmdPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.capsuleCmd
    public static let sqeSize = 64

    public var sqe: Data
    public var inCapsuleData: Data

    public init(sqe: Data, inCapsuleData: Data = Data()) {
        precondition(sqe.count == Self.sqeSize, "an SQE is exactly 64 bytes")
        self.sqe = sqe
        self.inCapsuleData = inCapsuleData
    }

    public init(raw: RawNVMeTCPPDU) throws {
        try raw.requirePSH(Self.sqeSize, for: .capsuleCmd)
        sqe = raw.psh
        inCapsuleData = raw.data
    }

    public func encode() -> RawNVMeTCPPDU {
        RawNVMeTCPPDU(type: .capsuleCmd, psh: sqe, data: inCapsuleData)
    }
}

/// CapsuleResp: a 16-byte CQE. Never carries data on TCP.
public struct CapsuleRespPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.capsuleResp
    public static let cqeSize = 16

    public var cqe: Data

    public init(cqe: Data) {
        precondition(cqe.count == Self.cqeSize, "a CQE is exactly 16 bytes")
        self.cqe = cqe
    }

    public init(raw: RawNVMeTCPPDU) throws {
        try raw.requirePSH(Self.cqeSize, for: .capsuleResp)
        guard raw.data.isEmpty else {
            throw NVMeTCPError.malformed("CapsuleResp carries \(raw.data.count) bytes of data")
        }
        cqe = raw.psh
    }

    public func encode() -> RawNVMeTCPPDU {
        RawNVMeTCPPDU(type: .capsuleResp, psh: cqe)
    }
}

// MARK: - Data transfer

/// H2CData (host → controller): one chunk of write data, answering an R2T.
/// PSH: CCCID, TTAG (from the R2T), DATAO, DATAL, reserved.
public struct H2CDataPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.h2cData
    static let pshSize = 16

    public var cccid: UInt16
    public var ttag: UInt16
    public var dataOffset: UInt32
    public var data: Data
    public var last: Bool

    public init(cccid: UInt16, ttag: UInt16, dataOffset: UInt32, data: Data, last: Bool) {
        self.cccid = cccid
        self.ttag = ttag
        self.dataOffset = dataOffset
        self.data = data
        self.last = last
    }

    public init(raw: RawNVMeTCPPDU) throws {
        try raw.requirePSH(Self.pshSize, for: .h2cData)
        cccid = raw.psh.leU16(0)
        ttag = raw.psh.leU16(2)
        dataOffset = raw.psh.leU32(4)
        let dataLength = raw.psh.leU32(8)
        guard dataLength == UInt32(raw.data.count) else {
            throw NVMeTCPError.malformed("H2CData DATAL \(dataLength) but \(raw.data.count) bytes of data")
        }
        data = raw.data
        last = raw.flags.contains(.lastPDU)
    }

    public func encode() -> RawNVMeTCPPDU {
        var psh = Data(count: Self.pshSize)
        psh.setLE16(cccid, 0)
        psh.setLE16(ttag, 2)
        psh.setLE32(dataOffset, 4)
        psh.setLE32(UInt32(data.count), 8)
        return RawNVMeTCPPDU(type: .h2cData, flags: last ? [.lastPDU] : [], psh: psh, data: data)
    }
}

/// C2HData (controller → host): one chunk of read data. SUCCESS means this
/// PDU also completes the command and no CapsuleResp will follow.
public struct C2HDataPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.c2hData
    static let pshSize = 16

    public var cccid: UInt16
    public var dataOffset: UInt32
    public var data: Data
    public var last: Bool
    public var success: Bool

    public init(cccid: UInt16, dataOffset: UInt32, data: Data, last: Bool, success: Bool) {
        self.cccid = cccid
        self.dataOffset = dataOffset
        self.data = data
        self.last = last
        self.success = success
    }

    public init(raw: RawNVMeTCPPDU) throws {
        try raw.requirePSH(Self.pshSize, for: .c2hData)
        cccid = raw.psh.leU16(0)
        dataOffset = raw.psh.leU32(4)
        let dataLength = raw.psh.leU32(8)
        guard dataLength == UInt32(raw.data.count) else {
            throw NVMeTCPError.malformed("C2HData DATAL \(dataLength) but \(raw.data.count) bytes of data")
        }
        data = raw.data
        last = raw.flags.contains(.lastPDU)
        success = raw.flags.contains(.success)
    }

    public func encode() -> RawNVMeTCPPDU {
        var psh = Data(count: Self.pshSize)
        psh.setLE16(cccid, 0)
        psh.setLE32(dataOffset, 4)
        psh.setLE32(UInt32(data.count), 8)
        var flags: NVMeTCPFlags = []
        if last { flags.insert(.lastPDU) }
        if success { flags.insert(.success) }
        return RawNVMeTCPPDU(type: .c2hData, flags: flags, psh: psh, data: data)
    }
}

/// R2T (controller → host): permission to send `length` bytes of a write
/// starting at `offset`, tagged so the H2CData PDUs can name it.
public struct NVMeR2TPDU: NVMeTCPPDU {
    public static let pduType = NVMeTCPPDUType.r2t
    static let pshSize = 16

    public var cccid: UInt16
    public var ttag: UInt16
    public var offset: UInt32
    public var length: UInt32

    public init(cccid: UInt16, ttag: UInt16, offset: UInt32, length: UInt32) {
        self.cccid = cccid
        self.ttag = ttag
        self.offset = offset
        self.length = length
    }

    public init(raw: RawNVMeTCPPDU) throws {
        try raw.requirePSH(Self.pshSize, for: .r2t)
        guard raw.data.isEmpty else {
            throw NVMeTCPError.malformed("R2T carries \(raw.data.count) bytes of data")
        }
        cccid = raw.psh.leU16(0)
        ttag = raw.psh.leU16(2)
        offset = raw.psh.leU32(4)
        length = raw.psh.leU32(8)
    }

    public func encode() -> RawNVMeTCPPDU {
        var psh = Data(count: Self.pshSize)
        psh.setLE16(cccid, 0)
        psh.setLE16(ttag, 2)
        psh.setLE32(offset, 4)
        psh.setLE32(length, 8)
        return RawNVMeTCPPDU(type: .r2t, psh: psh)
    }
}

// MARK: - Dispatch

/// Type-dispatched decoding of a framed PDU, the NVMe/TCP `AnyPDU`.
public enum AnyNVMeTCPPDU: Sendable, Equatable {
    case icReq(ICReqPDU)
    case icResp(ICRespPDU)
    case h2cTermReq(H2CTermReqPDU)
    case c2hTermReq(C2HTermReqPDU)
    case capsuleCmd(CapsuleCmdPDU)
    case capsuleResp(CapsuleRespPDU)
    case h2cData(H2CDataPDU)
    case c2hData(C2HDataPDU)
    case r2t(NVMeR2TPDU)

    public static func decode(_ raw: RawNVMeTCPPDU) throws -> AnyNVMeTCPPDU {
        guard let type = raw.pduType else { throw NVMeTCPError.unknownType(raw.type) }
        switch type {
        case .icReq: return .icReq(try ICReqPDU(raw: raw))
        case .icResp: return .icResp(try ICRespPDU(raw: raw))
        case .h2cTermReq: return .h2cTermReq(try H2CTermReqPDU(raw: raw))
        case .c2hTermReq: return .c2hTermReq(try C2HTermReqPDU(raw: raw))
        case .capsuleCmd: return .capsuleCmd(try CapsuleCmdPDU(raw: raw))
        case .capsuleResp: return .capsuleResp(try CapsuleRespPDU(raw: raw))
        case .h2cData: return .h2cData(try H2CDataPDU(raw: raw))
        case .c2hData: return .c2hData(try C2HDataPDU(raw: raw))
        case .r2t: return .r2t(try NVMeR2TPDU(raw: raw))
        }
    }

    public var pduType: NVMeTCPPDUType {
        switch self {
        case .icReq: return .icReq
        case .icResp: return .icResp
        case .h2cTermReq: return .h2cTermReq
        case .c2hTermReq: return .c2hTermReq
        case .capsuleCmd: return .capsuleCmd
        case .capsuleResp: return .capsuleResp
        case .h2cData: return .h2cData
        case .c2hData: return .c2hData
        case .r2t: return .r2t
        }
    }

    public func encode() -> RawNVMeTCPPDU {
        switch self {
        case .icReq(let p): return p.encode()
        case .icResp(let p): return p.encode()
        case .h2cTermReq(let p): return p.encode()
        case .c2hTermReq(let p): return p.encode()
        case .capsuleCmd(let p): return p.encode()
        case .capsuleResp(let p): return p.encode()
        case .h2cData(let p): return p.encode()
        case .c2hData(let p): return p.encode()
        case .r2t(let p): return p.encode()
        }
    }
}
