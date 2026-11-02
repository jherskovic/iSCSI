//
//  MenuBarLabel.swift
//  The menu bar icon, and the one place the main window is opened from
//  outside a window.
//
//  The window is `.suppressed` at launch and `openWindow` only exists inside a
//  view. This label is the only view that is always alive — at login there is
//  no window at all — so a request to show the window (a manual launch, a Dock
//  click, an auto-attach run that ended with failures) is a flag on the model
//  that this view acts on.
//
//  Alive is not the same as evaluated. A hidden menu bar item's label is not
//  evaluated while the app is in the background, so the end of an
//  attach-at-login run also opens the window by URL (`MainWindowURL`).
//

import AppKit
import iSCSIKit
import os
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The icon carries the state: a filled drive when something is
        // mounted, a warning when setup has something to address or a marked
        // target did not attach at login. For most users on most days this is the only
        // part of the app they look at.
        Image(systemName: symbol)
            .onChange(of: model.wantsMainWindow, initial: true) { _, wants in
                guard wants else { return }
                model.wantsMainWindow = false
                openWindow(id: "main")
                NSApp.activate()
            }
    }

    private var symbol: String {
        // Not `!isReady`, which is also true while the launch check runs:
        // the warning is for something to address, not for "not known yet".
        if model.setup.needsAttention || !model.autoAttachFailures.isEmpty {
            return "externaldrive.badge.exclamationmark"
        }
        return model.attachments.attachments.contains(where: \.isFullyAttached)
            ? "externaldrive.fill.badge.checkmark"
            : "externaldrive"
    }
}

/// The main window by URL, for a request made while the app is in the
/// background.
///
/// Measured on the 26.6 VM, 2026-10-22: with the menu bar item hidden in
/// System Settings, an attach-at-login run ended with a failure and set
/// `wantsMainWindow`, and no window opened. The label was evaluated only once a
/// Dock click made the app active. A MacBook with a notch and a full menu bar
/// hides the item without any setting, which gives the same result. A URL
/// reaches the `Window` scene as an Apple event through LaunchServices,
/// whatever the UI is doing.
///
/// The URL itself is `MainWindowLink`, in iSCSIKit, where a test holds it to
/// the scheme the Info.plist declares.
enum MainWindowURL {
    @MainActor
    static func open() {
        let url = MainWindowLink.url
        let log = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "autoattach")
        log.notice("asking for the main window by URL")
        // Pinned to this copy: given only the URL, LaunchServices chooses
        // among every registered copy of the app.
        NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                log.error("main window URL failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
