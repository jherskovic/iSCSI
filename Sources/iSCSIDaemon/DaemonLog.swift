//
//  DaemonLog.swift
//  Where iscsid's diagnostics go once it lives inside a signed app bundle.
//
//  It used to write to stderr and the LaunchDaemon plist redirected that to
//  /var/log/iscsid.err. That stops being an option when the plist ships inside
//  Contents/Library/LaunchDaemons of a signed bundle: the file is covered by the
//  code signature, so the log destination can no longer be changed without
//  breaking the signature, and third-party software has no business owning a
//  path in /var/log anyway.
//
//  os.Logger instead. It survives a crash, it is timestamped and interleaved
//  with fskitd/launchd/DiskArbitration — which is exactly the correlation every
//  interesting failure in this project has needed — and `log show --predicate
//  'subsystem == "me.herko.iSCSIInitiator"'` gets it all back.
//
//  stderr is kept in parallel. Under launchd it goes nowhere and costs nothing;
//  run `swift run iscsid` in a terminal and you still see output, which is the
//  dev loop.
//

import Foundation
import os

public enum DaemonLog {
    public static let subsystem = "me.herko.iSCSIInitiator"

    private static let sessionLog = Logger(subsystem: subsystem, category: "session")
    private static let dextLog = Logger(subsystem: subsystem, category: "dext")
    private static let lifecycleLog = Logger(subsystem: subsystem, category: "lifecycle")

    /// Messages here are marked `.public`. os.Logger redacts interpolated
    /// strings by default, and a log full of `<private>` is the reason the FSKit
    /// enablement bug took days instead of hours to characterise.
    ///
    /// The tradeoff is explicit: target IQNs, hostnames and LUN numbers are
    /// diagnostics on the user's own machine and are logged. **CHAP secrets and
    /// key material must never be passed to any of these.** There is no
    /// redaction to fall back on once a string reaches here.
    public static func lifecycle(_ message: String) {
        lifecycleLog.notice("\(message, privacy: .public)")
        echo(message)
    }

    public static func session(_ message: String) {
        sessionLog.notice("\(message, privacy: .public)")
        echo(message)
    }

    public static func dextMessage(_ message: String) {
        dextLog.notice("\(message, privacy: .public)")
        echo("iscsid[dext]: \(message)")
    }

    public static func error(_ message: String) {
        lifecycleLog.error("\(message, privacy: .public)")
        echo(message)
    }

    private static func echo(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
