//
//  ISCSIError.swift
//  One error domain for everything that crosses XPC.
//
//  Every `catch` in the daemon's XPC surface used to do `error as NSError`.
//  Swift enums bridge to NSError as domain "iSCSIKit.SessionError" with the case
//  *index* as the code and no user info, so the client received something like
//  "The operation couldn't be completed. (iSCSIKit.SessionError error 2.)" —
//  which cannot distinguish a wrong CHAP secret from a NAS that is switched off,
//  and cannot be acted on by a UI or by a person reading a bug report.
//
//  The GUI needs three things from a failure and none of them survive that
//  bridging: what went wrong in a sentence, what the user might do about it, and
//  enough raw detail to diagnose it when the answer is neither.
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

        case protocolViolation = 50
        case daemonInternal = 60
    }

    /// User-info key carrying SCSI sense bytes as hex, when there are any.
    /// The one piece of evidence that makes a check condition diagnosable, and
    /// it is otherwise lost the moment the error crosses the boundary.
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
                // 0x02/0x01 is "authentication failure" in RFC 7143 terms, and
                // it is by far the most common real failure — worth naming
                // rather than printing two hex bytes at the user.
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
            case .invalidGeometry(let blockSize, let blockCount, let reason):
                // Points at the target, not at the user, because there is
                // nothing they can change here — and not at the initiator
                // either, because it is the target that is misreporting.
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
        // Sense bytes are what a storage vendor asks for first. Keep them in the
        // error rather than only in the log, so a bug report carries them.
        sense.description
    }
}
