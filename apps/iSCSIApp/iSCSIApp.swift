//
//  iSCSIApp.swift
//  Scene graph for iSCSI Initiator.
//
//  MenuBarExtra plus a real window, and deliberately **no LSUIElement**. A
//  storage manager needs a Dock icon: when a volume vanishes, "where did my disk
//  go" has to be answerable by looking for the app that mounted it, and an app
//  that lives only in the menu bar cannot be found by someone who does not
//  already know it is there.
//
//  The window does not open by itself at launch: a login launch attaches
//  marked targets with nothing on screen. `AppDelegate` decides, and
//  `MenuBarLabel` opens it.
//

import AppKit
import iSCSIKit
import os
import SwiftUI

@main
struct ISCSIInitiatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    init() {
        // The dock tile plug-in only covers the tile while the app is NOT
        // running; install the same un-squircled icon for the running case.
        // Deferred so NSApp exists.
        DispatchQueue.main.async { Self.installDockIcon() }
    }

    /// Draws icon.png straight into the Dock tile, escaping macOS 26's
    /// forced squircle backdrop. The image lives in the dock tile plug-in
    /// bundle so it ships only once.
    @MainActor
    private static func installDockIcon() {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(
            "iSCSI Initiator Dock.docktileplugin/Contents/Resources/DockIcon.png"),
            let image = NSImage(contentsOf: url)
        else { return }
        let tile = NSApplication.shared.dockTile
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        view.image = image
        tile.contentView = view
        tile.display()
    }

    var body: some Scene {
        Window("iSCSI/NVMe/TCP Initiator", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultLaunchBehavior(.suppressed)
        // Not restored from saved state either: a window left open at logout
        // must not come back on a login launch. Every other launch asks for it.
        .restorationBehavior(.disabled)
        // Shown by URL when the app is in the background (MainWindowURL).
        .handlesExternalEvents(matching: [MainWindowLink.host])
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }

            CommandGroup(after: .appInfo) {
                AppMenuUpdatesItem(updates: model.updates)
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @State private var section: Section? = .targets
    @State private var isUninstalling = false
    /// The uninstall sheet moved the app to the Trash. The app quits once
    /// the sheet has closed: AppKit refuses to terminate an app with a
    /// sheet open ("App termination blocked by modal sheet").
    @State private var movedToTrash = false
    /// Auto-selection happens once per window, never again. 
    @State private var hasChosenLanding = false

    enum Section: String, CaseIterable, Identifiable {
        case targets, discover, sessions, setup
        var id: String { rawValue }

        var title: String {
            switch self {
            case .targets:  return "Targets"
            case .discover: return "Discover"
            case .sessions: return "Sessions"
            case .setup:    return "Setup"
            }
        }

        var symbol: String {
            switch self {
            case .targets:  return "externaldrive"
            case .discover: return "magnifyingglass"
            case .sessions: return "bolt.horizontal"
            case .setup:    return "checklist"
            }
        }
    }

    /// Land on Setup when there is something to do there.
    ///
    /// Targets is the right home once everything works, but on a fresh install
    /// it is an empty list with a disabled Add button and nothing saying that
    /// the work is one screen away. `!isReady` covers first launch, since a new
    /// install always has an unregistered daemon.
    ///
    /// Not "no targets yet": once setup is green, the empty Targets screen
    /// explains itself and has the button you want, whereas an all-green Setup
    /// screen would be a dead end.
    private func chooseLandingSection() {
        guard !hasChosenLanding else { return }
        hasChosenLanding = true
        if !model.isReady { section = .setup }
    }

    private func isWorking(_ item: Section) -> Bool {
        switch item {
        case .targets:             return model.isLoadingTargets
        case .setup:               return model.setup.isWorking
        case .discover, .sessions: return false
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                NavigationLink(value: item) {
                    // Setup is the only screen that can be *wrong* rather
                    // than merely empty, so it says so from the sidebar
                    // instead of waiting to be visited.
                    SidebarRow(title: item.title, symbol: item.symbol,
                               isWorking: isWorking(item),
                               needsAttention: item == .setup && model.setup.needsAttention)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch section {
            case .targets:  TargetsView(model: model)
            case .discover: DiscoveryView(model: model)
            case .sessions: SessionsView(model: model)
            case .setup, .none:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SetupView(setup: model.setup)

                        HStack {
                            Spacer()
                            Button("Remove iSCSI Initiator…") { isUninstalling = true }
                        }

                        DisclosureGroup("Diagnostics") {
                            VStack(alignment: .leading, spacing: 12) {
                                FSKitProbeView()
                                DaemonPanelView()
                            }
                            .padding(.top, 6)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Setup")
            }
        }
        .onOpenURL { _ in
            Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "autoattach")
                .notice("main window shown by URL")
        }
        .task {
            FSKitSettingsLinkCheck.verify()
            await model.refresh()
            chooseLandingSection()
        }
        // Everything shown here can change without the app being told: the user
        // can eject in Finder, deny the daemon in System Settings, or power off
        // the storage. Refreshing when the app comes forward is both cheaper and
        // more accurate than a timer that is wrong most times it fires.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .sheet(isPresented: $isUninstalling, onDismiss: {
            if movedToTrash { NSApp.terminate(nil) }
        }) {
            UninstallView(model: model) { movedToTrash = true }
        }
        .alert(item: $model.lastError) { error in
            Alert(title: Text(error.title),
                  message: Text([error.message, error.suggestion]
                    .compactMap { $0 }.joined(separator: "\n\n")),
                  dismissButton: .default(Text("OK")))
        }
    }
}
