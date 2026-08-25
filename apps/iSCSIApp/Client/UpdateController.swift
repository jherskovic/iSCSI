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
//  Nothing here handles the *post*-update repair. It does not need to: replacing
//  the bundle drops the extension's registration, and the setup machine
//  re-checks every condition on every launch — a Sparkle relaunch is a launch.
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
    /// What is attached, in the words the user would use for it. Naming the
    /// volume is the difference between a rule and an instruction.
    var attachedVolumeNames: () -> [String] = { [] }
    /// Offered as the default button, so the dialog that says why the update is
    /// stuck can also be the thing that unsticks it.
    var detachEverything: () async -> Void = {}

    @Published private(set) var canCheckForUpdates = false
    /// Non-nil when an update is downloaded and waiting for volumes to go away.
    @Published private(set) var pendingUpdateVersion: String?

    private var controller: SPUStandardUpdaterController!
    /// Sparkle hands us a block to call when we are ready to let it proceed.
    /// @unchecked Sendable box: Sparkle's block is not typed Sendable, and
    /// this method is nonisolated, so the compiler cannot see that the block is
    /// only ever stored and called on the main actor. Which it is.
    private struct InstallHandler: @unchecked Sendable {
        let invoke: () -> Void
    }
    private var resumeInstallation: InstallHandler?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        // KVO-observable rather than @Published, so bridge it once here and
        // let the menu item bind to a plain Bool.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
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
    /// The rule.
    ///
    /// Sparkle calls this before replacing the bundle. Returning true holds the
    /// installation until `invocation` is called, which happens once the last
    /// volume is detached — or on the next launch, when nothing is attached yet
    /// and the update simply proceeds.
    nonisolated func updater(_ updater: SPUUpdater,
                             shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let handler = InstallHandler(invoke: installHandler)
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            guard isAnythingAttached() else { return false }
            pendingUpdateVersion = version
            resumeInstallation = handler
            // Scheduled rather than run inline. This method owes Sparkle a Bool
            // synchronously, and a modal here would put a dialog on top of the
            // update window Sparkle is in the middle of taking down — and hold
            // its teardown open behind a click.
            Task { @MainActor [weak self] in
                self?.explainPostponement(version: version)
            }
            return true
        }
    }
}

// MARK: - Saying so

private extension UpdateController {
    /// The dialog the user gets instead of silence.
    func explainPostponement(version: String) {
        let names = attachedVolumeNames()
        let subject = names.isEmpty
            ? "a volume that is attached"
            : ListFormatter.localizedString(byJoining: names.map { "“\($0)”" })

        NSApp.activate()

        let alert = NSAlert()
        // Informational, not a warning: refusing is the app working correctly,
        // and dressing it as a problem would teach the user to distrust it.
        alert.alertStyle = .informational
        alert.messageText = "Version \(version) will install after you detach"
        alert.informativeText = """
            Installing now would replace the filesystem extension that \
            \(subject) is using, and anything writing to it at that moment \
            would lose the process answering its reads and writes.

            The update is downloaded and ready. It will install itself and \
            relaunch the app as soon as the last volume is detached, or the \
            next time you launch.
            """
        alert.addButton(withTitle: "Detach and Install")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            await self?.detachEverything()
            // Also reached by the app model watching attachments, which is what
            // covers a Finder eject. Calling here too is what makes the button
            // feel like it did something; installPendingUpdateIfReady clears its
            // handler before invoking it, so arriving twice is harmless.
            self?.installPendingUpdateIfReady()
        }
    }
}

// MARK: - Menu item

/// The menu bar popover's row.
///
/// Styled as a row rather than as a `Button`, because the popover is a menu and
/// everything else in it is a row. A bordered button in the middle of a list of
/// plain labels reads as a different kind of thing, and it was also sitting
/// between "Detach All" and the window item, which put a rarely-used command
/// above two frequently-used ones.
///
/// A separate view rather than an inlined `menuButton` call so that
/// `@ObservedObject` sits on something that actually redraws: `canCheckForUpdates`
/// and `pendingUpdateVersion` live on `UpdateController`, and observing
/// `AppModel` does not propagate its changes.
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
                // The standing reminder, for after the dialog has been
                // dismissed. It names the relaunch because that is the part
                // that is startling if it is not expected.
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

/// The same command in the application menu, under "About iSCSI Initiator".
///
/// Plain `Button`, unlike the popover's row: this one *is* a menu item, and
/// AppKit draws it. Styling it would make it the odd one out here for exactly
/// the reason the popover version needed restyling.
struct AppMenuUpdatesItem: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}
