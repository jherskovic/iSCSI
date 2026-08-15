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

        public var errorDescription: String? {
            switch self {
            case .osStatus(let status):
                let text = SecCopyErrorMessageString(status, nil) as String?
                return "The keychain refused the request: \(text ?? "OSStatus \(status)")"
            case .notPersisted:
                return "The secret was saved but could not be read back."
            }
        }
    }

    /// UNRESOLVED, and deliberately marked as such: whether a root LaunchDaemon
    /// can read this back *before any user logs in*.
    ///
    /// `kSecUseDataProtectionKeychain` is required, or a root daemon's item goes
    /// to root's login keychain, which is locked at boot — the failure would
    /// only ever appear as auto-attach silently not working after a restart.
    /// `AfterFirstUnlockThisDeviceOnly` is the most permissive accessibility that
    /// is still device-bound and excluded from backups, but "after first unlock"
    /// is a statement about a *user* session, and a daemon at boot has none.
    ///
    /// This is R3 in the plan and needs a reboot experiment before any
    /// auto-attach feature can rely on it. Until then nothing depends on
    /// reading a secret at boot: the app is running whenever a login happens.
    private static func baseQuery(_ targetID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public static func setCHAPSecret(_ secret: String, for targetID: String) {
        try? store(secret, for: targetID)
    }

    /// Throwing variant. `SecItemAdd`'s status used to be discarded entirely, so
    /// a keychain that refused the write was indistinguishable from one that
    /// accepted it — and the first symptom was a login failing against a target
    /// whose credentials the user had definitely entered.
    public static func store(_ secret: String, for targetID: String) throws {
        var query = baseQuery(targetID)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "iSCSI Initiator — CHAP secret"

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreFailure.osStatus(status) }
    }

    public static func chapSecret(for targetID: String) -> String? {
        var query = baseQuery(targetID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteCHAPSecret(for targetID: String) {
        SecItemDelete(baseQuery(targetID) as CFDictionary)
    }
}
#else
public enum KeychainStore {
    public enum StoreFailure: Error { case osStatus(Int32), notPersisted }
    public static func setCHAPSecret(_ secret: String, for targetID: String) {}
    public static func store(_ secret: String, for targetID: String) throws {}
    public static func chapSecret(for targetID: String) -> String? { nil }
    public static func deleteCHAPSecret(for targetID: String) {}
}
#endif
