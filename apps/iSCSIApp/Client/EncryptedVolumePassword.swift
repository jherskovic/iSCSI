import Foundation
import os
import Security

private let unlockLog = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "attach")

/// The password macOS saved for an encrypted APFS volume, if it saved one.
///
/// macOS's unlock prompt writes it to the login keychain when "Remember this
/// password in my keychain" is ticked: a generic password whose account and
/// service are both the volume's UUID, of kind "Encrypted Volume Password"
/// (the `ssd-vms` item, seen 2026-11-09). Finder and Disk Utility save the
/// same item.
///
/// macOS does not use it for a disk this app attaches. `hdiutil attach` fails
/// a disk whose only volumes are locked ("no mountable file systems") without
/// consulting it, and nothing unlocks the volume after the `-nomount`
/// re-attach either (both measured on macOS 26.7.2, 2026-11-09). So the app
/// reads it itself.
///
/// Another process created the item, so the first read shows macOS's "wants
/// to use your confidential information" prompt; Always Allow makes every
/// later attach silent. A missing item, a denial or anything else is nil:
/// unlocking is a convenience, never a reason for an attach to fail.
enum EncryptedVolumePassword {
    static func saved(forVolumeUUID uuid: String) -> Data? {
        // The file-based login keychain, where the prompt saves it: no
        // kSecUseDataProtectionKeychain.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: uuid,
            kSecAttrService as String: uuid,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return nil }
            return data
        case errSecItemNotFound:
            return nil
        default:
            // errSecAuthFailed / errSecUserCanceled: Deny in the access prompt.
            unlockLog.notice("no saved password for volume \(uuid, privacy: .public): keychain status \(status)")
            return nil
        }
    }
}
