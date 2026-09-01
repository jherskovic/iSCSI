import Foundation
import iSCSIKit

/// NVMe/TCP PDU types (NVMe/TCP Transport Specification §3.3).
public enum NVMeTCPPDUType: UInt8, Sendable, CaseIterable {
    case icReq = 0x00
    case icResp = 0x01
    case h2cTermReq = 0x02
    case c2hTermReq = 0x03
    case capsuleCmd = 0x04
    case capsuleResp = 0x05
    case h2cData = 0x06
    case c2hData = 0x07
    case r2t = 0x09
}

/// The FLAGS byte of the common header. The two digest bits are owned by the
/// serializer (set from the negotiated `NVMeTCPDigests`); the other two are
/// per-PDU semantics that callers set.
public struct NVMeTCPFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// HDGSTF: a header digest follows the PDU header.
    public static let headerDigest = NVMeTCPFlags(rawValue: 1 << 0)
    /// DDGSTF: a data digest follows the data.
    public static let dataDigest = NVMeTCPFlags(rawValue: 1 << 1)
    /// LAST_PDU: final data PDU of a transfer (H2CData / C2HData).
    public static let lastPDU = NVMeTCPFlags(rawValue: 1 << 2)
    /// SUCCESS: this C2HData PDU also completes the command; no CapsuleResp
    /// follows.
    public static let success = NVMeTCPFlags(rawValue: 1 << 3)
}

public enum NVMeTCPError: Error, Equatable, Sendable {
    case headerTooShort
    case pduTooLarge(length: Int, limit: Int)
    case headerDigestMismatch
    case dataDigestMismatch
    case unknownType(UInt8)
    case malformed(String)
}

/// The 8-byte common header every PDU starts with: type, flags, HLEN (bytes
/// of header incl. this one), PDO (offset of the data from byte 0; 0 when
/// there is no data), PLEN (whole PDU incl. digests and padding).
public struct NVMeTCPHeader: Sendable, Equatable {
    public static let size = 8

    public var type: UInt8
    public var flags: NVMeTCPFlags
    public var hlen: UInt8
    public var pdo: UInt8
    public var plen: UInt32

    public init(type: UInt8, flags: NVMeTCPFlags, hlen: UInt8, pdo: UInt8, plen: UInt32) {
        self.type = type
        self.flags = flags
        self.hlen = hlen
        self.pdo = pdo
        self.plen = plen
    }

    public init(bytes: Data) throws {
        guard bytes.count >= Self.size else { throw NVMeTCPError.headerTooShort }
        type = bytes.u8(0)
        flags = NVMeTCPFlags(rawValue: bytes.u8(1))
        hlen = bytes.u8(2)
        pdo = bytes.u8(3)
        plen = bytes.leU32(4)
    }

    /// nil for a type this implementation does not know; the byte is kept so
    /// a termination request can still name it.
    public var pduType: NVMeTCPPDUType? { NVMeTCPPDUType(rawValue: type) }

    public var encoded: Data {
        var out = Data(count: Self.size)
        out.setU8(type, 0)
        out.setU8(flags.rawValue, 1)
        out.setU8(hlen, 2)
        out.setU8(pdo, 3)
        out.setLE32(plen, 4)
        return out
    }
}

/// A PDU as framed off the wire, before type-specific decoding: the
/// PDU-specific header (bytes 8 ..< HLEN) and the data (from PDO), with any
/// padding dropped and both digests already verified by the deframer.
public struct RawNVMeTCPPDU: Sendable, Equatable {
    public var type: UInt8
    public var flags: NVMeTCPFlags
    public var psh: Data
    public var data: Data

    public init(type: NVMeTCPPDUType, flags: NVMeTCPFlags = [], psh: Data, data: Data = Data()) {
        self.init(rawType: type.rawValue, flags: flags, psh: psh, data: data)
    }

    public init(rawType: UInt8, flags: NVMeTCPFlags = [], psh: Data, data: Data = Data()) {
        precondition(psh.count + NVMeTCPHeader.size <= 255, "HLEN is an 8-bit field")
        self.type = rawType
        self.flags = flags
        self.psh = psh
        self.data = data
    }

    public var pduType: NVMeTCPPDUType? { NVMeTCPPDUType(rawValue: type) }
    /// HLEN as it will appear on the wire.
    public var hlen: Int { NVMeTCPHeader.size + psh.count }
}

/// Digest configuration for one connection, fixed by ICReq/ICResp.
public struct NVMeTCPDigests: Sendable, Equatable {
    public var header: Bool
    public var data: Bool

    public init(header: Bool = false, data: Bool = false) {
        self.header = header
        self.data = data
    }
}
