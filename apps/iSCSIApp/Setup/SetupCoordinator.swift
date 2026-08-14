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
//    location -> daemon -> registered -> enabled
//
//  Location first because SMAppService registration from a translocated bundle
//  points at a path that will not exist. Daemon before enabled because on macOS
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
        /// True for the first not-yet-satisfied step only. Everything after it
        /// renders its state but offers no button — clicking "Enable" before the
        /// daemon exists produces a failure that teaches the user nothing.
        let isNext: Bool
    }

    @Published private(set) var reports: [Report] = []
    @Published private(set) var isChecking = false

    /// Every prerequisite holds. The GUI gates its Connect affordances on this.
    var isReady: Bool {
        !reports.isEmpty && reports.allSatisfy(\.state.isSatisfied)
    }

    private let steps: [any SetupStep]
    let daemon = DaemonController()

    init() {
        steps = [
            InstallLocation(),
            DaemonStep(controller: daemon),
            ModuleRegistration(),
            ModuleEnablement(),
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
            return .blocked("the background service is approved but not running. "
                            + "Reinstalling from the disk image usually fixes this.")
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
        case .versionMismatch:  return "Reinstall"
        default:                return nil
        }
    }

    func check() async { await controller.refresh() }

    func perform() async {
        switch controller.state {
        case .notRegistered:    await controller.register()
        case .requiresApproval: controller.openLoginItemsSettings()
        case .versionMismatch:  await controller.reregister()
        default:                break
        }
    }
}
