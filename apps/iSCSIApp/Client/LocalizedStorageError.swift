import Foundation
import iSCSIKit

/// Translate the stable error code at the GUI boundary. The root daemon and
/// protocol engines retain their original diagnostics, including device status
/// bytes and target replies; no language preference is assumed by a service.
enum LocalizedStorageError {
    static func details(_ error: NSError) -> (message: String, suggestion: String?) {
        guard error.domain == ISCSIError.domain,
              let code = ISCSIError.Code(rawValue: error.code),
              Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        else { return (error.localizedDescription, error.localizedRecoverySuggestion) }

        let summary: String
        let recovery: String?
        switch code {
        case .cannotConnect:
            summary = String(localized: "Could not connect to the storage target.")
            recovery = String(localized: "Check the address, port and network interface, and confirm the storage device is online.")
        case .connectionLost, .recoveryExhausted:
            summary = String(localized: "The connection to the storage target was interrupted.")
            recovery = String(localized: "Check the network and storage device, then reconnect.")
        case .authenticationFailed, .loginRejected:
            summary = String(localized: "The storage target refused this Mac's login.")
            recovery = String(localized: "Check the CHAP username and secret, the initiator IQN or host NQN, and the target's access rules. The original response below identifies the specific refusal.")
        case .targetRequestedLogout:
            summary = String(localized: "The storage target ended the connection.")
            recovery = String(localized: "The device may be restarting or rebalancing. Try connecting again shortly.")
        case .sessionNotActive, .sessionLoggedOut:
            summary = String(localized: "This connection is no longer active.")
            recovery = String(localized: "Reconnect to the storage target.")
        case .taskTimedOut:
            summary = String(localized: "The storage target did not complete a request in time.")
            recovery = String(localized: "Check the network and storage device, then reconnect.")
        case .deviceNotReady:
            summary = String(localized: "The storage device is not ready.")
            recovery = String(localized: "It may still be starting up. Try again shortly.")
        case .negotiationFailed, .protocolViolation:
            summary = String(localized: "The storage target returned an incompatible response.")
            recovery = String(localized: "Check the target's protocol settings. Keep the original diagnostic below when reporting this issue.")
        case .misalignedIO, .outOfRange:
            summary = String(localized: "A disk request did not match the device's block layout.")
            recovery = String(localized: "Keep the original diagnostic below and report this issue.")
        case .checkCondition, .nvmeStatus, .taskRejected:
            summary = String(localized: "The storage device rejected a request.")
            recovery = String(localized: "The original diagnostic below contains the device's status and any suggested remedy.")
        case .redirected:
            summary = String(localized: "The storage target requested a different connection address.")
            recovery = String(localized: "Use the address in the original response below.")
        case .unknown, .daemonInternal:
            summary = String(localized: "The storage operation could not be completed.")
            recovery = nil
        }
        // Keep exact server/OS diagnostics. They can contain addresses, status
        // codes and identity evidence that a generic translated summary cannot.
        let original = [error.localizedDescription, error.localizedRecoverySuggestion]
            .compactMap { $0 }.joined(separator: "\n")
        return (summary, [recovery, String(localized: "Original diagnostic:"), original]
            .compactMap { $0 }.joined(separator: "\n\n"))
    }
}
