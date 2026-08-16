//
//  DaemonController.swift
//  Setup step C: the daemon is registered, approved, and answering.
//
//  Three separate conditions, and the reason this file is longer than a Bool is
//  that they fail in ways the user has to respond to differently:
//
//    not registered          -> press the button
//    registered, unapproved  -> go to System Settings and switch it on
//    approved, not answering -> the daemon is crashing; reinstall or file a bug
//
//  `SMAppService.status` cannot tell the last two apart. `.enabled` means only
//  that launchd is willing to start the job — not that it started, not that it
//  stayed up, and not that it is the build we shipped. So the check is
//  status *plus* an XPC round trip, and "approved but crashlooping" gets its own
//  state rather than being reported as success.
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
    /// SMAppService resolves the service by the *filename* of the plist, so
    /// this string includes the extension and must match the file in
    /// Contents/Library/LaunchDaemons byte for byte. release.sh asserts that
    /// the shipped plist's Label matches its filename; this is the other half.
    static let plistName = "me.herko.iSCSIInitiator.daemon.plist"

    @Published private(set) var state: DaemonState = .checking
    /// Raw detail for the probe UI — error domains and codes, kept because the
    /// interesting failures here are ones nobody has seen yet.
    @Published private(set) var detail: String = ""

    private var service: SMAppService { .daemon(plistName: Self.plistName) }

    /// Every state change, with the detail that produced it.
    ///
    /// Added after a reinstall that needed two clicks could not be diagnosed
    /// from outside: Apple's own SMAppService logging reports a status integer
    /// and nothing about what this class concluded from it, so working out
    /// which of six states the screen was showing meant guessing. The same
    /// lesson as the filesystem extension — instrument rather than infer.
    private static let log = Logger(subsystem: "me.herko.iSCSIInitiator.app",
                                    category: "daemon")

    private func transition(to next: DaemonState, _ why: String) {
        if next != state {
            Self.log.log("state \(String(describing: self.state), privacy: .public) -> \(String(describing: next), privacy: .public): \(why, privacy: .public)")
        }
        state = next
        detail = why
    }

    /// Whether the plist SMAppService is being asked about is actually in the
    /// bundle. The reason to check rather than infer: `.notFound` was assumed to
    /// mean "the plist is missing" and told the user their app was incomplete,
    /// on a machine where the plist was demonstrably present. Look at the disk.
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

    /// How the running daemon identifies itself, for comparison against the app.
    ///
    /// Both halves, not just the marketing version. `DaemonInfo.build` exists
    /// precisely "to tell two builds of the same marketing version apart" — its
    /// own words — and the check ignored it, so shipping a changed `iscsid`
    /// under an unchanged version number left the old daemon running and
    /// nothing reported a problem. Apple's guidance is to re-register whenever
    /// the executable changes, which is a statement about the binary, not about
    /// what the release was called.
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
            // Measured on a clean machine: a service that has never been
            // registered reports .notFound and has no Background Task
            // Management record at all, while .notRegistered is what you get
            // after registering and then unregistering. So .notFound is the
            // ordinary starting state, not a defect — unless the plist really
            // is absent, which is the one case worth alarming about.
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
    /// `register()` throws EPERM (SMAppServiceErrorDomain 1) in two unrelated
    /// situations, and they need opposite responses:
    ///
    ///   * The daemon is recorded but unapproved. `.status` is then
    ///     `requiresApproval` and the user has somewhere to go. Retrying is
    ///     pointless and would delay telling them.
    ///   * A previous `unregister()` has not finished. `.status` is
    ///     `notRegistered` and nothing was recorded at all. Only asking again
    ///     helps.
    ///
    /// The second is what made every reinstall take two clicks. Measured:
    ///
    ///     11:08:41.582  register() calling
    ///     11:08:41.603  state checking -> notRegistered
    ///     11:08:47.858  settle gave up after 24 rounds in notRegistered
    ///                   failed("SMAppServiceErrorDomain 1 ... not permitted")
    ///     11:09:15.346  register() returned without throwing   [second click]
    ///     11:09:15.415  running(build 19, pid 70587)
    ///
    /// The first attempt threw, the second did not. Polling `.status` after a
    /// failed register — which is what the previous fix did, 24 times over six
    /// seconds — cannot help, because there is no pending result to wait for.
    /// The user's second click was not confirming anything; it was doing the
    /// work. So do it here.
    ///
    /// `unregister()` waits for the daemon process to die, and that is
    /// evidently not the same as launchd having finished with the job.
    func register() async {
        state = .checking
        var lastError: NSError?

        for attempt in 1 ... 5 {
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

                // Did it record the job despite throwing? One cheap look, not
                // the full settle: the answer here is immediate either way.
                await refresh()
                guard case .notRegistered = state else {
                    // Something was recorded — approval pending, or already
                    // running. Let the normal path report it.
                    await settle()
                    return
                }

                if attempt < 5 {
                    try? await Task.sleep(for: .milliseconds(400 * attempt))
                }
            }
        }

        if let lastError {
            transition(to: Self.mapRegisterError(lastError),
                       "register() never took: \(Self.describe(lastError))")
        }
    }

    /// Refresh until the answer stops changing, or a deadline passes.
    ///
    /// `SMAppService.register()` returns before launchd has finished recording
    /// the job, and the daemon it starts needs a moment more before it answers
    /// XPC. Asking once, immediately, catches that gap and reports
    /// `notRegistered` — so the button relabelled itself from "Reinstall" to
    /// "Install" and the user had to press it a second time to see the state
    /// that was already on its way. Every update did this.
    ///
    /// `notRegistered` and `registeredNotResponding` are the two answers that
    /// mean "not yet" as often as they mean "no", so those are the ones worth
    /// waiting on. Everything else is a real answer, including
    /// `requiresApproval`: the user has somewhere to go and should be told
    /// immediately rather than after five seconds of nothing.
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

    /// Apple's header: "If an app updates either the plist or the executable
    /// for a LaunchAgent or LaunchDaemon, the SMAppService must be re-registered
    /// or it may not launch. It is recommended to also call unregister before
    /// re-registering if the executable has been changed."
    ///
    /// Uses the async unregister, which — unlike the throwing one — waits for
    /// the running process to actually be killed. Re-registering before the old
    /// process is reaped is how you get a registration that points at a daemon
    /// which never comes back.
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
        // A real API, unlike the FSKit pane — see the R7 note in
        // docs/backend-a-fskit-notes.md. No URL-scheme guessing needed here.
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

/// One-shot connections rather than a long-lived one, because everything the
/// setup flow asks is a liveness question: a cached connection that has gone
/// stale answers wrongly, and in the direction that looks like success.
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

    /// Open a connection, hand the proxy to `body`, and bridge whichever of the
    /// reply block or the error handler fires into one continuation.
    ///
    /// NSXPC calls exactly one of those in the ordinary cases but guarantees
    /// neither if the peer dies mid-call, so this guards against resuming twice
    /// (a crash) and, via the invalidation handler, against never resuming at
    /// all (a hang the user experiences as a frozen setup screen).
    // Not private: DaemonClient.swift builds the rest of the surface on it.
    static func call<T: Sendable>(
        _ body: @escaping @Sendable (ISCSIDaemonProtocol,
                                     @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        // NSXPCConnection's methods are documented as callable from any thread,
        // but the class is not annotated Sendable — and the paths that have to
        // invalidate it (the reply block, the error handler, the invalidation
        // and interruption handlers) genuinely do run on arbitrary queues. This
        // is the case nonisolated(unsafe) exists for: the safety argument is
        // Apple's documentation, not the compiler's inference.
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

/// M2 instrumentation, not product UI. The shipping version of this is a step
/// in the setup sheet; this exists to answer R4 — whether SMAppService.register()
/// refuses a build that is not notarized — and to show the raw error when it does.
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
                    // Only offered when it is the actual next step. A button
                    // that opens System Settings when System Settings is not
                    // where the problem is teaches the user to ignore it.
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
