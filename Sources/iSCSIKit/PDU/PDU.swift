import Foundation

/// A PDU as framed off the wire, before opcode-specific decoding:
/// 48-byte BHS, optional AHS bytes (without padding), data segment (without
/// padding or digests). Digests have already been verified by the deframer.
public struct RawPDU: Sendable, Equatable {
    public var bhs: Data // exactly 48 bytes
    public var ahs: Data
    public var data: Data

    public init(bhs: Data, ahs: Data = Data(), data: Data = Data()) {
        precondition(bhs.count == 48, "BHS must be exactly 48 bytes")
        self.bhs = bhs
        self.ahs = ahs
        self.data = data
    }

    public var opcodeByte: UInt8 { bhs.u8(0) & 0x3F }
    public var immediate: Bool { bhs.u8(0) & 0x40 != 0 }
    public var opcode: Opcode? { Opcode(rawValue: opcodeByte) }
    public var initiatorTaskTag: UInt32 { bhs.beU32(16) }
}

/// One concrete PDU type. `encode()` produces (BHS+AHS, data) — digest and
/// padding framing is the serializer's job.
public protocol ProtocolDataUnit: Sendable, Equatable {
    static var opcode: Opcode { get }
    init(raw: RawPDU) throws
    func encode() -> RawPDU
}

/// Helper for building a 48-byte BHS with the fields common to all PDUs.
struct BHSBuilder {
    var bytes = Data(count: 48)

    init(opcode: Opcode, immediate: Bool = false) {
        bytes.setU8(opcode.rawValue | (immediate ? 0x40 : 0), 0)
    }

    var flags: UInt8 {
        get { bytes.u8(1) }
        set { bytes.setU8(newValue, 1) }
    }

    mutating func setDataSegmentLength(_ n: Int) {
        bytes.setBE24(UInt32(n), 5)
    }

    mutating func setTotalAHSLength(words: Int) {
        bytes.setU8(UInt8(words), 4)
    }
}
