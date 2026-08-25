//
//  DaemonLog.swift
//  iscsid's diagnostics: os.Logger, interleaved with fskitd/launchd/
//  DiskArbitration and retrievable via
//  `log show --predicate 'subsystem == "me.herko.iSCSIInitiator"'`.
//  stderr is echoed in parallel — free under launchd, and it is the
//  `swift run iscsid` dev loop.
//

import Foundation
import os

public enum DaemonLog {
    public static let subsystem = "me.herko.iSCSIInitiator"

    private static let sessionLog = Logger(subsystem: subsystem, category: "session")
    #if ISCSI_BACKEND_B
    private static let dextLog = Logger(subsystem: subsystem, category: "dext")
    #endif
    private static let lifecycleLog = Logger(subsystem: subsystem, category: "lifecycle")
    /// Login negotiation, CHAP, and its keychain; its own category so
    /// `--predicate 'category == "auth"'` answers the failing-dialog questions.
    private static let authLog = Logger(subsystem: subsystem, category: "auth")

    /// Everything here is `.public` (os.Logger redacts interpolation by
    /// default, and a log of `<private>` diagnoses nothing). IQNs, hostnames,
    /// and LUN numbers are fine; **CHAP secrets and key material must never
    /// reach these** — there is no redaction to fall back on.
    public static func lifecycle(_ message: String) {
        lifecycleLog.notice("\(message, privacy: .public)")
        echo(message)
    }

    public static func session(_ message: String) {
        sessionLog.notice("\(message, privacy: .public)")
        echo(message)
    }

    #if ISCSI_BACKEND_B
    public static func dextMessage(_ message: String) {
        dextLog.notice("\(message, privacy: .public)")
        echo("iscsid[dext]: \(message)")
    }
    #endif

    /// Authentication diagnostics: **no secret, no CHAP_R, no challenge
    /// bytes** — names and byte counts only (`LoginConfig.trace` has the
    /// contract).
    public static func auth(_ message: String) {
        authLog.notice("\(message, privacy: .public)")
        echo("iscsid: \(message)")
    }

    public static func error(_ message: String) {
        lifecycleLog.error("\(message, privacy: .public)")
        echo(message)
    }

    private static func echo(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
