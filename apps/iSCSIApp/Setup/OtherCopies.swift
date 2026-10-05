//
//  OtherCopies.swift
//  Setup step: no other copy of the app is registered with macOS.
//
//  LaunchServices registers the app inside a mounted disk image once it runs
//  from there, and keeps that registration after the image is ejected; build
//  products register too. Every other step checks presence, so a stray copy
//  slips past all of them — and launchd may start the daemon out of it, which
//  breaks every attach once that copy is gone (measured 2026-10-05,
//  docs/backend-a-fskit-notes.md). This step checks plurality.
//  See docs/superpowers/specs/2026-10-05-setup-repair-design.md.
//

import AppKit
import Foundation
import iSCSIKit

private let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework"
    + "/Frameworks/LaunchServices.framework/Support/lsregister"

@MainActor
final class OtherCopies: SetupStep {
    let id = "other-copies"
    let title = "No other copies registered"
    private(set) var state: StepState = .checking
    private var others: [RegisteredCopy] = []
    /// The dump's answer, kept for the launch: the coordinator re-checks
    /// every step after every action, and 2.3 s each time would be felt.
    /// Dropped after Clean up, the one action that changes it.
    private var dumped: [String]?

    func check() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "me.herko.iSCSIInitiator"
        // ~4 ms; LaunchServices' own answer, by bundle identifier.
        let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .map(\.path)
        // The fast query omits registrations whose bundle is gone (measured
        // 2026-10-05, docs/backend-a-fskit-notes.md); the dump sees them.
        // ~2.3 s, so off the main actor, and once.
        if dumped == nil {
            dumped = await Task.detached { FSKitRegistrationAudit.registeredAppBundles() }.value
        }
        others = RegisteredCopies.others(registered: registered + (dumped ?? []),
                                         running: Bundle.main.bundleURL.path,
                                         exists: { FileManager.default.fileExists(atPath: $0) })
        state = others.isEmpty
            ? .satisfied("only this copy is registered")
            : .actionable(RegisteredCopies.summary(others, home: NSHomeDirectory()))
    }

    var actionLabel: String? { state.isSatisfied ? nil : "Clean up" }

    var consentPrompt: String? {
        guard !state.isSatisfied else { return nil }
        return "This removes macOS's registration of the copies listed above so only "
            + "this one is used. It does not delete any files."
    }

    /// Unregister every other copy, then ask LaunchServices again rather than
    /// assume it worked — a copy that would not unregister stays listed.
    func perform() async {
        let paths = others.map(\.path)
        state = .checking
        // Off the main actor, like every subprocess the app waits on.
        await Task.detached {
            for path in paths { Self.unregister(path) }
        }.value
        dumped = nil
        await check()
    }

    nonisolated private static func unregister(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-u", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Nothing to do here: the re-check after this reports the copy as
            // still registered, which is the honest answer.
        }
    }
}
