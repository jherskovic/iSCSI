//
//  Uninstaller.swift
//  Taking everything back out, in the only order that works.
//
//  **The order is load-bearing.** Each step needs the previous one to still be
//  possible, and getting it wrong does not fail loudly — it leaves something
//  behind that nothing can reach any more:
//
//    1. Detach every volume.       A mounted volume whose app is gone cannot be
//                                  taken down by anything the user can find.
//    2. Delete secrets and data.   Both live in the *daemon's* context. After
//                                  step 3 the app cannot reach the keychain
//                                  items, and they would outlive the app with
//                                  nothing left that knows their names.
//    3. Unregister the daemon.     Only now, because steps 1 and 2 need it.
//    4. Disable and unregister the filesystem extension, in the user's context.
//    5. Remove the cache directory with rmdir.
//    6. Ask the user to move the app to the Trash.
//
//  Every step reports rather than throwing, because a failure partway through
//  must not strand the user midway: the remaining steps still run, and the
//  screen says exactly what was and was not removed.
//

import AppKit
import Foundation
import ServiceManagement
import iSCSIKit

@MainActor
final class Uninstaller: ObservableObject {
    struct Step: Identifiable {
        let id = UUID()
        let label: String
        var outcome: Outcome
    }

    enum Outcome: Equatable {
        case pending
        case running
        case done(String)
        /// Not fatal — later steps still run, because a partial uninstall that
        /// stops at the first problem is worse than one that finishes and says
        /// what it could not do.
        case failed(String)
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false

    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func run() async {
        isRunning = true
        finished = false
        steps = [
            Step(label: "Detach volumes", outcome: .pending),
            Step(label: "Delete saved targets and passwords", outcome: .pending),
            Step(label: "Remove the background service", outcome: .pending),
            Step(label: "Turn off the filesystem extension", outcome: .pending),
            Step(label: "Clean up", outcome: .pending),
        ]

        await step(0) { try await self.detachEverything() }
        await step(1) { try await self.removeDaemonData() }
        await step(2) { try await self.unregisterDaemon() }
        await step(3) { try await self.disableExtension() }
        await step(4) { try await self.cleanCaches() }

        isRunning = false
        finished = true
    }

    private func step(_ index: Int, _ work: @escaping () async throws -> String) async {
        steps[index].outcome = .running
        do {
            steps[index].outcome = .done(try await work())
        } catch {
            steps[index].outcome = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    /// Refuses if a volume is busy rather than forcing it.
    ///
    /// A forced unmount of a volume someone is writing to loses data, and
    /// "uninstall the app" is never worth that. Better to stop and say which
    /// volume is in use.
    private func detachEverything() async throws -> String {
        let attached = model.attachments.attachments
        guard !attached.isEmpty else { return "nothing was attached" }

        var detached = 0
        var busy: [String] = []
        for attachment in attached {
            do {
                try await model.attachments.detach(tag: attachment.tag)
                detached += 1
            } catch {
                busy.append(attachment.volumePaths.first ?? attachment.hiddenPath)
            }
        }
        if !busy.isEmpty {
            throw UninstallError.volumesBusy(busy)
        }
        return "detached \(detached)"
    }

    private func removeDaemonData() async throws -> String {
        try await DaemonConnection.removeAllData()
        return "removed"
    }

    private func unregisterDaemon() async throws -> String {
        let service = SMAppService.daemon(plistName: DaemonController.plistName)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The async form, which waits for the process to actually die. The
            // throwing one returns before it is reaped, and the next step would
            // race a daemon that is still running.
            service.unregister { _ in continuation.resume() }
        }
        // Trust the system's answer rather than the absence of an error.
        let status = service.status
        guard status == .notRegistered || status == .notFound else {
            throw UninstallError.daemonStillRegistered(status)
        }
        return "unregistered"
    }

    /// Undo what setup step E did, in the user's context — the only place it can
    /// be done, since the enabled-modules list is per-user.
    private func disableExtension() async throws -> String {
        var removed = false
        let (container, _) = FSKitEnablement.locateContainer()
        let plist = container.appendingPathComponent("enabledModules.plist")
        if let data = try? Data(contentsOf: plist),
           var list = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String],
           list.contains(FSKitEnablement.moduleBundleID) {
            list.removeAll { $0 == FSKitEnablement.moduleBundleID }
            let encoded = try PropertyListSerialization.data(
                fromPropertyList: list, format: .binary, options: 0)
            try encoded.write(to: plist, options: .atomic)
            removed = true
        }

        let appex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/iSCSIFSExtension.appex")
        let pluginkit = Process()
        pluginkit.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        pluginkit.arguments = ["-r", appex.path]
        try? pluginkit.run()
        pluginkit.waitUntilExit()

        return removed ? "disabled and unregistered" : "was not enabled"
    }

    /// `rmdir`, never `rm -rf`.
    ///
    /// Everything in this directory is a mount point, never storage. Anything
    /// still inside means a volume did not come down, and recursively deleting
    /// it would destroy the evidence — and potentially write through a live
    /// mount into the user's LUN.
    private func cleanCaches() async throws -> String {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/me.herko.iSCSIInitiator")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return "nothing left behind"
        }
        var stubborn: [String] = []
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in contents {
            let path = root.appendingPathComponent(name).path
            if rmdir(path) != 0 { stubborn.append(name) }
        }
        if rmdir(root.path) != 0 && !contents.isEmpty {
            throw UninstallError.cacheNotEmpty(stubborn)
        }
        return "removed"
    }

    func revealAppForTrashing() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

enum UninstallError: LocalizedError {
    case volumesBusy([String])
    case daemonStillRegistered(SMAppService.Status)
    case cacheNotEmpty([String])

    var errorDescription: String? {
        switch self {
        case .volumesBusy(let paths):
            return "still in use: \(paths.joined(separator: ", "))"
        case .daemonStillRegistered(let status):
            return "the system still reports it as registered (status \(status.rawValue))"
        case .cacheNotEmpty(let names):
            return "a mount point would not come down: \(names.joined(separator: ", "))"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .volumesBusy:
            return "Close anything using the volume — including Finder windows and "
                 + "Terminal sessions inside it — and try again."
        case .daemonStillRegistered:
            return "Remove it in System Settings → General → Login Items & Extensions."
        case .cacheNotEmpty:
            return "Restarting will release it, after which the folder can be deleted."
        }
    }
}

extension DaemonConnection {
    static func removeAllData() async throws {
        try await call { proxy, finish in
            proxy.removeAllData { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }
}
