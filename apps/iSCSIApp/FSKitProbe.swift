//
//  FSKitProbe.swift
//  Milestone 0-b instrumentation, not product UI.
//
//  The one thing that can kill the FSKit-backed v1 is the System Settings switch
//  under General → Login Items & Extensions → File System Extensions refusing to
//  turn our module on. That was observed on a Debug, Apple-Development-signed
//  build (docs/backend-a-fskit-notes.md:179-186), and independently reported
//  against Apple's own FSKitSample on macOS 26.x. It has never been tried with a
//  notarized Developer ID Release build, which is what M0-b tests.
//
//  Reading enabledModules.plist by hand answers the question badly: the file is
//  in a foreign group container, it is rewritten by fskit_agent, and the app may
//  not even be allowed to read it. FSClient answers it properly and is the same
//  API the shipping setup flow will use.
//

import Foundation
import FSKit
import SwiftUI

/// What the system thinks of our filesystem module, right now.
enum ModuleState: Equatable {
    /// FSKit does not list the bundle id at all — the appex is not registered.
    case notRegistered
    /// Listed but switched off. This is the state the toggle is supposed to change.
    case registeredDisabled(url: String)
    /// Listed and enabled. `mount -F` can work.
    case enabled(url: String)
    case failed(String)

    var isEnabled: Bool { if case .enabled = self { return true }; return false }

    var summary: String {
        switch self {
        case .notRegistered:
            return "not registered — FSKit does not know this module exists"
        case .registeredDisabled:
            return "registered, DISABLED — this is the gate"
        case .enabled:
            return "registered and ENABLED"
        case .failed(let why):
            return "query failed: \(why)"
        }
    }

    var color: Color {
        switch self {
        case .enabled:            return .green
        case .registeredDisabled: return .orange
        case .notRegistered:      return .secondary
        case .failed:             return .red
        }
    }
}

@MainActor
final class FSKitProbe: ObservableObject {
    static let moduleBundleID = "me.herko.iSCSIInitiator.fsext"

    @Published private(set) var state: ModuleState = .notRegistered
    @Published private(set) var allModules: [String] = []
    @Published private(set) var lastChecked: Date?
    /// Result of the M0-b.2 write attempt, nil until the button is pressed.
    @Published private(set) var writeReport: FSKitEnablement.Report?

    /// Ask FSKit directly rather than inferring from the settings plist.
    func refresh() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            allModules = modules
                .map { "\($0.isEnabled ? "on " : "off") \($0.bundleIdentifier)" }
                .sorted()

            if let mine = modules.first(where: { $0.bundleIdentifier == Self.moduleBundleID }) {
                let path = mine.url.path
                state = mine.isEnabled ? .enabled(url: path) : .registeredDisabled(url: path)
            } else {
                state = .notRegistered
            }
        } catch {
            state = .failed(error.localizedDescription)
            allModules = []
        }
        lastChecked = Date()
    }

    /// Take the user to the switch. `openFileSystemExtensionsSettings` is macOS 27
    /// and up; older systems get the URL scheme, which is undocumented and may
    /// dead-end — so fall back to System Settings' root rather than nothing.
    func openSettings() {
        // Reached by selector so this builds against the macOS 26 SDK; see
        // FSKitSettingsLink. Returns false on macOS 26, where the API does not
        // exist, and the URL fallback below runs instead.
        if FSKitSettingsLink.open() { return }
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
            "x-apple.systempreferences:",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// M0-b.2: perform the shipping 26.x write from the app's own TCC context.
    ///
    /// The write has only ever been proven from an ssh shell, which inherits the
    /// terminal's grants; a freshly installed app is a different principal
    /// against a foreign group container. Runs off the main actor because a TCC
    /// denial can block on a consent prompt.
    func attemptEnablementWrite() async {
        let report = await Task.detached { FSKitEnablement.enableModule() }.value
        writeReport = report
        // The entry only becomes live once fskitd re-reads it, which needs root,
        // so state will still read "disabled" here. Refresh anyway: if it does
        // flip, that is worth knowing.
        await refresh()
    }
}

/// The M0-b observation panel: module state, every installed module for context,
/// and a way to reach the switch. Deliberately plain — it is a measuring
/// instrument that ships only in the probe build.
struct FSKitProbeView: View {
    @StateObject private var probe = FSKitProbe()

    var body: some View {
        GroupBox("FSKit module (Backend A)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(probe.state.color).frame(width: 10, height: 10)
                    Text(probe.state.summary)
                    Spacer()
                    Button("Re-check") { Task { await probe.refresh() } }
                    Button("Open System Settings") { probe.openSettings() }
                }

                if case .registeredDisabled(let url) = probe.state {
                    Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                } else if case .enabled(let url) = probe.state {
                    Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }

                if !probe.allModules.isEmpty {
                    Divider()
                    Text("All installed modules")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(probe.allModules.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                Divider()

                // M0-b.2. Separated from the state display above because it is
                // the only control here that changes anything.
                HStack(spacing: 8) {
                    Text("macOS 26.x fallback")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Attempt enablement write") {
                        Task { await probe.attemptEnablementWrite() }
                    }
                }

                if let report = probe.writeReport {
                    // fixedSize(vertical:) or the VStack compresses this to two
                    // lines and truncates the rest — which is how the first run
                    // of this probe reported a result nobody could read. A
                    // measuring instrument that hides the measurement is worse
                    // than no instrument, because it looks like it worked.
                    Text(report.transcript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(report.succeeded ? Color.green.opacity(0.12)
                                                     : Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(6)
        }
        .task { await probe.refresh() }
        // Returning from System Settings is the moment the answer changes, so
        // re-check then instead of polling on a timer.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await probe.refresh() }
        }
    }
}
