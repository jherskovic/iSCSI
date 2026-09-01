import Foundation
import iSCSIKit

/// The SGL descriptor at bytes 24–39 of an SQE. NVMe/TCP uses exactly two
/// encodings (NVMe/TCP 1.0 §3.4.2): an SGL Data Block descriptor with the
/// offset subtype for in-capsule data, and a Transport SGL Data Block for
/// data that C2HData/H2CData PDUs move. Byte 15 is `type << 4 | subtype`.
public struct SGLDescriptor: Sendable, Equatable {
    public static let size = 16

    public var address: UInt64
    public var length: UInt32
    public var typeByte: UInt8

    public init(address: UInt64, length: UInt32, typeByte: UInt8) {
        self.address = address
        self.length = length
        self.typeByte = typeByte
    }

    /// Data Block (0h) / offset (1h): the data follows the SQE in the
    /// capsule; `offset` is from the start of the in-capsule region (ICDOFF).
    public static func inCapsule(offset: UInt64 = 0, length: UInt32) -> SGLDescriptor {
        SGLDescriptor(address: offset, length: length, typeByte: 0x01)
    }

    /// Transport Data Block (5h) / Ah: the transport carries the data. With
    /// `length` 0 this is the null SGL a data-less command carries.
    public static func transport(length: UInt32) -> SGLDescriptor {
        SGLDescriptor(address: 0, length: length, typeByte: 0x5A)
    }

    public var isInCapsule: Bool { typeByte == 0x01 }

    init(bytes: Data) {
        address = bytes.leU64(0)
        length = bytes.leU32(8)
        typeByte = bytes.u8(15)
    }

    var encoded: Data {
        var out = Data(count: Self.size)
        out.setLE64(address, 0)
        out.setLE32(length, 8)
        out.setU8(typeByte, 15)
        return out
    }
}

/// The 64-byte submission queue entry. A byte buffer with typed accessors
/// rather than a struct per command: every command shares the first 40
/// bytes and differs only in how it reads CDW10–15.
public struct SQE: Sendable, Equatable {
    public static let size = 64

    public var bytes: Data

    public init() { bytes = Data(count: Self.size) }

    public init(bytes: Data) throws {
        guard bytes.count == Self.size else {
            throw NVMeTCPError.malformed("SQE must be 64 bytes, got \(bytes.count)")
        }
        self.bytes = bytes
    }

    public var opcode: UInt8 {
        get { bytes.u8(0) }
        set { bytes.setU8(newValue, 0) }
    }

    /// Bits 7:6 PSDT (01b = an SGL sits in the SQE), bits 1:0 FUSE.
    public var flags: UInt8 {
        get { bytes.u8(1) }
        set { bytes.setU8(newValue, 1) }
    }

    public var commandID: UInt16 {
        get { bytes.leU16(2) }
        set { bytes.setLE16(newValue, 2) }
    }

    public var nsid: UInt32 {
        get { bytes.leU32(4) }
        set { bytes.setLE32(newValue, 4) }
    }

    /// For opcode 7Fh (Fabrics) byte 4 is the Fabrics command type instead.
    public var fabricsType: UInt8 {
        get { bytes.u8(4) }
        set { bytes.setU8(newValue, 4) }
    }

    /// Setting the SGL also sets PSDT = 01b, which nvmet insists on for every
    /// command including ones without data.
    public var sgl: SGLDescriptor {
        get { SGLDescriptor(bytes: bytes.sub(24, SGLDescriptor.size)) }
        set {
            bytes.setSub(newValue.encoded, 24)
            flags = (flags & ~0xC0) | 0x40
        }
    }

    public var cdw10: UInt32 { get { bytes.leU32(40) } set { bytes.setLE32(newValue, 40) } }
    public var cdw11: UInt32 { get { bytes.leU32(44) } set { bytes.setLE32(newValue, 44) } }
    public var cdw12: UInt32 { get { bytes.leU32(48) } set { bytes.setLE32(newValue, 48) } }
    public var cdw13: UInt32 { get { bytes.leU32(52) } set { bytes.setLE32(newValue, 52) } }
    public var cdw14: UInt32 { get { bytes.leU32(56) } set { bytes.setLE32(newValue, 56) } }
    public var cdw15: UInt32 { get { bytes.leU32(60) } set { bytes.setLE32(newValue, 60) } }
}

/// The 15-bit status of a completion: SC in bits 7:0, SCT in 10:8, CRD in
/// 12:11, MORE in 13, DNR in 14 — after the phase bit is shifted out.
public struct NVMeStatus: Sendable, Equatable, CustomStringConvertible {
    public var sct: UInt8
    public var sc: UInt8
    public var crd: UInt8
    public var more: Bool
    public var dnr: Bool

    public init(sct: UInt8, sc: UInt8, crd: UInt8 = 0, more: Bool = false, dnr: Bool = false) {
        self.sct = sct
        self.sc = sc
        self.crd = crd
        self.more = more
        self.dnr = dnr
    }

    /// From the 16-bit status field of a CQE (bit 0 is the phase tag).
    public init(field: UInt16) {
        sc = UInt8((field >> 1) & 0xFF)
        sct = UInt8((field >> 9) & 0x7)
        crd = UInt8((field >> 12) & 0x3)
        more = field & 0x4000 != 0
        dnr = field & 0x8000 != 0
    }

    /// The status field with the phase bit clear.
    public var field: UInt16 {
        UInt16(sc) << 1 | UInt16(sct & 0x7) << 9 | UInt16(crd & 0x3) << 12
            | (more ? 0x4000 : 0) | (dnr ? 0x8000 : 0)
    }

    public var isSuccess: Bool { sct == 0 && sc == 0 }

    public static let success = NVMeStatus(sct: 0, sc: 0)

    public var description: String { String(format: "sct 0x%02x sc 0x%02x", sct, sc) }
}

/// The 16-byte completion queue entry.
public struct CQE: Sendable, Equatable {
    public static let size = 16

    public var dw0: UInt32
    public var dw1: UInt32
    public var sqHead: UInt16
    public var sqID: UInt16
    public var commandID: UInt16
    public var statusField: UInt16

    public init(dw0: UInt32 = 0, dw1: UInt32 = 0, sqHead: UInt16 = 0, sqID: UInt16 = 0,
                commandID: UInt16, status: NVMeStatus = .success) {
        self.dw0 = dw0
        self.dw1 = dw1
        self.sqHead = sqHead
        self.sqID = sqID
        self.commandID = commandID
        self.statusField = status.field
    }

    public init(bytes: Data) throws {
        guard bytes.count == Self.size else {
            throw NVMeTCPError.malformed("CQE must be 16 bytes, got \(bytes.count)")
        }
        dw0 = bytes.leU32(0)
        dw1 = bytes.leU32(4)
        sqHead = bytes.leU16(8)
        sqID = bytes.leU16(10)
        commandID = bytes.leU16(12)
        statusField = bytes.leU16(14)
    }

    public var encoded: Data {
        var out = Data(count: Self.size)
        out.setLE32(dw0, 0)
        out.setLE32(dw1, 4)
        out.setLE16(sqHead, 8)
        out.setLE16(sqID, 10)
        out.setLE16(commandID, 12)
        out.setLE16(statusField, 14)
        return out
    }

    /// DW1:DW0 as one value, which is how Property Get returns a register.
    public var result64: UInt64 { UInt64(dw1) << 32 | UInt64(dw0) }

    public var status: NVMeStatus { NVMeStatus(field: statusField) }
}
