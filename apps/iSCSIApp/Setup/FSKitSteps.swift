//
//  FSKitSteps.swift
//  Setup steps D and E: the filesystem module is registered, and enabled.
//
//  Two separate conditions that are easy to conflate. Registration is
//  LaunchServices knowing the .appex exists; enablement is the user (or, on
//  26.x, us) having consented to it running. A module can be registered and
//  disabled forever, which is exactly the state every install starts in.
//

import AppKit
import Foundation
import FSKit
import iSCSIKit

// MARK: - D: registered

@MainActor
final class ModuleRegistration: SetupStep {
    let id = "module-registered"
    let title = "Filesystem extension registered"
    private(set) var state: StepState = .checking

    func check() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            if modules.contains(where: { $0.bundleIdentifier == FSKitEnablement.moduleBundleID }) {
                state = .satisfied(FSKitEnablement.moduleBundleID)
            } else {
                state = .actionable(
                    "macOS has not registered the extension inside this app yet. "
                    + "This usually resolves itself a moment after the app is "
                    + "moved or launched; if it does not, registering explicitly "
                    + "fixes it.")
            }
        } catch {
            state = .blocked("could not ask FSKit: \(error.localizedDescription)")
        }
    }

    var actionLabel: String? { state.isSatisfied ? nil : "Register" }

    /// `pluginkit -a` on the embedded appex. LaunchServices normally does this
    /// on its own when the bundle lands in /Applications, so this is a repair
    /// for the case where it did not — most often after an in-place bundle
    /// replacement, which drops the registration.
    func perform() async {
        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/iSCSIFSExtension.appex")
        let pluginkit = Process()
        pluginkit.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        pluginkit.arguments = ["-a", appex.path]
        try? pluginkit.run()
        pluginkit.waitUntilExit()
        // Registration is asynchronous on the LaunchServices side; a check
        // fired immediately would report the old answer.
        try? await Task.sleep(for: .seconds(1))
        await check()
    }
}

// MARK: - E: enabled

@MainActor
final class ModuleEnablement: SetupStep {
    let id = "module-enabled"
    let title = "Filesystem extension enabled"
    private(set) var state: StepState = .checking

    /// The branch, decided at runtime and never at compile time.
    ///
    /// On macOS 27 the System Settings switch works, and it is the supported,
    /// consent-respecting path. On 26.x it is present but refuses to move, and
    /// `x-apple.systempreferences:` will not even navigate to the pane, so
    /// there is nothing to send the user to — the app has to do the work.
    /// Measured on both, see docs/backend-a-fskit-notes.md.
    ///
    /// Keyed on the running OS rather than the SDK: the same binary has to do
    /// the right thing on both.
    static var switchWorks: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    func check() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            guard let mine = modules.first(where: {
                $0.bundleIdentifier == FSKitEnablement.moduleBundleID
            }) else {
                state = .blocked("the extension is not registered yet — "
                                 + "that step has to pass first")
                return
            }
            if mine.isEnabled {
                state = .satisfied("enabled")
            } else if Self.switchWorks {
                state = .actionable(
                    "macOS needs your permission to run the filesystem "
                    + "extension. Turn on “iSCSI Initiator” under File System "
                    + "Extensions.")
            } else {
                state = .actionable(
                    "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) "
                    + "has a bug that leaves the File System Extensions switch "
                    + "stuck off for third-party extensions, so it has to be "
                    + "enabled another way.")
            }
        } catch {
            state = .blocked("could not ask FSKit: \(error.localizedDescription)")
        }
    }

    var actionLabel: String? {
        guard !state.isSatisfied else { return nil }
        return Self.switchWorks ? "Open System Settings" : "Enable"
    }

    var consentPrompt: String? {
        guard !state.isSatisfied, !Self.switchWorks else { return nil }
        return """
            iSCSI Initiator will add its filesystem extension to the list macOS \
            keeps of enabled extensions, at

            ~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist

            and then restart the system service that reads it. Nothing else on \
            that list is changed.

            This is normally done by the switch in System Settings, but that \
            switch does not work on this version of macOS.
            """
    }

    func perform() async {
        if Self.switchWorks {
            openSettings()
            return
        }

        state = .checking
        let report = await Task.detached { FSKitEnablement.enableModule() }.value
        guard report.succeeded else {
            state = .blocked("could not enable it: \(report.failure ?? "unknown"). "
                             + report.transcript)
            return
        }

        // The write alone changes nothing until fskitd re-reads the file, and
        // that needs root — hence the daemon. If the daemon is not up yet this
        // fails, which is why the coordinator orders the daemon step before
        // this one.
        do {
            try await DaemonConnection.refreshFSKitEnablement()
        } catch {
            state = .blocked(
                "the extension is on the list, but the system service could not "
                + "be restarted to notice: \(error.localizedDescription). "
                + "Restarting your Mac will also do it.")
            return
        }
        await check()
    }

    private func openSettings() {
        if #available(macOS 27, *), FSClient.shared.openFileSystemExtensionsSettings() {
            return
        }
        // Only reached on 26.x, where this is known not to navigate — kept so
        // the button does *something* rather than appearing dead. R7.
        for raw in ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                    "x-apple.systempreferences:"] {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
