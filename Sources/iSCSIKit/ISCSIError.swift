//
//  ISCSIError.swift
//  One error domain for everything that crosses XPC.
//
//  Swift enums bridge to NSError with the case *index* as code and no user
//  info — useless across the boundary. The GUI needs a sentence, a recovery
//  suggestion, and raw detail; this mapping is where they survive.
//

import Foundation

public enum ISCSIError {
    public static let domain = "me.herko.iSCSIInitiator.ErrorDomain"

    /// Stable across versions: they cross a process boundary between an app and
    /// a daemon that can be different builds mid-update, and they end up in bug
    /// reports. Append, never renumber.
    public enum Code: Int, Sendable, CaseIterable {
        case unknown = 0

        // Reaching the target at all.
        case cannotConnect = 10
        case connectionLost = 11
        case targetRequestedLogout = 12
        case redirected = 13

        // Getting logged in.
        case authenticationFailed = 20
        case loginRejected = 21
        case negotiationFailed = 22

        // Using the session.
        case sessionNotActive = 30
        case sessionLoggedOut = 31
        case recoveryExhausted = 32
        case taskTimedOut = 33
        case taskRejected = 34

        // The device behind it.
        case deviceNotReady = 40
        case misalignedIO = 41
        case outOfRange = 42
        case checkCondition = 43
        /// An NVMe controller answered with a non-success status; the SCT/SC
        /// pair rides in `senseKey`.
        case nvmeStatus = 44

        case protocolViolation = 50
        case daemonInternal = 60
    }

    /// User-info key carrying the device's own status bytes: SCSI sense as
    /// hex, or an NVMe "sct/sc/opcode" line. The one piece of evidence that
    /// makes a device error diagnosable, and it is otherwise lost the moment
    /// the error crosses the boundary.
    public static let senseKey = "me.herko.iSCSIInitiator.SenseData"
    /// User-info key carrying the original Swift error's description, for the
    /// cases where the mapping below is not specific enough to be useful.
    public static let underlyingKey = "me.herko.iSCSIInitiator.Underlying"

    /// Convert anything the engine throws into an NSError the other side of XPC
    /// can act on.
    public static func nsError(from error: Error, context: String? = nil) -> NSError {
        let (code, description, recovery, sense) = classify(error)

        var info: [String: Any] = [
            NSLocalizedDescriptionKey: context.map { "\($0): \(description)" } ?? description,
            underlyingKey: String(describing: error),
        ]
        if let recovery { info[NSLocalizedRecoverySuggestionErrorKey] = recovery }
        if let sense { info[senseKey] = sense }

        return NSError(domain: domain, code: code.rawValue, userInfo: info)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func classify(
        _ error: Error
    ) -> (Code, String, String?, String?) {
        switch error {
        case let e as ConnectionError:
            switch e {
            case .closed:
                return (.connectionLost, "The connection to the target closed.",
                        "Check that the storage device is powered on and reachable.", nil)
            case .connectionLost(let why):
                return (.connectionLost, "The connection to the target was lost: \(why).",
                        "Check the network path to the storage device.", nil)
            case .protocolError(let why):
                return (.protocolViolation, "The target sent something unexpected: \(why).",
                        "This usually indicates a bug — on either side. "
                        + "The details are worth reporting.", nil)
            case .loginFailed(let negotiation):
                return classify(negotiation)
            case .redirected(let address, let permanent):
                return (.redirected,
                        "The target redirected to \(address)"
                        + (permanent ? " permanently." : " temporarily."),
                        "Use \(address) as the portal address.", nil)
            case .taskRejected(let reason):
                return (.taskRejected, "The target rejected a command (\(reason)).",
                        nil, nil)
            case .targetRequestedLogout:
                return (.targetRequestedLogout, "The target asked us to log out.",
                        "The storage device may be rebooting or rebalancing.", nil)
            }

        case let e as NegotiationError:
            switch e {
            case .authenticationFailed(let why):
                return (.authenticationFailed, "The target rejected our credentials: \(why).",
                        "Check the CHAP username and secret for this target. "
                        + "Many targets also require the secret to be at least 12 characters.",
                        nil)
            case .loginFailed(let statusClass, let statusDetail):
                // RFC 7143 "authentication failure" — the most common real
                // failure, worth naming over two hex bytes.
                if statusClass == 0x02 && statusDetail == 0x01 {
                    return (.authenticationFailed,
                            "The target refused the login as unauthorised.",
                            "Check the CHAP credentials, and whether this initiator's "
                            + "IQN is allowed to use this target.", nil)
                }
                return (.loginRejected,
                        String(format: "The target refused the login "
                               + "(status 0x%02X/0x%02X).", statusClass, statusDetail),
                        "Check that the target name is correct and that this "
                        + "initiator is permitted to use it.", nil)
            case .keyRejected(let key):
                return (.negotiationFailed, "The target rejected the parameter “\(key)”.",
                        nil, nil)
            case .invalidValue(let key, let value):
                return (.negotiationFailed,
                        "The target answered “\(key)” with a value we cannot use: \(value).",
                        nil, nil)
            case .invalidResult(let why), .protocolViolation(let why):
                return (.negotiationFailed, "Login negotiation failed: \(why).", nil, nil)
            }

        case let e as SessionError:
            switch e {
            case .notActive:
                return (.sessionNotActive, "The session is not active.",
                        "Reconnect to the target.", nil)
            case .loggedOut:
                return (.sessionLoggedOut, "The session has been logged out.",
                        "Reconnect to the target.", nil)
            case .recoveryExhausted(let last):
                return (.recoveryExhausted,
                        "The connection dropped and could not be re-established: \(last).",
                        "Check the network path, then reconnect.", nil)
            case .taskTimedOut:
                return (.taskTimedOut, "The target accepted a command and never answered it.",
                        "The session was abandoned rather than waiting forever, which "
                        + "keeps the filesystem from wedging. Reconnect to try again.", nil)
            case .taskFailed(let result):
                return (.checkCondition, "A SCSI command failed: \(result).", nil, nil)
            }

        case let e as BlockDeviceError:
            switch e {
            case .notReady:
                return (.deviceNotReady, "The storage device reports it is not ready.",
                        "It may still be starting up. Try again in a moment.", nil)
            case .misaligned(let offset, let length, let blockSize):
                return (.misalignedIO,
                        "An unaligned read or write was attempted "
                        + "(offset \(offset), length \(length), block size \(blockSize)).",
                        "This is a bug in the initiator; please report it.", nil)
            case .outOfRange(let lba, let blocks, let capacity):
                return (.outOfRange,
                        "A read or write ran past the end of the device "
                        + "(block \(lba)+\(blocks) of \(capacity)).",
                        "This is a bug in the initiator; please report it.", nil)
            case .scsiError(let status, let sense):
                return (.checkCondition,
                        String(format: "The storage device reported an error "
                               + "(SCSI status 0x%02X).", status),
                        "The sense data attached to this error identifies the cause.",
                        sense.map(hex))
            case .nvmeStatus(let sct, let sc, let opcode):
                let status = String(format: "sct 0x%02x sc 0x%02x opcode 0x%02x", sct, sc, opcode)
                switch (opcode, sct, sc) {
                case (0x7F, 0x01, 0x84):   // Fabrics Connect: Invalid Host
                    return (.nvmeStatus,
                            "The subsystem refused this Mac's host NQN.",
                            "Add this Mac's host NQN (shown when editing the target) to the "
                            + "subsystem's allowed hosts on the NAS.", status)
                case (0x7F, 0x01, 0x91):   // Fabrics Connect: Authentication Required
                    return (.nvmeStatus,
                            "The subsystem requires in-band authentication (DH-HMAC-CHAP), "
                            + "which this version does not support.",
                            "Turn off host authentication for this subsystem on the NAS.", status)
                case (0x7F, 0x01, 0x82):   // Fabrics Connect: Invalid Parameters
                    return (.nvmeStatus,
                            "The subsystem rejected the connection parameters.",
                            "Check that the subsystem NQN is correct and that the NAS is "
                            + "serving it on this address and port.", status)
                case (_, 0x00, 0x0B):      // Invalid Namespace or Format
                    return (.nvmeStatus,
                            "The subsystem has no namespace with that ID.",
                            "Namespace IDs start at 1. Use Discover, or check the namespace "
                            + "list for this subsystem on the NAS.", status)
                case (_, 0x00, 0x82):      // Namespace Not Ready
                    return (.deviceNotReady, "The namespace is not ready.",
                            "It may still be starting up. Try again in a moment.", status)
                default:
                    return (.nvmeStatus,
                            String(format: "The NVMe controller returned status 0x%02X/0x%02X "
                                   + "for opcode 0x%02X.", sct, sc, opcode),
                            "The status bytes attached to this error identify the cause.", status)
                }
            case .invalidGeometry(let blockSize, let blockCount, let reason):
                // Points at the target: nothing user- or initiator-side to fix.
                return (.deviceNotReady,
                        "The target described a device that cannot exist: \(reason) "
                        + "(block size \(blockSize), \(blockCount) blocks).",
                        "The target is misreporting its capacity, or something "
                        + "between this Mac and it is altering the reply. Check the "
                        + "target's LUN configuration.", nil)
            }

        case let e as TransportError:
            switch e {
            case .closed:
                return (.connectionLost, "The network connection closed.", nil, nil)
            case .connectFailed(let why):
                return (.cannotConnect, "Could not reach the target: \(why).",
                        "Check the address and port, and that the storage device "
                        + "is powered on.", nil)
            }

        default:
            return (.daemonInternal, error.localizedDescription, nil, nil)
        }
    }

    private static func hex(_ sense: SenseData) -> String {
        // Sense bytes ride in the error so a bug report carries them.
        sense.description
    }
}
