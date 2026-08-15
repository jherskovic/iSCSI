//
//  UpdateController.swift
//  Sparkle, with the one rule this app cannot compromise on.
//
//  **An update replaces the app bundle. If a LUN is attached when that happens,
//  the FSKit extension serving it is replaced underneath a live filesystem.**
//  That is not an inconvenience, it is data loss — a volume the user is writing
//  to loses the process answering its reads and writes.
//
//  So installation is postponed while anything is attached, and automatic
//  installation is off entirely. The cost is that updates land later; the
//  alternative is an app that can corrupt a volume overnight while nobody is
//  watching, which is not a trade worth making for a faster update cadence.
//
//  Nothing here handles the *post*-update repair. It does not need to: replacing
//  the bundle drops the extension's registration, and the setup machine
//  re-checks every condition on every launch — a Sparkle relaunch is a launch.
//  Verified in the field when 0.1.3 landed over 0.1.2 and the Register button
//  fixed exactly that. See docs/daemon-registration.md.
//

import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdateController: NSObject, ObservableObject {
    /// Set by the app model so the postpone check can see live state without
    /// this class owning any.
    var isAnythingAttached: () -> Bool = { false }

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
        return MainActor.assumeIsolated {
            guard isAnythingAttached() else { return false }
            pendingUpdateVersion = item.displayVersionString
            resumeInstallation = handler
            return true
        }
    }
}

// MARK: - Menu item

struct CheckForUpdatesButton: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
            if let version = updates.pendingUpdateVersion {
                // Says why nothing is happening. An update that has downloaded
                // and then appears to do nothing reads as a broken updater.
                Text("Version \(version) is ready and will install once every "
                     + "volume is detached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
