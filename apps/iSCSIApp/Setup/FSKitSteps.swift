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
import os

/// `FSClient.installedExtensions`, retried briefly before an error is believed.
/// Enabling restarts the FSKit agent, and a check that lands in that window
/// fails with "Couldn't communicate with a helper application" (SIP-on VM,
/// 2026-10-05) — once in the middle of two that succeeded.
private func installedFSModules() async throws -> [FSModuleIdentity] {
    var lastError: Error?
    for attempt in 0 ..< 4 {
        if attempt > 0 { try? await Task.sleep(for: .milliseconds(750)) }
        do {
            return try await FSClient.shared.installedExtensions
        } catch {
            lastError = error
        }
    }
    throw lastError ?? CocoaError(.featureUnsupported)
}

/// Whether `mount -F` can use the module, asked by mounting the extension's
/// local test store and unmounting it (FSKitMountProbe). Consulted only when
/// FSKit's list leaves the module out — a list that can omit a module FSKit
/// loads without complaint (SIP-on VM, 2026-10-05), while attaching depends on
/// the mount alone. Shared by both FSKit steps so one check pass mounts once;
/// either step's action drops the answer.
@MainActor
final class FSKitAttachProbe {
    private var cached: (outcome: FSKitMountProbe.Outcome, at: ContinuousClock.Instant)?
    private static let maxAge: Duration = .seconds(15)
    private static let log = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "fskit-probe")

    func outcome() async -> FSKitMountProbe.Outcome {
        if let cached, ContinuousClock.now - cached.at < Self.maxAge { return cached.outcome }
        let outcome = await Task.detached { Self.probe() }.value
        Self.log.log("FSKit's list omits the module; test mount: \(String(describing: outcome), privacy: .public)")
        cached = (outcome, .now)
        return outcome
    }

    func invalidate() { cached = nil }

    nonisolated private static func probe() -> FSKitMountProbe.Outcome {
        let point = FileManager.default.temporaryDirectory
            .appendingPathComponent("fskit-probe-\(UUID().uuidString)").path
        guard mkdir(point, 0o700) == 0 else { return .failed("could not create \(point)") }
        // rmdir, never a recursive remove: if the unmount failed, the volume's
        // own file is in there.
        defer { rmdir(point) }
        let mounted = run("/sbin/mount", ["-F", "-t", "iSCSI", FSKitMountProbe.testURL, point])
        let outcome = FSKitMountProbe.classify(status: mounted.status, output: mounted.output)
        if outcome == .mounts, run("/sbin/umount", [point]).status != 0 {
            _ = run("/sbin/umount", ["-f", point])
        }
        return outcome
    }

    /// A subprocess with a deadline: `mount -F` waits on FSKit, and a wedged
    /// FSKit must cost a check pass 20 seconds, not the app.
    nonisolated private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        guard finished.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            return (-1, "\((path as NSString).lastPathComponent) did not finish within 20 s")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - D: registered

@MainActor
final class ModuleRegistration: SetupStep {
    let id = "module-registered"
    let title = "Filesystem extension registered"
    private(set) var state: StepState = .checking
    private let probe: FSKitAttachProbe

    init(probe: FSKitAttachProbe) { self.probe = probe }

    func check() async {
        do {
            let modules = try await installedFSModules()
            if modules.contains(where: { $0.bundleIdentifier == FSKitEnablement.moduleBundleID }) {
                state = .satisfied(FSKitEnablement.moduleBundleID)
                return
            }
            // Not on FSKit's list — which is not the same as not registered.
            switch await probe.outcome() {
            case .mounts, .disabled:
                state = .satisfied(
                    "\(FSKitEnablement.moduleBundleID) — macOS's list of extensions leaves "
                    + "it out, but FSKit loads it (checked with a local test mount)")
            case .notFound:
                state = .actionable(
                    "macOS has not registered the extension inside this app yet. "
                    + "This usually resolves itself a moment after the app is "
                    + "moved or launched; if it does not, registering explicitly "
                    + "fixes it.")
            case .failed(let why):
                state = .blocked("macOS's list of extensions leaves it out, and a local "
                                 + "test mount failed: \(why)")
            }
        } catch {
            state = .blocked("could not ask FSKit: \(error.localizedDescription)")
        }
    }

    /// Only when FSKit answered and did not list the module. Registering does
    /// nothing for an FSKit that will not answer, and right after Enable it
    /// re-registers the module — which invalidates the entry just written.
    var actionLabel: String? {
        guard case .actionable = state else { return nil }
        return "Register"
    }

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
        probe.invalidate()
        var attempted: [String] = []

        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            // Off the main actor: on a loaded machine lsregister runs for
            // minutes — measured past 2.5 on a VM just after boot (2026-10-04)
            // — and waiting for it here froze the whole window.
            let bundlePath = Bundle.main.bundleURL.path
            attempted.append(await Task.detached {
                Self.run(lsregister, ["-f", "-R", "-trusted", bundlePath])
            }.value)
        } else {
            attempted.append("lsregister not present at the expected path")
        }

        // Remove any other bundle claiming to provide this module. More than
        // one and `mount -F` cannot resolve the short name, which surfaces as
        // "File system named iSCSI not found" — indistinguishable from not
        // being installed, and reported as healthy by every presence check.
        // They accumulate from old builds and from disk images left mounted.
        let pruned = await Task.detached { FSKitRegistrationAudit.pruneDuplicates() }.value
        if !pruned.isEmpty {
            attempted.append("removed \(pruned.count) duplicate registration(s)")
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

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String {
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
    private let probe: FSKitAttachProbe

    init(probe: FSKitAttachProbe) { self.probe = probe }

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

    /// What restarting fskitd would disconnect, as of the last check: every
    /// FSKit volume on the Mac, in every account (docs/open-questions.md item
    /// 14). Non-empty means Enable must not restart it.
    private var inTheWay: [MountTableEntry] = []
    /// This app session put the extension on macOS's list but left fskitd
    /// alone because something was mounted, so a restart of the Mac finishes
    /// the job. Remembered rather than read back: the list lives in another
    /// app's container, and reading it is what the consent dialog is for.
    private var waitingForMacRestart = false
    /// Why the last Enable could not restart fskitd, kept until the next one:
    /// the coordinator re-checks every step as soon as an action returns, and
    /// a failure set only in `perform` was replaced before anyone could read it.
    private var lastRestartFailure: String?

    func check() async {
        do {
            let modules = try await installedFSModules()
            guard let mine = modules.first(where: {
                $0.bundleIdentifier == FSKitEnablement.moduleBundleID
            }) else {
                // Off FSKit's list: a local test mount says what the list cannot.
                switch await probe.outcome() {
                case .mounts:
                    enabled("enabled (checked with a local test mount; macOS's "
                            + "list of extensions leaves it out)")
                case .disabled:
                    state = notEnabled()
                case .notFound:
                    state = .blocked("the extension is not registered yet — "
                                     + "that step has to pass first")
                case .failed(let why):
                    state = .blocked("could not tell whether it is enabled: a local test "
                                     + "mount failed: \(why)")
                }
                return
            }
            if mine.isEnabled { enabled("enabled") } else { state = notEnabled() }
        } catch {
            state = .blocked("could not ask FSKit: \(error.localizedDescription)")
        }
    }

    private func enabled(_ evidence: String) {
        waitingForMacRestart = false
        lastRestartFailure = nil
        inTheWay = []
        state = .satisfied(evidence)
    }

    /// Every line this step shows while the extension is off. All of it comes
    /// from here, because `check()` runs after every action and is the only
    /// text that stays on screen.
    private func notEnabled() -> StepState {
        if Self.switchWorks {
            return .actionable(
                "macOS needs your permission to run the filesystem "
                + "extension. Turn on “iSCSI/NVMe/TCP Initiator” under File System "
                + "Extensions.")
        }
        inTheWay = FSKitRestart.mountsItWouldDisconnect(AttachmentManager.mountTable())
        if !inTheWay.isEmpty {
            let what = inTheWay.map(FSKitRestart.describe).joined(separator: "; ")
            if waitingForMacRestart {
                return .blocked(
                    "It is on macOS's list of enabled extensions, and turns on the next "
                    + "time the system service that reads the list restarts — at the latest "
                    + "when this Mac restarts. Turning it on now would restart that service and "
                    + "disconnect what is mounted through it, in every account: \(what). "
                    + "To turn it on without restarting the Mac, detach those, then "
                    + "choose Re-check.")
            }
            return .actionable(
                "Turning it on means restarting a system service, which would disconnect "
                + "what is mounted through it on this Mac, in every account: \(what). "
                + "Detach those, then choose Re-check — or choose Enable at Next Restart "
                + "and restart this Mac.")
        }
        if let lastRestartFailure {
            return .actionable(
                "It is on macOS's list, but the system service that reads the list could "
                + "not be restarted: \(lastRestartFailure). Choose Enable to try again, "
                + "or restart this Mac.")
        }
        return .actionable(
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) "
            + "has a bug that leaves the File System Extensions switch "
            + "stuck off for third-party extensions, so it has to be "
            + "enabled another way.")
    }

    var actionLabel: String? {
        guard !state.isSatisfied else { return nil }
        if Self.switchWorks { return "Open System Settings" }
        if inTheWay.isEmpty { return "Enable" }
        return waitingForMacRestart ? nil : "Enable at Next Restart"
    }

    var consentTitle: String? { "Enable the filesystem extension?" }

    var consentPrompt: String? {
        guard !state.isSatisfied, !Self.switchWorks else { return nil }
        if !inTheWay.isEmpty {
            return """
                iSCSI/NVMe/TCP Initiator will add its filesystem extension to the list macOS \
                keeps of enabled extensions, at

                ~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist

                Nothing else on that list is changed, and nothing is restarted now, \
                so nothing mounted is disconnected. The extension turns on the next \
                time the service that reads the list restarts — at the latest when \
                this Mac restarts.

                This is normally done by the switch in System Settings, but that \
                switch does not work on this version of macOS.
                """
        }
        return """
            iSCSI/NVMe/TCP Initiator will add its filesystem extension to the list macOS \
            keeps of enabled extensions, at

            ~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist

            and then restart the system service that reads it. Nothing else on \
            that list is changed.

            Restarting that service disconnects everything mounted through it, \
            in every account on this Mac — this app's volumes, and on this \
            version of macOS also FAT and exFAT drives. Nothing like that is \
            mounted right now; if something is by the time you confirm, the \
            restart is skipped and you will be told what is in the way.

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
        probe.invalidate()
        lastRestartFailure = nil
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
        //
        // Not while anything FSKit serves is mounted, in any account: the
        // restart takes every such volume down mid-write (docs/open-questions.md
        // item 14). Read again here, not trusted from the last check — the
        // consent dialog may have sat open while something attached. The
        // daemon refuses too. The entry stays written, so restarting the Mac
        // turns the extension on without disconnecting anything.
        if !FSKitRestart.mountsItWouldDisconnect(AttachmentManager.mountTable()).isEmpty {
            waitingForMacRestart = true
            await check()
            return
        }
        do {
            try await DaemonConnection.refreshFSKitEnablement()
        } catch {
            let ns = error as NSError
            lastRestartFailure = [ns.localizedDescription, ns.localizedRecoverySuggestion]
                .compactMap { $0 }.joined(separator: " ")
        }
        await check()
    }

    private func openSettings() {
        // macOS 27's own link to the switch. The app builds against the 27
        // SDK, so this is a direct, availability-gated call.
        if #available(macOS 27, *), FSClient.shared.openFileSystemExtensionsSettings() { return }
        // macOS 26.x, or a refusal: the URL scheme, known not to navigate on
        // 26 — kept so the button does *something* rather than appearing dead.
        for raw in ["x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                    "x-apple.systempreferences:"] {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}
