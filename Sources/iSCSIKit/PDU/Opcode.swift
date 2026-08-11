/// iSCSI PDU opcodes (RFC 7143 §11.2.1.2). The immediate-delivery bit (0x40)
/// is carried separately; these are the low 6 bits of byte 0.
public enum Opcode: UInt8, Sendable, CaseIterable {
    // Initiator → target
    case nopOut = 0x00
    case scsiCommand = 0x01
    case tmfRequest = 0x02
    case loginRequest = 0x03
    case textRequest = 0x04
    case scsiDataOut = 0x05
    case logoutRequest = 0x06
    case snackRequest = 0x10

    // Target → initiator
    case nopIn = 0x20
    case scsiResponse = 0x21
    case tmfResponse = 0x22
    case loginResponse = 0x23
    case textResponse = 0x24
    case scsiDataIn = 0x25
    case logoutResponse = 0x26
    case r2t = 0x31
    case asyncMessage = 0x32
    case reject = 0x3F

    public var isTargetOpcode: Bool {
        rawValue >= 0x20
    }
}

public enum PDUError: Error, Equatable, Sendable {
    case truncatedBHS
    case unknownOpcode(UInt8)
    case headerDigestMismatch
    case dataDigestMismatch
    case dataSegmentTooLarge(length: Int, limit: Int)
    case malformed(String)
}
