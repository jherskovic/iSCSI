import Foundation

/// The resolved outcome of login negotiation for one session/connection
/// (RFC 7143 §13). Field defaults are the RFC defaults — a key never
/// mentioned during login lands on these.
public struct OperationalParameters: Sendable, Equatable {
    // Connection-scope
    public var headerDigest = false
    public var dataDigest = false
    /// What the *target* is willing to receive per Data-Out/command PDU —
    /// caps our outgoing data segments.
    public var targetMaxRecvDataSegmentLength: UInt32 = 8192
    /// What we declared we can receive — caps their Data-In segments.
    public var initiatorMaxRecvDataSegmentLength: UInt32 = 262_144

    // Session-scope
    public var maxConnections: UInt32 = 1
    public var initialR2T = true
    public var immediateData = true
    public var maxBurstLength: UInt32 = 262_144
    public var firstBurstLength: UInt32 = 65536
    public var defaultTime2Wait: UInt32 = 2
    public var defaultTime2Retain: UInt32 = 20
    public var maxOutstandingR2T: UInt32 = 1
    public var dataPDUInOrder = true
    public var dataSequenceInOrder = true
    public var errorRecoveryLevel: UInt32 = 0

    // Declarative session facts
    public var targetPortalGroupTag: UInt16?
    public var targetAlias: String?

    public init() {}

    /// May we send unsolicited data with/immediately after the command?
    public var canSendImmediateData: Bool { immediateData }
    public var canSendUnsolicitedDataOut: Bool { !initialR2T }

    /// RFC 7143 §13.19: FirstBurstLength MUST NOT exceed MaxBurstLength.
    public func validate() throws {
        guard firstBurstLength <= maxBurstLength else {
            throw NegotiationError.invalidResult("FirstBurstLength > MaxBurstLength")
        }
        guard (512 ... 0xFF_FFFF).contains(targetMaxRecvDataSegmentLength) else {
            throw NegotiationError.invalidResult("target MaxRecvDataSegmentLength out of range")
        }
    }
}

public enum NegotiationError: Error, Equatable, Sendable {
    case keyRejected(String)
    case invalidValue(key: String, value: String)
    case invalidResult(String)
    case protocolViolation(String)
    case authenticationFailed(String)
    case loginFailed(statusClass: UInt8, statusDetail: UInt8)
}
