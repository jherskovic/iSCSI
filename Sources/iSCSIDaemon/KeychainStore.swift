#if canImport(Security)
import Foundation
import Security

/// CHAP secrets, held by the daemon so they never transit XPC on the way out.
///
/// Keyed by **target id**, not by CHAP username. Two targets can legitimately
/// use the same username with different secrets, and keying by username meant
/// the second one silently overwrote the first.
///
/// Secrets travel *into* this store and never back out over XPC. The daemon
/// reads them itself when it logs in; there is no `getSecret` on the protocol,
/// so a client that is later compromised cannot read back what an earlier
/// trusted one saved.
public enum KeychainStore {
    private static let service = "me.herko.iSCSIInitiator.chap"

    public enum StoreFailure: Error, LocalizedError {
        case osStatus(OSStatus)
        /// Written without error, but not readable afterwards. Worth its own
        /// case because it is the shape the boot-time problem takes.
        case notPersisted
        /// The System keychain would not open. Distinct from a refused write:
        /// there is nowhere to write *to*, and no amount of retrying or
        /// re-entering the secret will change it.
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

    /// Opened per call rather than cached: `SecKeychain` is a CF type and not
    /// `Sendable`, opening it is cheap, and secrets are touched only when one is
    /// saved or a login resolves one.
    ///
    /// `SecKeychainOpen` is deprecated in favour of the data-protection
    /// keychain, which is precisely what a system-domain daemon cannot reach.
    /// There is no non-deprecated way to name a file keychain, so the
    /// deprecation is acknowledged rather than avoidable.
    ///
    /// The build therefore carries one deprecation warning, on the
    /// `SecKeychainOpen` line below, and it is meant to stay: it marks the one
    /// place this constraint lives. Do not silence it by annotating the callers
    /// — that spreads a false "deprecated" onto this type's whole public API —
    /// and do not silence it by going back to the data-protection keychain,
    /// which is what did not work.
    static func systemKeychain() -> SecKeychain? {
        var keychain: SecKeychain?
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        guard status == errSecSuccess else {
            DaemonLog.auth("cannot open the System keychain: \(describe(status))")
            return nil
        }
        return keychain
    }

    /// The three operations this store needs from a keychain.
    ///
    /// A seam, not an abstraction for its own sake. Everything below it — which
    /// keychain, which query keys — is exactly what was wrong for every release
    /// up to 0.4.3, and it was wrong in a way no test could see: the calls
    /// returned, the logic was right, and the secret went somewhere the daemon
    /// could not read. With the Security calls behind this, the logic can be
    /// tested against a fake and the query construction can be asserted
    /// directly, which is the assertion that would have caught it.
    public protocol Backend: Sendable {
        func store(account: String, service: String, label: String, secret: Data) -> OSStatus
        func fetch(account: String, service: String) -> (status: OSStatus, secret: Data?)
        func remove(account: String, service: String) -> OSStatus
    }

    /// RESOLVED 2026-08-17, and the answer is worse than the question was.
    ///
    /// This used to pass `kSecUseDataProtectionKeychain: true`, reasoning that
    /// otherwise a root daemon's item lands in root's login keychain, which is
    /// locked at boot. The open question was whether a daemon could read such an
    /// item back *before any user logs in*.
    ///
    /// It cannot read or write one at all, at any time. The data-protection
    /// keychain is served by `secd`, which is a **per-user agent**. `iscsid` is
    /// a LaunchDaemon in the system domain, where `com.apple.securityd.xpc` is
    /// not in the bootstrap namespace, so every call failed:
    ///
    ///     Failed to talk to secd after 4 attempts.
    ///     error:[-25291] … com.apple.securityd.xpc … Connection invalid —
    ///       Connection init failed at lookup with error 3 - No such process
    ///     keychain write initiator for …: SecItemDelete -25291, SecItemAdd -25291
    ///
    /// `-25291` is `errSecNotAvailable`. Every CHAP secret ever entered was
    /// silently discarded — `setCHAPSecret` is `try?` over `store`, so the user
    /// saw only "saved but could not be read back", which is what the read-back
    /// check reports when there is nothing to read.
    ///
    /// The System keychain is what a system-domain daemon is meant to use: it is
    /// served by the system `securityd`, is unlocked at boot from
    /// `/var/db/SystemKey`, and needs no user session. Verified as root by
    /// writing in one process and reading the value back in a later one.
    ///
    /// Nothing was migrated because nothing was ever stored.
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

        /// Searching and adding name the keychain differently: a search takes a
        /// list, an add takes the one to write into. Passing the wrong key is
        /// not an error — it silently addresses the default keychain, which for
        /// a root daemon is root's login keychain, locked at boot.
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

    /// Throwing variant. `SecItemAdd`'s status used to be discarded entirely, so
    /// a keychain that refused the write was indistinguishable from one that
    /// accepted it — and the first symptom was a login failing against a target
    /// whose credentials the user had definitely entered.
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
            // Distinguishes the two ways this returns nil, which the caller
            // cannot: "no such item" is an ordinary answer for a target with no
            // CHAP configured, and anything else is a keychain refusing us.
            // Both arrive at the call site as a bare nil.
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
