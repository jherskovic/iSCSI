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
    private static func baseQuery(_ targetID: String, _ kind: Kind = .initiator) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.account(for: targetID),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

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

        func account(for targetID: String) -> String {
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
        var query = baseQuery(targetID, kind)
        let deleted = SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = kind == .mutual
            ? "iSCSI Initiator — mutual CHAP secret"
            : "iSCSI Initiator — CHAP secret"

        let status = SecItemAdd(query as CFDictionary, nil)
        // Logged here rather than at the call site because `setCHAPSecret` is
        // `try?` over this function: the status is discarded one frame up, and
        // what the user is shown instead — "saved but could not be read back" —
        // describes a symptom two steps downstream of whatever actually went
        // wrong. This is the only place the real answer exists.
        DaemonLog.auth("keychain write \(kind) for \(targetID): "
                       + "SecItemDelete \(describe(deleted)), SecItemAdd \(describe(status))")
        guard status == errSecSuccess else { throw StoreFailure.osStatus(status) }
    }

    /// An OSStatus with its name, because `-34018` is unreadable and
    /// `errSecMissingEntitlement` is a diagnosis.
    private static func describe(_ status: OSStatus) -> String {
        guard status != errSecSuccess else { return "ok" }
        let text = SecCopyErrorMessageString(status, nil) as String?
        return "\(status) (\(text ?? "no description"))"
    }

    public static func chapSecret(for targetID: String, kind: Kind = .initiator) -> String? {
        var query = baseQuery(targetID, kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            // Distinguishes the two ways this returns nil, which the caller
            // cannot: "no such item" is an ordinary answer for a target with no
            // CHAP configured, and anything else is a keychain that is refusing
            // us. Both arrive at the call site as a bare nil.
            DaemonLog.auth("keychain read \(kind) for \(targetID): \(describe(status))")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func deleteCHAPSecret(for targetID: String, kind: Kind = .initiator) {
        SecItemDelete(baseQuery(targetID, kind) as CFDictionary)
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
