//
//  SetupCoordinator.swift
//  Runs every setup step, in order, on every launch.
//
//  "On every launch" is the load-bearing part. The alternative — a first-run
//  wizard that never runs again — cannot notice that something stopped being
//  true, and things here do stop being true: an update replaces the bundle and
//  the daemon needs re-registering, a bundle replacement drops the extension's
//  registration, a user revokes approval in System Settings. Re-checking
//  unconditionally means the repair path is the same code as the install path,
//  and a Sparkle relaunch needs no special handling at all because it is just a
//  launch.
//
//  Ordering is not cosmetic:
//
//    location -> other copies -> daemon -> registered -> enabled
//
//  Location first because SMAppService registration from a translocated bundle
//  points at a path that will not exist. Other copies next: a second
//  registered copy (a once-launched DMG, a build product) is what lets the
//  later steps report green over a broken install, and cleaning it up does
//  not depend on the daemon. Daemon before enabled because on macOS
//  26.x the enablement fallback needs the daemon to signal fskitd as root, so
//  the daemon has to be answering before that step can succeed.
//
//  Step B from the plan — Full Disk Access — is deliberately absent. It was
//  conditional on the enablement write being denied by TCC, and it is not: a
//  drag-installed notarized build writes enabledModules.plist with no prompt.
//  Measured, see docs/backend-a-fskit-notes.md. Do not add it speculatively.
//

import Foundation
import SwiftUI

@MainActor
final class SetupCoordinator: ObservableObject {
    struct Report: Identifiable, Equatable {
        let id: String
        let title: String
        let state: StepState
        let actionLabel: String?
        let consentPrompt: String?
        let consentTitle: String?
        /// True for the first not-yet-satisfied step only. Everything after it
        /// renders its state but offers no button — clicking "Enable" before the
        /// daemon exists produces a failure that teaches the user nothing.
        let isNext: Bool
    }

    @Published private(set) var reports: [Report] = []
    @Published private(set) var isChecking = false
    /// The step whose action is running, so the screen can say so.
    ///
    /// Tracked here rather than read off the step's own `.checking` state
    /// because `perform` does not republish until it returns: a step can set
    /// itself to `.checking` and the screen will not know for as long as the
    /// work takes. Registering the daemon can take seconds — it waits for
    /// launchd to record the job and for the daemon to answer — and for all of
    /// that the button sat there lit and unchanged, which reads as a button
    /// that does nothing.
    @Published private(set) var busyStepID: String?
    /// What the button said when it was pressed. `actionLabel` goes nil while
    /// a step is checking, so it cannot be used to label the work in progress.
    @Published private(set) var busyLabel: String?

    /// Every prerequisite holds. The GUI gates its Connect affordances on this.
    var isReady: Bool {
        !reports.isEmpty && reports.allSatisfy(\.state.isSatisfied)
    }

    private let steps: [any SetupStep]
    let daemon = DaemonController()
    /// One local test mount per check pass, shared by both FSKit steps.
    private let fskitProbe = FSKitAttachProbe()

    init() {
        steps = [
            InstallLocation(),
            OtherCopies(),
            DaemonStep(controller: daemon),
            ModuleRegistration(probe: fskitProbe),
            ModuleEnablement(probe: fskitProbe),
        ]
    }

    func checkAll() async {
        isChecking = true
        defer { isChecking = false }
        // Sequential, not concurrent: later steps read state that earlier ones
        // can change, and four cheap local queries are not worth the confusion
        // of racing them.
        for step in steps {
            await step.check()
            publish()
        }
    }

    func perform(_ id: String) async {
        guard let step = steps.first(where: { $0.id == id }) else { return }
        busyStepID = id
        busyLabel = step.actionLabel
        defer { busyStepID = nil; busyLabel = nil }
        await step.perform()
        // Re-check everything, not just this step: satisfying one commonly
        // unblocks another, and the screen should show that immediately rather
        // than waiting for the user to go away and come back.
        await checkAll()
    }

    private func publish() {
        var seenUnsatisfied = false
        reports = steps.map { step in
            let isNext = !step.state.isSatisfied && !seenUnsatisfied
            if !step.state.isSatisfied { seenUnsatisfied = true }
            return Report(id: step.id,
                          title: step.title,
                          state: step.state,
                          actionLabel: step.actionLabel,
                          consentPrompt: step.consentPrompt,
                          consentTitle: step.consentTitle,
                          isNext: isNext)
        }
    }
}

// MARK: - The daemon, as a step

/// Adapts `DaemonController` to `SetupStep`. The controller predates the
/// protocol and carries more detail than a step needs (it drives the M2 probe
/// panel); this exposes only what the setup screen renders.
@MainActor
final class DaemonStep: SetupStep {
    let id = "daemon"
    let title = "Background service installed"
    private let controller: DaemonController

    init(controller: DaemonController) { self.controller = controller }

    var state: StepState {
        switch controller.state {
        case .checking:
            return .checking
        case .running(let info):
            return .satisfied("running \(info.version), pid \(info.pid)")
        case .notRegistered:
            return .actionable("iSCSI Initiator needs a background service to "
                               + "hold the connection to your storage.")
        case .requiresApproval:
            return .actionable("macOS is waiting for you to allow the background "
                               + "service in System Settings.")
        case .registeredNotResponding:
            return .actionable("the background service is approved but not running — "
                               + "most often because it belongs to a copy of the app that "
                               + "no longer exists. Reinstall it from this copy.")
        case .otherCopy(let path):
            return .actionable("the background service belongs to another copy of the app "
                               + "at \(path); it needs reinstalling from this one.")
        case .versionMismatch(let daemon, let app):
            return .actionable("the background service is version \(daemon) but "
                               + "this app is \(app); it needs reinstalling.")
        case .notFound:
            return .blocked("this copy of the app is incomplete — its background "
                            + "service is missing. Reinstall from the disk image.")
        case .failed(let why):
            return .blocked(why)
        }
    }

    var actionLabel: String? {
        switch controller.state {
        case .notRegistered:    return "Install"
        case .requiresApproval: return "Open System Settings"
        case .versionMismatch, .otherCopy, .registeredNotResponding:
            return "Reinstall"
        default:                return nil
        }
    }

    /// Reinstall over a daemon that is answering stops it, and every session
    /// it holds goes with it; those sessions are hidden while this step is
    /// unsatisfied, so the user cannot see what they would lose.
    var consentPrompt: String? {
        guard case .otherCopy = controller.state else { return nil }
        return "This stops the background service running from the other copy and "
            + "starts it from this one. Disks attached through it lose their "
            + "connection — eject them in Finder first."
    }

    var consentTitle: String? { "Reinstall the background service?" }

    func check() async { await controller.refresh() }

    func perform() async {
        switch controller.state {
        case .notRegistered:    await controller.register()
        case .requiresApproval: controller.openLoginItemsSettings()
        case .versionMismatch, .otherCopy, .registeredNotResponding:
            await controller.reregister()
        default:                break
        }
    }
}
