//
//  AppDelegate.swift
//  Which kind of launch this is, and what each kind shows.
//
//  The main window no longer opens by itself (it is `.suppressed`): a login
//  launch attaches marked targets with nothing on screen, and every other
//  launch asks for the window here. Measured on macOS 26.6.2, SIP on, with a
//  probe registered through `SMAppService.mainApp` (2026-10-22):
//
//    * login item launch: `aevt/oapp` with keyAEPropData = 'lgit'
//    * manual launch:     `aevt/oapp` with no keyAEPropData
//    * Dock click while windowless: SwiftUI does not reopen a suppressed
//      Window, so `applicationShouldHandleReopen` has to ask for it
//    * `currentAppleEvent` is nil in `applicationWillFinishLaunching`; it is
//      the oapp event in `applicationDidFinishLaunching`
//
//  The event test itself is `LoginLaunch.isLoginItemLaunch`, in iSCSIKit, where
//  it is tested. The delegate owns `AppModel` so it can act on launch before
//  any view exists.
//

import AppKit
import iSCSIKit
import os

private let launchLog = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "autoattach")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.applyRelaunchPolicy()
        if LoginLaunch.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent) {
            launchLog.notice("launched as a login item")
            model.beginLoginLaunch()
        } else {
            launchLog.notice("launched by hand")
            model.wantsMainWindow = true
            model.updates.start()
        }
    }

    /// A prepared update installs when the app quits, so this is the update
    /// rule's second gate (`UpdateController.replyToTermination`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.updates.replyToTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.wantsMainWindow = true }
        return false
    }
}
