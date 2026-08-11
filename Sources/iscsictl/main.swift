import ArgumentParser
import Foundation
import iSCSIKit

// iscsictl — control CLI. Subcommands (discover/login/logout/status/verify)
// arrive in Phase 4 alongside the daemon.

struct ISCSICtl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iscsictl",
        abstract: "Control the macOS iSCSI initiator.",
        version: "0.0.1"
    )

    func run() throws {
        print("iscsictl: daemon control arrives in Phase 4")
    }
}

ISCSICtl.main()
