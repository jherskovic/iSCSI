#if canImport(Security)
import Foundation
import Security

/// CHAP secrets, held by the daemon.
///
/// Keyed by **target id**, not CHAP username: two targets can share a username
/// with different secrets.
///
/// Secrets travel *into* this store and never back out over XPC — there is no
/// `getSecret` on the protocol, so a compromised client cannot read back what
/// an earlier trusted one saved.
public enum KeychainStore {
    private static let service = "me.herko.iSCSIInitiator.chap"

    public enum StoreFailure: Error, LocalizedError {
        case osStatus(OSStatus)
        /// Written without error, but not readable afterwards.
        case notPersisted
        /// The System keychain would not open: there is nowhere to write *to*,
        /// and retrying or re-entering the secret will not change that.
        case noSystemKeychain

        public var errorDescription: String? {
            switch self {
            case .osStatus(let status):
                let text = SecCopyErrorMessageString(status, nil) as String?
                return "The keychain refused the request: \(text ?? "OSStatus \(status)")"
            case .notPersisted:
                return "The secret was saved but could not be read back."
            case .noSystemKeychain:
                return "The System keychain could not be opened, so there is "
                     + "nowhere to save the secret."
            }
        }
    }

    /// Opened per call: `SecKeychain` is not `Sendable` and opening is cheap.
    ///
    /// `SecKeychainOpen` is deprecated in favour of the data-protection
    /// keychain — precisely what a system-domain daemon cannot reach (see
    /// `SystemKeychain`) — and there is no non-deprecated way to name a file
    /// keychain. The one deprecation warning below is deliberate; do not
    /// silence it, and do not go back to the data-protection keychain.
    static func systemKeychain() -> SecKeychain? {
        var keychain: SecKeychain?
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        guard status == errSecSuccess else {
            DaemonLog.auth("cannot open the System keychain: \(describe(status))")
            return nil
        }
        return keychain
    }

    /// The three operations this store needs from a keychain. A seam so the
    /// logic can run against a fake and the query construction — the part that
    /// once sent secrets somewhere the daemon could not read — can be asserted
    /// directly.
    public protocol Backend: Sendable {
        func store(account: String, service: String, label: String, secret: Data) -> OSStatus
        func fetch(account: String, service: String) -> (status: OSStatus, secret: Data?)
        func remove(account: String, service: String) -> OSStatus
    }

    /// The System keychain, and it must be: the data-protection keychain
    /// (`kSecUseDataProtectionKeychain`) is served by `secd`, a **per-user
    /// agent**, and `iscsid` is a system-domain LaunchDaemon with no
    /// `com.apple.securityd.xpc` in its bootstrap namespace — every call
    /// returns `-25291` (`errSecNotAvailable`) and no secret is ever stored.
    /// The System keychain is served by the system `securityd`, unlocked at
    /// boot from `/var/db/SystemKey`, and needs no user session.
    public struct SystemKeychain: Backend {
        public init() {}

        /// The query every operation starts from, exposed so its *shape* can be
        /// asserted. `kSecUseDataProtectionKeychain` must never appear here.
        public static func baseQuery(account: String, service: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
        }

        /// Searching and adding name the keychain differently (a search takes
        /// a list, an add takes one). The wrong key is not an error — it
        /// silently addresses the default keychain, which for a root daemon is
        /// root's login keychain, locked at boot.
        public static func writeQuery(account: String, service: String, label: String,
                                      keychain: SecKeychain?) -> [String: Any] {
            var q = baseQuery(account: account, service: service)
            if let keychain { q[kSecUseKeychain as String] = keychain }
            q[kSecAttrLabel as String] = label
            return q
        }

        public static func searchQuery(account: String, service: String,
                                       keychain: SecKeychain?) -> [String: Any] {
            var q = baseQuery(account: account, service: service)
            if let keychain { q[kSecMatchSearchList as String] = [keychain] }
            return q
        }

        public func store(account: String, service: String, label: String,
                          secret: Data) -> OSStatus {
            guard let keychain = KeychainStore.systemKeychain() else { return errSecNotAvailable }
            let deleted = SecItemDelete(
                Self.searchQuery(account: account, service: service, keychain: keychain) as CFDictionary)
            var q = Self.writeQuery(account: account, service: service,
                                    label: label, keychain: keychain)
            q[kSecValueData as String] = secret
            let status = SecItemAdd(q as CFDictionary, nil)
            DaemonLog.auth("keychain write \(account): "
                           + "SecItemDelete \(KeychainStore.describe(deleted)), "
                           + "SecItemAdd \(KeychainStore.describe(status))")
            return status
        }

        public func fetch(account: String, service: String) -> (status: OSStatus, secret: Data?) {
            guard let keychain = KeychainStore.systemKeychain() else { return (errSecNotAvailable, nil) }
            var q = Self.searchQuery(account: account, service: service, keychain: keychain)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            return (status, item as? Data)
        }

        public func remove(account: String, service: String) -> OSStatus {
            guard let keychain = KeychainStore.systemKeychain() else { return errSecNotAvailable }
            return SecItemDelete(
                Self.searchQuery(account: account, service: service, keychain: keychain) as CFDictionary)
        }
    }

    /// Swapped by tests, never by the daemon, which is why an unguarded static
    /// is honest here rather than lazy.
    nonisolated(unsafe) public static var backend: Backend = SystemKeychain()

    /// Which half of a mutual CHAP pair a secret is.
    ///
    /// Separate accounts rather than a second service, so one target's two
    /// secrets stay adjacent and `removeAll` can still find them by service. The
    /// initiator account is the bare id, unprefixed, so items written before
    /// mutual CHAP existed keep resolving.
    public enum Kind: Sendable {
        /// What we prove to the target.
        case initiator
        /// What the target must prove to us.
        case mutual

        public func account(for targetID: String) -> String {
            switch self {
            case .initiator: return targetID
            case .mutual:    return "mutual:" + targetID
            }
        }
    }

    public static func setCHAPSecret(_ secret: String, for targetID: String,
                                     kind: Kind = .initiator) {
        try? store(secret, for: targetID, kind: kind)
    }

    /// Throwing variant: a discarded `SecItemAdd` status makes a refused write
    /// indistinguishable from an accepted one.
    public static func store(_ secret: String, for targetID: String,
                             kind: Kind = .initiator) throws {
        let status = backend.store(account: kind.account(for: targetID),
                                   service: service,
                                   label: kind == .mutual
                                       ? "iSCSI Initiator — mutual CHAP secret"
                                       : "iSCSI Initiator — CHAP secret",
                                   secret: Data(secret.utf8))
        guard status != errSecNotAvailable else { throw StoreFailure.noSystemKeychain }
        guard status == errSecSuccess else { throw StoreFailure.osStatus(status) }
    }

    /// An OSStatus with its name, because `-34018` is unreadable and
    /// `errSecMissingEntitlement` is a diagnosis.
    static func describe(_ status: OSStatus) -> String {
        guard status != errSecSuccess else { return "ok" }
        let text = SecCopyErrorMessageString(status, nil) as String?
        return "\(status) (\(text ?? "no description"))"
    }

    public static func chapSecret(for targetID: String, kind: Kind = .initiator) -> String? {
        let (status, data) = backend.fetch(account: kind.account(for: targetID), service: service)
        guard status == errSecSuccess, let data else {
            // Logged because the caller sees only nil: "no such item" is
            // ordinary, anything else is the keychain refusing us.
            DaemonLog.auth("keychain read \(kind) for \(targetID): \(describe(status))")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteCHAPSecret(for targetID: String, kind: Kind = .initiator) {
        let status = backend.remove(account: kind.account(for: targetID), service: service)
        if status != errSecSuccess && status != errSecItemNotFound {
            DaemonLog.auth("keychain delete \(kind) for \(targetID): \(describe(status))")
        }
    }

    /// Both halves, for deleting a target outright. Neither absence is an error.
    public static func deleteAllSecrets(for targetID: String) {
        deleteCHAPSecret(for: targetID, kind: .initiator)
        deleteCHAPSecret(for: targetID, kind: .mutual)
    }
}
#else
public enum KeychainStore {
    public enum StoreFailure: Error { case osStatus(Int32), notPersisted }
    public enum Kind: Sendable { case initiator, mutual }
    public static func setCHAPSecret(_ secret: String, for targetID: String,
                                     kind: Kind = .initiator) {}
    public static func store(_ secret: String, for targetID: String,
                             kind: Kind = .initiator) throws {}
    public static func chapSecret(for targetID: String, kind: Kind = .initiator) -> String? { nil }
    public static func deleteCHAPSecret(for targetID: String, kind: Kind = .initiator) {}
    public static func deleteAllSecrets(for targetID: String) {}
}
#endif
