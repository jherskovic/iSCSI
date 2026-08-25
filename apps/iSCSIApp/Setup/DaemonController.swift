//
//  DaemonController.swift
//  Setup step C: the daemon is registered, approved, and answering — three
//  conditions with three different user remedies. `SMAppService.status`
//  cannot tell "unapproved" from "approved but crashing" (`.enabled` only
//  means launchd is willing to start the job), so the check is status *plus*
//  an XPC round trip. See docs/daemon-registration.md.
//

import Foundation
import os
import ServiceManagement
import SwiftUI
import iSCSIKit

enum DaemonState: Equatable {
    case checking
    /// Never registered, or unregistered. The button is the answer.
    case notRegistered
    /// Registered; launchd is waiting for an admin to approve it in System
    /// Settings. Nothing happens until they do.
    case requiresApproval
    /// launchd says enabled but nothing answers XPC. Approved and broken.
    case registeredNotResponding
    case running(DaemonInfo)
    /// Answering, but it is not the build this app shipped with — the usual
    /// cause is an update that replaced the executable without re-registering.
    case versionMismatch(daemon: String, app: String)
    /// The plist is not in the bundle at all. A packaging bug, not a user problem.
    case notFound
    case failed(String)

    var isReady: Bool { if case .running = self { return true }; return false }

    var summary: String {
        switch self {
        case .checking:                return "checking…"
        case .notRegistered:           return "not installed"
        case .requiresApproval:        return "waiting for approval in System Settings"
        case .registeredNotResponding: return "approved, but not answering — the daemon is not running"
        case .running(let info):       return "running \(info.version) (\(info.build)), pid \(info.pid)"
        case .versionMismatch(let d, let a):
            return "running \(d) but this app is \(a) — needs re-registering"
        case .notFound:
            return "the LaunchDaemon plist is missing from the app bundle (packaging bug)"
        case .failed(let why):         return "failed: \(why)"
        }
    }

    var color: Color {
        switch self {
        case .running:                            return .green
        case .requiresApproval, .versionMismatch: return .orange
        case .checking:                           return .secondary
        default:                                  return .red
        }
    }
}

@MainActor
final class DaemonController: ObservableObject {
    /// SMAppService resolves the service by plist *filename*; this must match
    /// the file in Contents/Library/LaunchDaemons byte for byte (release.sh
    /// asserts Label == filename, the other half of the contract).
    static let plistName = "me.herko.iSCSIInitiator.daemon.plist"

    @Published private(set) var state: DaemonState = .checking
    /// Raw error domains/codes for the probe UI.
    @Published private(set) var detail: String = ""

    private var service: SMAppService { .daemon(plistName: Self.plistName) }

    /// Every state change is logged with its cause — SMAppService's own
    /// logging reports only a status integer.
    private static let log = Logger(subsystem: "me.herko.iSCSIInitiator.app",
                                    category: "daemon")

    private func transition(to next: DaemonState, _ why: String) {
        if next != state {
            Self.log.log("state \(String(describing: self.state), privacy: .public) -> \(String(describing: next), privacy: .public): \(why, privacy: .public)")
        }
        state = next
        detail = why
    }

    /// Checked on disk rather than inferred from `.notFound`, which is also
    /// the ordinary never-registered state.
    static var bundledPlistExists: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(plistName).path)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// Both halves, not just the marketing version: `build` tells two builds
    /// of one version apart, and Apple says to re-register whenever the
    /// *executable* changes.
    private func versionLabel(_ version: String, _ build: String) -> String {
        "\(version) (\(build))"
    }

    // MARK: - Checking

    func refresh() async {
        let status = service.status
        switch status {
        case .notRegistered:
            transition(to: .notRegistered, "SMAppService.status = notRegistered")
        case .requiresApproval:
            transition(to: .requiresApproval, "SMAppService.status = requiresApproval")
        case .notFound:
            // A never-registered service reports .notFound; it is the
            // ordinary starting state, not a defect — unless the plist really
            // is absent from the bundle.
            transition(to: Self.bundledPlistExists ? .notRegistered : .notFound,
                       "SMAppService.status = notFound; bundled plist "
                       + (Self.bundledPlistExists ? "present (never registered yet)"
                                                  : "MISSING from the bundle"))
        case .enabled:
            detail = "SMAppService.status = enabled; probing XPC"
            await probe()
        @unknown default:
            transition(to: .failed("unknown SMAppService.status (\(status.rawValue))"),
                       "unknown SMAppService.status \(status.rawValue)")
        }
    }

    /// launchd says the job is enabled. Ask the daemon itself.
    private func probe() async {
        do {
            let info = try await DaemonConnection.info()
            let matches = info.version == appVersion && info.build == appBuild
            transition(to: matches
                       ? .running(info)
                       : .versionMismatch(daemon: versionLabel(info.version, info.build),
                                          app: versionLabel(appVersion, appBuild)),
                       "daemonInfo: version=\(info.version) build=\(info.build) "
                       + "pid=\(info.pid) app=\(versionLabel(appVersion, appBuild)) "
                       + "relaxedAuth=\(info.authorizationRelaxed)")
        } catch {
            transition(to: .registeredNotResponding,
                       "daemonInfo failed: \(Self.describe(error))")
        }
    }

    // MARK: - Acting

    /// Register, retrying while the system says nothing was recorded.
    ///
    /// `register()` throws EPERM in two unrelated situations needing opposite
    /// responses: recorded-but-unapproved (`.status == requiresApproval` —
    /// stop and point at System Settings) and a previous `unregister()` that
    /// launchd has not finished with (`.status == notRegistered` — only
    /// *calling register again* helps; polling `.status` waits on a result
    /// that does not exist). See docs/daemon-registration.md.
    func register() async {
        state = .checking
        var lastError: NSError?

        // launchd can take >1 s to let go of an old job; the unapproved case
        // returns immediately via the status check, so extra attempts are free.
        for attempt in 1 ... 8 {
            do {
                Self.log.log("register() calling (attempt \(attempt, privacy: .public))")
                try service.register()
                Self.log.log("register() returned without throwing")
                detail = "register() succeeded"
                await settle()
                return
            } catch let error as NSError where error.code == kSMErrorAlreadyRegistered {
                // The state we wanted, reached earlier. Not a failure.
                Self.log.log("register(): already registered")
                detail = "already registered"
                await settle()
                return
            } catch let error as NSError {
                lastError = error
                Self.log.log("register() threw \(Self.describe(error), privacy: .public) on attempt \(attempt, privacy: .public)")

                // Did it record the job despite throwing?
                await refresh()
                guard case .notRegistered = state else {
                    // Something was recorded — approval pending, or already
                    // running. Let the normal path report it.
                    await settle()
                    return
                }

                if attempt < 8 {
                    // Capped so eight attempts stay inside ~6 s.
                    try? await Task.sleep(for: .milliseconds(min(400 * attempt, 1000)))
                }
            }
        }

        if let lastError {
            transition(to: Self.mapRegisterError(lastError),
                       "register() never took: \(Self.describe(lastError))")
        }
    }

    /// Refresh until the answer stops changing, or a deadline passes:
    /// `register()` returns before launchd has recorded the job, and the
    /// daemon needs a moment before it answers XPC. Only `notRegistered` and
    /// `registeredNotResponding` mean "not yet" as often as "no"; everything
    /// else — `requiresApproval` included — is a real answer reported
    /// immediately.
    private func settle(within deadline: Duration = .seconds(6)) async {
        let clock = ContinuousClock()
        let started = clock.now
        var rounds = 0
        while true {
            await refresh()
            rounds += 1
            switch state {
            case .notRegistered, .registeredNotResponding:
                guard clock.now - started < deadline else {
                    Self.log.error("settle gave up after \(rounds, privacy: .public) rounds in \(String(describing: self.state), privacy: .public)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            default:
                Self.log.log("settle done after \(rounds, privacy: .public) rounds: \(String(describing: self.state), privacy: .public)")
                return
            }
        }
    }

    /// Apple requires re-registering whenever the plist or executable changes,
    /// with an unregister first. The async unregister — unlike the throwing
    /// one — waits for the old process to die; re-registering before that
    /// yields a registration pointing at a daemon that never comes back.
    func reregister() async {
        state = .checking
        detail = "unregistering before re-registering (the executable changed)"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            service.unregister { error in
                if let error = error as NSError?, error.code != kSMErrorJobNotFound {
                    Task { @MainActor in self.detail = "unregister: \(Self.describe(error))" }
                }
                continuation.resume()
            }
        }
        await register()
    }

    func unregister() async {
        state = .checking
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            service.unregister { error in
                Task { @MainActor in
                    self.detail = error.map { "unregister: \(Self.describe($0))" }
                        ?? "unregister() succeeded"
                }
                continuation.resume()
            }
        }
        await refresh()
    }

    func openLoginItemsSettings() {
        // A real API, unlike the FSKit pane (docs/backend-a-fskit-notes.md).
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Errors

    private static func mapRegisterError(_ error: NSError) -> DaemonState {
        switch error.code {
        case kSMErrorLaunchDeniedByUser:
            return .requiresApproval
        case kSMErrorInvalidSignature:
            return .failed("the app's code signature is not valid for this. "
                           + "Reinstall by dragging from the DMG.")
        case kSMErrorJobPlistNotFound, kSMErrorInvalidPlist:
            return .notFound
        default:
            return .failed(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var out = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            out += " [underlying \(underlying.domain) \(underlying.code)]"
        }
        return out
    }
}

// MARK: - The XPC round trip

/// One-shot connections: everything the setup flow asks is a liveness
/// question, and a stale cached connection answers wrongly toward success.
enum DaemonConnection {
    struct Unreachable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Ask the daemon to make `fskitd` re-read the enabled-modules list.
    /// Only used on the macOS 26.x branch of setup step E.
    static func refreshFSKitEnablement() async throws {
        try await call { proxy, finish in
            proxy.refreshFSKitEnablement { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    static func info() async throws -> DaemonInfo {
        try await call { proxy, finish in
            proxy.daemonInfo { data, error in
                if let error {
                    finish(.failure(error))
                } else if let data {
                    finish(Result { try JSONDecoder().decode(DaemonInfo.self, from: data) })
                } else {
                    finish(.failure(Unreachable(reason: "the daemon replied with nothing")))
                }
            }
        }
    }

    /// Open a connection, hand the proxy to `body`, and bridge the reply
    /// block / error handler into one continuation. NSXPC guarantees neither
    /// exactly-one nor at-least-one if the peer dies mid-call, so this guards
    /// against resuming twice (a crash) and never resuming (a frozen screen).
    // Not private: DaemonClient.swift builds the rest of the surface on it.
    static func call<T: Sendable>(
        _ body: @escaping @Sendable (ISCSIDaemonProtocol,
                                     @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        // NSXPCConnection is documented thread-safe but not annotated
        // Sendable, and the handlers genuinely run on arbitrary queues — the
        // case nonisolated(unsafe) exists for.
        nonisolated(unsafe) let connection = NSXPCConnection(
            machServiceName: iscsiDaemonServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ISCSIDaemonProtocol.self)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                @Sendable func finish(_ result: Result<T, any Error>) {
                    let already = resumed.withLock { was -> Bool in
                        defer { was = true }
                        return was
                    }
                    guard !already else { return }
                    connection.invalidate()
                    continuation.resume(with: result)
                }

                connection.invalidationHandler = {
                    finish(.failure(Unreachable(reason: "the daemon is not running")))
                }
                connection.interruptionHandler = {
                    finish(.failure(Unreachable(reason: "the daemon stopped mid-call")))
                }
                connection.resume()

                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    finish(.failure(error))
                }) as? ISCSIDaemonProtocol else {
                    finish(.failure(Unreachable(reason: "the daemon does not implement the protocol")))
                    return
                }
                body(proxy, finish)
            }
        } onCancel: {
            connection.invalidate()
        }
    }
}

// MARK: - Probe UI

/// Instrumentation, not product UI: shows the raw SMAppService errors the
/// setup sheet summarises away.
struct DaemonPanelView: View {
    @StateObject private var daemon = DaemonController()

    var body: some View {
        GroupBox("Daemon (SMAppService)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(daemon.state.color).frame(width: 10, height: 10)
                    Text(daemon.state.summary)
                    Spacer()
                    Button("Re-check") { Task { await daemon.refresh() } }
                }

                HStack(spacing: 8) {
                    Button("Register") { Task { await daemon.register() } }
                    Button("Re-register") { Task { await daemon.reregister() } }
                    Button("Unregister") { Task { await daemon.unregister() } }
                    Spacer()
                    // Only offered when it is the actual next step.
                    if daemon.state == .requiresApproval {
                        Button("Open Login Items…") { daemon.openLoginItemsSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if !daemon.detail.isEmpty {
                    Text(daemon.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)
                }

                if case .running(let info) = daemon.state, info.authorizationRelaxed {
                    Text("This daemon was built with DEBUG and accepts XPC connections "
                         + "from any process. Never ship it.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(6)
        }
        .task { await daemon.refresh() }
        // Returning from System Settings is when the approval state changes.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await daemon.refresh() }
        }
    }
}
