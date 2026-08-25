//
//  ClientAuthorization.swift
//  Who is allowed to talk to iscsid. A root daemon vending block read/write
//  must refuse everyone else, and `NSXPCConnection.setCodeSigningRequirement`
//  is the mechanism: kernel-checked against the peer's actual signature, not
//  spoofable like an audited pid or a client-supplied bundle id.
//

import Foundation
import Security

public enum ClientAuthorization {
    public static let teamIdentifier = "4A27X5PJP3"

    /// The only two legitimate clients: the container app and the FSKit
    /// extension. `iscsictl` is deliberately absent — ad-hoc signed dev
    /// tooling; it works in debug builds only (see `authorize`).
    public static let allowedIdentifiers = [
        "me.herko.iSCSIInitiator",
        "me.herko.iSCSIInitiator.fsext",
    ]

    /// A Developer ID requirement in canonical `codesign -dr -` form. The two
    /// certificate OIDs are load-bearing: without them an *Apple Development*
    /// certificate for the same team — issued freely — would satisfy a bare
    /// team-identifier check.
    public static var requirement: String {
        let identifiers = allowedIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        return """
            anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ \
            and certificate leaf[subject.OU] = "\(teamIdentifier)" \
            and (\(identifiers))
            """
    }

    /// `setCodeSigningRequirement` raises an uncatchable ObjC exception on a
    /// malformed string; validate first so a bad requirement fails *closed*
    /// (every connection refused) rather than fatally.
    public static func isWellFormed(_ requirement: String) -> Bool {
        var parsed: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess
            && parsed != nil
    }

    /// Apply the requirement; false means refuse the connection. Debug builds
    /// skip the check (dev VMs cannot satisfy Developer ID) — gated at compile
    /// time and announced in the log, so a relaxed daemon is never silent.
    public static func authorize(_ connection: NSXPCConnection) -> Bool {
        #if DEBUG
        DaemonLog.error("DEBUG BUILD: accepting an XPC connection WITHOUT a "
                        + "code-signing check. Never ship this binary.")
        return true
        #else
        let requirement = Self.requirement
        guard isWellFormed(requirement) else {
            DaemonLog.error("refusing every connection: the code-signing "
                            + "requirement is malformed: \(requirement)")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        return true
        #endif
    }
}
