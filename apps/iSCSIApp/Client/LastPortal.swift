//
//  LastPortal.swift
//  Remembering the address someone last typed.
//
//  Almost nobody has one LUN on one NAS. Adding the second means typing the same
//  address again, and an iSCSI portal address is the kind of thing people look
//  up rather than remember.
//
//  Remembered per protocol. iSCSI and NVMe/TCP listen on different ports, often
//  on the same box, so one shared slot handed iSCSI the 4420 an NVMe discovery
//  had left behind. Ports never cross protocols. A host does when the other
//  protocol has none of its own yet: an NVMe/TCP subsystem is most likely on
//  the NAS that already serves the iSCSI targets.
//

import Foundation

enum LastPortal {
    /// Written on every remember, whatever the protocol: the cross-protocol
    /// fallback for a host. Its key predates per-protocol memory, so an
    /// address remembered by an older version still comes back.
    private static let anyHostKey = "me.herko.iSCSIInitiator.lastPortalHost"
    // The old shared port key, "…lastPortalPort", is deliberately not read: it
    // may hold either protocol's port, and that ambiguity was the bug.

    private static func hostKey(nvme: Bool) -> String {
        "me.herko.iSCSIInitiator.lastPortalHost." + (nvme ? "nvme" : "iscsi")
    }

    private static func portKey(nvme: Bool) -> String {
        "me.herko.iSCSIInitiator.lastPortalPort." + (nvme ? "nvme" : "iscsi")
    }

    static func defaultPort(nvme: Bool) -> UInt16 { nvme ? 4420 : 3260 }

    static func host(nvme: Bool, in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: hostKey(nvme: nvme)) ?? defaults.string(forKey: anyHostKey)
    }

    static func port(nvme: Bool, in defaults: UserDefaults = .standard) -> UInt16 {
        let stored = defaults.integer(forKey: portKey(nvme: nvme))
        // `integer(forKey:)` returns 0 for "never set", which is not a port.
        return stored > 0 && stored <= Int(UInt16.max) ? UInt16(stored) : defaultPort(nvme: nvme)
    }

    static func remember(host: String, port: UInt16, nvme: Bool,
                         in defaults: UserDefaults = .standard) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: hostKey(nvme: nvme))
        defaults.set(trimmed, forKey: anyHostKey)
        defaults.set(Int(port), forKey: portKey(nvme: nvme))
    }

    /// The value a *new* target's address field should start with. Empty when
    /// nothing has been added yet, so the field shows its placeholder rather
    /// than a confident-looking blank.
    static func suggestedHost(nvme: Bool, in defaults: UserDefaults = .standard) -> String {
        host(nvme: nvme, in: defaults) ?? ""
    }

    /// Fields that still hold what was suggested for `old` move to what is
    /// suggested for `new`; anything else was typed, and a value the user
    /// typed is theirs. A port that is `old`'s well-known default also moves,
    /// so 3260 typed over a remembered 3261 still becomes 4420 under NVMe/TCP.
    static func switchProtocol(host: inout String, port: inout String,
                               from old: Bool, to new: Bool,
                               in defaults: UserDefaults = .standard) {
        guard old != new else { return }
        if host == suggestedHost(nvme: old, in: defaults) {
            host = suggestedHost(nvme: new, in: defaults)
        }
        if port == String(self.port(nvme: old, in: defaults))
            || port == String(defaultPort(nvme: old)) {
            port = String(self.port(nvme: new, in: defaults))
        }
    }
}
