#if canImport(Security)
import Foundation
import Security

/// Minimal System keychain access for CHAP secrets, keyed by initiator/target
/// user name. Used by the daemon so secrets never transit XPC in the clear.
public enum KeychainStore {
    private static let service = "me.herko.iSCSIInitiator.chap"

    public static func setCHAPSecret(_ secret: String, for user: String) {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func chapSecret(for user: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#else
public enum KeychainStore {
    public static func setCHAPSecret(_ secret: String, for user: String) {}
    public static func chapSecret(for user: String) -> String? { nil }
}
#endif
