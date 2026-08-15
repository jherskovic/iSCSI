//
//  LastPortal.swift
//  Remembering the address someone last typed.
//
//  Almost nobody has one LUN on one NAS. Adding the second means typing the same
//  address again, and an iSCSI portal address is the kind of thing people look
//  up rather than remember.
//
//  UserDefaults rather than the daemon's TargetStore: this is a UI convenience
//  belonging to whoever is sitting at the machine, not configuration the daemon
//  needs, and it must not end up in a file that boot-time code reads.
//

import Foundation

enum LastPortal {
    private static let hostKey = "me.herko.iSCSIInitiator.lastPortalHost"
    private static let portKey = "me.herko.iSCSIInitiator.lastPortalPort"

    static var host: String? {
        UserDefaults.standard.string(forKey: hostKey)
    }

    static var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        // `integer(forKey:)` returns 0 for "never set", which is not a port.
        return stored > 0 && stored <= Int(UInt16.max) ? UInt16(stored) : 3260
    }

    static func remember(host: String, port: UInt16) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: hostKey)
        UserDefaults.standard.set(Int(port), forKey: portKey)
    }

    /// The value a *new* target's address field should start with. Empty when
    /// nothing has been added yet, so the field shows its placeholder rather
    /// than a confident-looking blank.
    static var suggestedHost: String { host ?? "" }
}
