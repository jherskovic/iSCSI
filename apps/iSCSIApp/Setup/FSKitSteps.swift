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

    /// Re-register the *app* with LaunchServices, not the appex with pluginkit.
    ///
    /// FSKit enumerates modules through LaunchServices/ExtensionKit, not through
    /// pluginkit's database, and the two can disagree. Measured: after a bundle
    /// was placed by something other than Finder, `pluginkit -a` added a record
    /// that `pluginkit -m -v` showed with a **(null)** version, and
    /// `FSClient.installedExtensions` ignored it completely — while `mount -F`
    /// worked fine, so nothing was actually broken except our ability to see it.
    /// `lsregister -f -R -trusted` restored the version and the record.
    ///
    /// A normal install cannot reach this state: dragging from the DMG makes
    /// Finder register the bundle properly. This is a repair for bundles placed
    /// by scripts, installers, or a restore.
    func perform() async {
        state = .checking
        var attempted: [String] = []

        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            attempted.append(run(lsregister, ["-f", "-R", "-trusted", Bundle.main.bundleURL.path]))
        } else {
            attempted.append("lsregister not present at the expected path")
        }

        // Registration propagates asynchronously; checking immediately reports
        // the previous answer and makes the button look inert.
        try? await Task.sleep(for: .seconds(2))
        await check()

        // If it still is not registered, say what was tried. A button that
        // changes nothing and explains nothing reads as broken — which is
        // exactly how the pluginkit-only version of this looked.
        if !state.isSatisfied {
            state = .blocked(
                "macOS still does not list the extension after re-registering. "
                + "Quitting and reopening the app usually settles it; if not, "
                + "drag the app out of Applications and back in. "
                + "(tried: \(attempted.joined(separator: "; ")))")
        }
    }

    private func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return "\((path as NSString).lastPathComponent) exited \(process.terminationStatus)"
        } catch {
            return "\((path as NSString).lastPathComponent) failed: \(error.localizedDescription)"
        }
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
        // Reached by selector so this builds against the macOS 26 SDK; see
        // FSKitSettingsLink. Returns false on macOS 26, where the API does not
        // exist, and the URL fallback below runs instead.
        if FSKitSettingsLink.open() { return }
        // Only reached on 26.x, where this is known not to navigate — kept so
        // the button does *something* rather than appearing dead. R7.
        for raw in ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                    "x-apple.systempreferences:"] {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
