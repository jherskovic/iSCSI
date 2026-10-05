//
//  OtherCopies.swift
//  Setup step: no other copy of the app is registered with macOS.
//
//  LaunchServices registers the app inside a mounted disk image once it runs
//  from there, and keeps that registration after the image is ejected; build
//  products register too. Every other step checks presence, so a stray copy
//  slips past all of them — and launchd may start the daemon out of it, which
//  breaks every attach once that copy is gone (measured 2026-10-05,
//  docs/backend-a-fskit-notes.md). This step checks plurality.
//  See docs/superpowers/specs/2026-10-05-setup-repair-design.md.
//

import AppKit
import Foundation
import iSCSIKit

private let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework"
    + "/Frameworks/LaunchServices.framework/Support/lsregister"

@MainActor
final class OtherCopies: SetupStep {
    let id = "other-copies"
    let title = "No other copies registered"
    private(set) var state: StepState = .checking
    private var others: [RegisteredCopy] = []

    /// The dump's answer, kept for the launch: the coordinator re-checks
    /// every step after every action, and 2.3 s each time would be felt.
    /// Dropped after Clean up, the one action that changes it.
    private var dumped: [String]?
    /// The dump in flight, shared: launch and a return to the foreground can
    /// both start a check before the first dump is back.
    private var dumping: Task<[String], Never>?
    /// Copies Clean up has already tried to unregister.
    private var attempted: Set<String> = []

    /// How long a check waits for the dump. Idle it takes ~2.3 s; on a VM
    /// just after boot lsregister has run for minutes (FSKitSteps.swift), and
    /// every later step — and the user's sessions — wait on this one.
    private static let dumpWait: Duration = .seconds(10)

    func check() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "me.herko.iSCSIInitiator"
        // ~4 ms; LaunchServices' own answer, by bundle identifier.
        let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .map(\.path)
        // The fast query omits registrations whose bundle is gone (measured
        // 2026-10-05, docs/backend-a-fskit-notes.md); the dump sees them.
        let dump = await dumpedPaths()
        others = RegisteredCopies.others(registered: registered + (dump ?? []),
                                         running: Bundle.main.bundleURL.path,
                                         exists: { FileManager.default.fileExists(atPath: $0) })
        // A copy that is gone and survived Clean up is a record LaunchServices
        // will not drop. Attaching was measured not to depend on such records
        // (a stuck daemon does, and the daemon step owns that), so it must not
        // hold back every target and session for good.
        let stuck = others.filter { !$0.exists && attempted.contains($0.path) }
        let open = others.filter { !stuck.contains($0) }
        let pending = dump == nil ? " (the full LaunchServices scan is still running)" : ""
        if !open.isEmpty {
            state = .actionable(RegisteredCopies.summary(open, home: NSHomeDirectory()))
        } else if !stuck.isEmpty {
            let paths = stuck.map(\.path).joined(separator: "; ")
            let verb = stuck.count == 1 ? "exists" : "exist"
            state = .satisfied("only this copy can be used; macOS still lists \(paths), "
                               + "which no longer \(verb) and would not unregister" + pending)
        } else {
            state = .satisfied("only this copy is registered" + pending)
        }
    }

    /// The dump's paths, or nil if it is not back within `dumpWait`; it keeps
    /// running, and a later check picks up its answer.
    private func dumpedPaths() async -> [String]? {
        if let dumped { return dumped }
        let task = dumping ?? Task.detached { FSKitRegistrationAudit.registeredAppBundles() }
        dumping = task
        guard let paths = await Self.value(of: task, within: Self.dumpWait) else { return nil }
        // Only the current dump's answer is kept: one started before a Clean
        // up describes registrations that may be gone.
        if dumping == task {
            dumping = nil
            dumped = paths
        }
        return paths
    }

    /// `task`'s value, or nil after `limit`. Not a task group: a group waits
    /// for every child, and awaiting another task's value ignores cancellation.
    nonisolated private static func value(of task: Task<[String], Never>,
                                          within limit: Duration) async -> [String]? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(with: await task.value) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(with: nil)
            }
        }
    }

    var actionLabel: String? {
        guard case .actionable = state else { return nil }
        return "Clean up"
    }

    var consentTitle: String? { "Remove the other copies' registrations?" }

    var consentPrompt: String? {
        guard case .actionable = state else { return nil }
        return "This removes macOS's registration of the copies listed above so only "
            + "this one is used. It does not delete any files."
    }

    /// Unregister every other copy, then ask LaunchServices again rather than
    /// assume it worked — a copy that would not unregister stays listed.
    func perform() async {
        let paths = others.map(\.path)
        attempted.formUnion(paths)
        state = .checking
        // Off the main actor, like every subprocess the app waits on.
        await Task.detached {
            for path in paths { Self.unregister(path) }
        }.value
        dumped = nil
        dumping = nil
        await check()
    }

    nonisolated private static func unregister(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-u", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Nothing to do here: the re-check after this reports the copy as
            // still registered, which is the honest answer.
        }
    }
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String]?, Never>?

    init(_ continuation: CheckedContinuation<[String]?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: [String]?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
