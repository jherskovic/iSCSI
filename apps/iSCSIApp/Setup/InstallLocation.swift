//
//  InstallLocation.swift
//  Setup step A: the app is somewhere a LaunchDaemon can be registered from.
//
//  This has to pass before the daemon step is even attempted. Two reasons, both
//  measured or documented rather than guessed:
//
//    * SMAppService.h: "For a LaunchDaemon to be bootstrapped during boot, the
//      containing application must be accessible before a user logs in. For
//      applications that intend to register LaunchDaemons, it is recommended
//      that the application bundle live in /Applications."
//    * A translocated bundle is mounted at a randomised read-only path that
//      disappears when the app quits, so a BundleProgram registered from there
//      points at nothing the next time launchd looks.
//

import AppKit
import Foundation

@MainActor
final class InstallLocation: SetupStep {
    let id = "location"
    let title = "Installed in Applications"
    private(set) var state: StepState = .checking

    /// Where the running bundle actually is, which is not necessarily where the
    /// user put it — see translocation below.
    private var bundleURL: URL { Bundle.main.bundleURL }

    /// Gatekeeper Path Randomization: macOS runs a quarantined app from a
    /// read-only disk image under /private/var/folders/…/AppTranslocation/ so a
    /// downloaded app cannot see files next to it. `SecTranslocateIsTranslocatedURL`
    /// is not in the public SDK, so detect it from the path — the directory name
    /// is stable and this is what every app that handles it does.
    var isTranslocated: Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    /// `/Applications` only — deliberately not `~/Applications`.
    ///
    /// The daemon's plist uses `BundleProgram`, resolved relative to this
    /// bundle, so launchd runs a root binary out of whatever directory the app
    /// sits in. `~/Applications` is owned and writable by the unprivileged user.
    ///
    /// That is not arbitrary root execution — launchd validates the signature,
    /// and an attacker has no Developer ID for this team. What it does allow is
    /// a silent **downgrade**: replace the bundle with an older, still validly
    /// signed release of this same app and launchd will happily run it, putting
    /// back whatever has since been fixed. No prompt, no signature failure,
    /// nothing the user would notice.
    var isInApplications: Bool {
        bundleURL.path.hasPrefix("/Applications/")
    }

    func check() async {
        if isTranslocated {
            state = .actionable(
                "running from a temporary read-only copy (App Translocation). "
                + "Move it to Applications and reopen — a daemon registered from "
                + "here would point at a path that disappears.")
            return
        }
        guard isInApplications else {
            // Names /Applications specifically, because ~/Applications is the
            // near miss this is most likely to be reporting and "Applications"
            // alone reads as if that would do.
            state = .actionable(
                "running from \(bundleURL.deletingLastPathComponent().path). "
                + "A LaunchDaemon has to be reachable before anyone logs in, and "
                + "it runs as root from wherever this app lives — so the app needs "
                + "to be in /Applications, which only an administrator can change, "
                + "rather than in your home folder.")
            return
        }
        state = .satisfied(bundleURL.path)
    }

    var actionLabel: String? { state.isSatisfied ? nil : "Reveal in Finder" }

    /// Deliberately not a move-and-relaunch.
    ///
    /// Moving the bundle out from under the running process, re-signing nothing,
    /// then re-execing is the LetsMove trick, and it is genuinely fiddly:
    /// authorization when /Applications is not writable, a translocated source
    /// that is read-only, and a window where neither copy is complete. Dragging
    /// is one gesture, it is what the DMG already asks for, and it cannot leave
    /// a half-moved install behind. Revisit if it turns out to be a real
    /// friction point; do not guess that it is.
    func perform() async {
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }
}
