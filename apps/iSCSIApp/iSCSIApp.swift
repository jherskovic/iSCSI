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

import SwiftUI

@main
struct ISCSIInitiatorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("iSCSI Initiator", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            // The icon carries the state: a filled drive when something is
            // mounted, a warning when setup is incomplete. For most users on
            // most days this is the only part of the app they look at.
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if !model.isReady { return "externaldrive.badge.exclamationmark" }
        return model.attachments.attachments.contains(where: \.isFullyAttached)
            ? "externaldrive.fill.badge.checkmark"
            : "externaldrive"
    }
}

struct MainWindow: View {
    @ObservedObject var model: AppModel
    @State private var section: Section? = .targets
    @State private var isUninstalling = false
    /// Auto-selection happens once per window, never again. Re-running it on
    /// every foreground would yank the user off whatever they were reading
    /// each time they switched apps — which is exactly when they are most
    /// likely to be reading something.
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

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.symbol)
                        // Setup is the only screen that can be *wrong* rather
                        // than merely empty, so it says so from the sidebar
                        // instead of waiting to be visited.
                        .badge(item == .setup && !model.isReady ? "!" : nil)
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
        .sheet(isPresented: $isUninstalling) {
            UninstallView(model: model)
        }
        .alert(item: $model.lastError) { error in
            Alert(title: Text(error.title),
                  message: Text([error.message, error.suggestion]
                    .compactMap { $0 }.joined(separator: "\n\n")),
                  dismissButton: .default(Text("OK")))
        }
    }
}
