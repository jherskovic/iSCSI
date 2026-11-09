//
//  UpdateController.swift
//  Sparkle, with the one rule this app cannot compromise on.
//
//  **An update replaces the app bundle. If a LUN is attached when that happens,
//  the FSKit extension serving it is replaced underneath a live filesystem.**
//  That is not an inconvenience, it is data loss.
//
//  So installation is postponed while anything is attached, and automatic
//  installation is off entirely. The cost is that updates land later.
//
//  Postponing the relaunch is not enough on its own. Once Sparkle has prepared
//  an update, its installer finishes the job when the app terminates, whatever
//  the user answered: "Later" in the dialog below, or dismissing Sparkle's own
//  ready-to-install prompt (SPUUpdaterDelegate.h, `userDidMakeChoice`: "the
//  update is still set to install on application termination"). So a quit
//  with an update prepared and a volume attached is the same hazard, and
//  `replyToTermination` asks for a detach first.
//
//  "Attached" means anything this app mounted, in any account: there is one
//  bundle and one extension for the Mac (`AppReplacement`).
//
//  Nothing here handles the *post*-update repair. It does not need to: replacing
//  the bundle drops the extension's registration, and the setup machine
//  re-checks every condition on every launch — a Sparkle relaunch is a launch.
//
//  The updater starts when the app delegate says so, not in `init`. A login
//  launch is meant to be silent while marked targets attach, and an update
//  alert is a window; so on that launch Sparkle starts only once the
//  auto-attach run is over. Until `start()` no check can find an update, which
//  is why the postpone path below needs no "run in progress" input.
//

import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdateController: NSObject, ObservableObject {
    /// Set by the app model so the postpone check can see live state without
    /// this class owning any.
    var isAnythingAttached: () -> Bool = { false }
    /// What is attached, in the user's words — the dialog names the volumes.
    var attachedVolumeNames: () -> [String] = { [] }
    /// Offered as the default button, so the dialog that says why the update is
    /// stuck can also be the thing that unsticks it.
    var detachEverything: () async -> Void = {}

    @Published private(set) var canCheckForUpdates = false
    /// Non-nil when an update is downloaded and waiting for volumes to go away.
    @Published private(set) var pendingUpdateVersion: String?
    /// Set once Sparkle has an update extracted and its installer waiting:
    /// from then on, quitting installs it. Cleared only by Skip, which is the
    /// one answer that cancels the installer.
    private(set) var preparedUpdateVersion: String?

    private var controller: SPUStandardUpdaterController!
    /// Sparkle's resume block. @unchecked Sendable: the block is not typed
    /// Sendable but is only stored and called on the main actor.
    private struct InstallHandler: @unchecked Sendable {
        let invoke: () -> Void
    }
    private var resumeInstallation: InstallHandler?
    private var didStart = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // KVO-observable, bridged once so the menu item binds a plain Bool.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Starts Sparkle, including its scheduled checks. Later calls do nothing.
    func start() {
        guard !didStart else { return }
        didStart = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// The app delegate's answer to a quit. A quit with a prepared update
    /// installs it (see the file header), so with anything attached the user
    /// is asked to detach first, or to keep the app open.
    ///
    /// A logout, restart or shutdown is let through: everything is going down
    /// anyway, and a cancelled quit would cancel the logout.
    func replyToTermination() -> NSApplication.TerminateReply {
        guard let version = preparedUpdateVersion ?? pendingUpdateVersion,
              isAnythingAttached(), !Self.isSystemQuit else { return .terminateNow }

        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quitting now installs version \(version)"
        alert.informativeText = """
            The update installs when the app quits, and installing replaces the \
            filesystem extension that \(subjectForAlert()) is using.

            Detach first, or keep the app open and quit later.
            """
        alert.addButton(withTitle: "Detach and Quit")
        alert.addButton(withTitle: "Don't Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await detachEverything()
            guard isAnythingAttached() else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            NSApp.reply(toApplicationShouldTerminate: false)
            let still = NSAlert()
            still.alertStyle = .informational
            still.messageText = "The app is staying open"
            still.informativeText = """
                Still attached: \(subjectForAlert()). Quitting would install the \
                update under it. Detach it — in each account that has one — and \
                quit again.
                """
            still.runModal()
        }
        return .terminateLater
    }

    /// A quit sent by loginwindow carries why: logout, restart or shutdown.
    private static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    /// Called after a detach, in case an update has been waiting for one.
    func installPendingUpdateIfReady() {
        guard let resume = resumeInstallation, !isAnythingAttached() else { return }
        resumeInstallation = nil
        pendingUpdateVersion = nil
        resume.invoke()
    }
}

extension UpdateController: SPUUpdaterDelegate {
    /// The rule: called before Sparkle replaces the bundle; returning true
    /// holds installation until the last volume is detached (or the next
    /// launch, when nothing is attached).
    nonisolated func updater(_ updater: SPUUpdater,
                             shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let handler = InstallHandler(invoke: installHandler)
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            guard isAnythingAttached() else { return false }
            pendingUpdateVersion = version
            resumeInstallation = handler
            // Scheduled: this method owes Sparkle a Bool synchronously, and a
            // modal here would hold Sparkle's teardown open behind a click.
            Task { @MainActor [weak self] in
                self?.explainPostponement(version: version)
            }
            return true
        }
    }

    /// From here Sparkle's installer is waiting, and installs on quit.
    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { preparedUpdateVersion = version }
    }

    /// Also reached by an update resumed from an earlier launch, which never
    /// passes through extraction in this process.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { preparedUpdateVersion = version }
    }

    /// Skip cancels the installer; Dismiss leaves it set to install on quit.
    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                             forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        MainActor.assumeIsolated { preparedUpdateVersion = nil }
    }
}

// MARK: - Saying so

private extension UpdateController {
    /// The dialog the user gets instead of silence.
    /// What is attached, for a sentence: the names, or a stand-in.
    func subjectForAlert() -> String {
        let names = attachedVolumeNames()
        return names.isEmpty
            ? "a volume that is attached"
            : ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })
    }

    func explainPostponement(version: String) {
        let subject = subjectForAlert()

        NSApp.activate()

        let alert = NSAlert()
        // Informational, not a warning: refusing is the app working correctly.
        alert.alertStyle = .informational
        alert.messageText = "Version \(version) will install after you detach"
        alert.informativeText = """
            Installing now would replace the filesystem extension that \
            \(subject) is using, and anything writing to it at that moment \
            would lose the process answering its reads and writes.

            The update is downloaded and ready. It will install itself and \
            relaunch the app as soon as the last volume is detached. Quitting \
            the app installs it too, so a quit asks you to detach first.
            """
        alert.addButton(withTitle: "Detach and Install")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            await self?.detachEverything()
            // The attachment sink also reaches this; it clears its handler
            // before invoking, so arriving twice is harmless.
            self?.installPendingUpdateIfReady()
        }
    }
}

// MARK: - Menu item

/// The menu bar popover's row, styled like the rows around it. A separate
/// view so `@ObservedObject` sits on something that actually redraws —
/// observing `AppModel` does not propagate `UpdateController`'s changes.
struct CheckForUpdatesButton: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { updates.checkForUpdates() } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .disabled(!updates.canCheckForUpdates)

            if let version = updates.pendingUpdateVersion {
                // Standing reminder after the dialog; names the relaunch
                // because that is the startling part.
                Text("Version \(version) is ready. It will install and relaunch "
                     + "once every volume is detached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// The same command in the application menu. Plain `Button`: this one *is* a
/// menu item, and AppKit draws it.
struct AppMenuUpdatesItem: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}
