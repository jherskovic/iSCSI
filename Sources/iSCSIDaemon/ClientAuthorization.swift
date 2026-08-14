//
//  ClientAuthorization.swift
//  Who is allowed to talk to iscsid.
//
//  Until this existed, `shouldAcceptNewConnection` returned `true`
//  unconditionally. iscsid runs as root and vends `read`/`write` against a
//  block device, so any process on the machine — any user, any sandboxed app,
//  anything a browser dropped in /tmp — could connect and read or overwrite the
//  entire LUN. That is a local privilege escalation and a whole-volume data
//  disclosure in the same call, and it had to be fixed before any build left
//  this machine.
//
//  The fix is `NSXPCConnection.setCodeSigningRequirement(_:)` (macOS 13+), which
//  is checked by the kernel against the peer's *actual* code signature. It is
//  not spoofable by the client, unlike auditing a pid or a bundle identifier the
//  peer hands over — by the time you look up a pid it may belong to somebody
//  else.
//

import Foundation
import Security

public enum ClientAuthorization {
    public static let teamIdentifier = "4A27X5PJP3"

    /// The only two things that legitimately talk to the daemon: the container
    /// app (session and target management) and the FSKit extension (block I/O).
    ///
    /// `iscsictl` is deliberately absent. It is a development tool, built by
    /// `swift build` and ad-hoc signed, and a shipping root daemon should not
    /// accept a binary anyone can produce. It keeps working in debug builds —
    /// see `requirement` below.
    public static let allowedIdentifiers = [
        "me.herko.iSCSIInitiator",
        "me.herko.iSCSIInitiator.fsext",
    ]

    /// A Developer ID requirement, in the canonical form `codesign -dr -` emits.
    ///
    /// The two certificate OIDs are load-bearing and are the reason this is not
    /// just a team-identifier check: `1.2.840.113635.100.6.2.6` marks the
    /// Developer ID intermediate and `1.2.840.113635.100.6.1.13` the Developer
    /// ID Application leaf. Without them, an *Apple Development* certificate
    /// issued to the same team would satisfy the requirement — and those are
    /// issued freely to anyone on the team and are installed on every machine
    /// with Xcode signed in.
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

    /// `setCodeSigningRequirement` does not throw — it raises an Objective-C
    /// exception on a malformed string, which Swift cannot catch and which would
    /// take the daemon down. Validate first so a bad requirement fails *closed*
    /// (every connection refused) rather than fatally.
    public static func isWellFormed(_ requirement: String) -> Bool {
        var parsed: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess
            && parsed != nil
    }

    /// Apply the requirement to an incoming connection. Returns false if the
    /// connection must be refused outright.
    ///
    /// Debug builds skip the check entirely, because the SIP-off development VM
    /// runs Apple-Development-signed bundles and an ad-hoc `iscsictl`, none of
    /// which can satisfy a Developer ID requirement. This is gated at compile
    /// time — a Release build cannot reach it — and it announces itself in the
    /// log every time, so a relaxed daemon is never a silent one.
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
