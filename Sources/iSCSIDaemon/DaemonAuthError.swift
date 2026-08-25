//
//  DaemonAuthError.swift
//  Why the daemon refused to log in — worded so the alert names the actual
//  problem (target never saved, secret never stored) rather than sending the
//  user to re-check a password that is fine.
//

import Foundation

public enum DaemonAuthError: Error, LocalizedError, Equatable {
    /// No configured target matches this portal.
    case notConfigured(host: String, port: UInt16, targetIQN: String, lun: UInt64)
    /// The record names a CHAP user but the keychain has no secret for it.
    case secretMissing(user: String, target: String)
    /// Mutual CHAP is half-configured: a username with no stored secret.
    case mutualSecretMissing(user: String, target: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let host, let port, let iqn, let lun):
            return "No saved target matches \(iqn) (LUN \(lun)) at \(host):\(port)."
        case .secretMissing(let user, let target):
            return "“\(target)” is set to authenticate as “\(user)”, but no CHAP "
                 + "secret is saved for it."
        case .mutualSecretMissing(let user, let target):
            return "“\(target)” is set to verify the target as “\(user)”, but no "
                 + "mutual CHAP secret is saved for it."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            return "Add it in the app first. The daemon only connects to targets "
                 + "you have saved, so that a stored password can never be sent to "
                 + "a machine you did not configure."
        case .secretMissing:
            return "Open the target and enter its CHAP secret. Connecting without "
                 + "one would mean connecting with no authentication at all, which "
                 + "is not what the target is configured for."
        case .mutualSecretMissing:
            return "Open the target and enter the mutual CHAP secret, or clear the "
                 + "mutual CHAP user if the target does not authenticate itself."
        }
    }
}
