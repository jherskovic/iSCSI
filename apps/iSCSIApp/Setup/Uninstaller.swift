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
//    2. Delete secrets and data.   This account's. Both live in the *daemon's*
//                                  context. After step 4 the app cannot reach
//                                  the keychain items, and they would outlive
//                                  the app with nothing left that knows their
//                                  names. Other accounts' are theirs to remove,
//                                  and stay: the step says so.
//    3. Remove the login item.     Independent of the daemon; done while the
//                                  rest can still report.
//    4. Unregister the daemon.     Only now, because steps 1 and 2 need it.
//    5. Disable and unregister the filesystem extension, in the user's context.
//    6. Remove the iscsictl link, if there is one and it is this app's. Asks
//       for an administrator; cancelling that keeps the link and nothing else.
//    7. Empty and remove the cache directory, never deleting through a mount.
//    8. Move the app to the Trash, close the sheet, and quit, when the user
//       says so. AppKit will not terminate an app while a sheet is open.
//
//  Every step reports rather than throwing, because a failure partway through
//  must not strand the user midway: the remaining steps still run, and the
//  screen says exactly what was and was not removed.
//
//  Except step 1. A volume that will not detach stops everything: the steps
//  after it delete the daemon serving that volume and the extension under its
//  filesystem, which is exactly the data loss the order exists to prevent.
//  The user closes whatever is using it and runs the removal again.
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
        /// what it could not do. The detach step is the exception.
        case failed(String)
        /// Not run, because a volume did not detach.
        case skipped
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false
    /// The run stopped at the detach step; nothing after it ran, and the
    /// removal can be started again.
    @Published private(set) var stoppedForVolumes = false

    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func run() async {
        isRunning = true
        finished = false
        stoppedForVolumes = false
        // A login-time run still retrying would mount behind "Detach volumes".
        model.autoAttacher.cancelAll()
        steps = [
            Step(label: "Detach volumes", outcome: .pending),
            Step(label: "Delete saved targets and passwords", outcome: .pending),
            Step(label: "Remove the login item", outcome: .pending),
            Step(label: "Remove the background service", outcome: .pending),
            Step(label: "Turn off the filesystem extension", outcome: .pending),
            Step(label: "Remove the iscsictl link", outcome: .pending),
            Step(label: "Clean up", outcome: .pending),
        ]

        await step(0) { try await self.detachEverything() }
        if case .failed = steps[0].outcome {
            for index in steps.indices.dropFirst() { steps[index].outcome = .skipped }
            stoppedForVolumes = true
            isRunning = false
            return
        }
        await step(1) { try await self.removeDaemonData() }
        await step(2) { try await self.unregisterLoginItem() }
        await step(3) { try await self.unregisterDaemon() }
        await step(4) { try await self.disableExtension() }
        await step(5) { try await self.removeCommandLineLink() }
        await step(6) { try await self.cleanCaches() }

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
                // Never forced (the default): see the file header.
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
        // Asked afterwards, and never a reason to fail: what went, went.
        switch (try? await DaemonConnection.otherAccountsWithData()) ?? 0 {
        case 0: return "removed"
        case 1: return "removed; another account's saved targets were kept"
        case let others: return "removed; \(others) other accounts' saved targets were kept"
        }
    }

    /// "Attach at login" registers the app itself as a login item; a removed
    /// app must not leave an entry behind that launches nothing.
    private func unregisterLoginItem() async throws -> String {
        let before = LoginItem.status
        guard before != .notRegistered, before != .notFound else { return "was not set" }
        try await LoginItem.unregister()
        let status = LoginItem.status
        guard status == .notRegistered || status == .notFound else {
            throw UninstallError.loginItemStillRegistered(status)
        }
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
        // Off the main actor, like every subprocess the app waits on: a slow
        // pluginkit must not freeze the window mid-uninstall.
        await Task.detached {
            let pluginkit = Process()
            pluginkit.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            pluginkit.arguments = ["-r", appex.path]
            try? pluginkit.run()
            pluginkit.waitUntilExit()
        }.value

        return removed ? "disabled and unregistered" : "was not enabled"
    }

    /// Only a link to this copy, so a link or a file that was already there
    /// when setup looked, and that it left alone, stays. Any account's removal
    /// takes it: it is one link for the Mac, and the app it points at is going.
    private func removeCommandLineLink() async throws -> String {
        switch CommandLineTool.currentLink() {
        case .absent:
            return "was not set"
        case .otherLink, .notALink:
            return "\(CommandLineLink.path) is not this app's, and was left alone"
        case .ours:
            break
        }
        switch await CommandLineTool.removeLink() {
        case .done:              return "removed"
        case .cancelled:         throw UninstallError.commandLineLinkKept("not removed")
        case .failed(let why):   throw UninstallError.commandLineLinkKept(why)
        }
    }

    /// Deletes what the cache directory holds, never through a mount.
    ///
    /// It holds a mount point per attach, and, being the directory named after
    /// the bundle ID, URLSession's default disk cache too: `Cache.db`, its
    /// `-shm` and `-wal`, and `fsCachedData`, from Sparkle's update checks. So
    /// `rmdir` alone, which this once was, failed on every Mac that had
    /// checked for an update, and blamed a mount point.
    ///
    /// Anything with a volume mounted at or beneath it is left alone: a
    /// recursive delete that reaches a live mount deletes the files on the
    /// disk itself. The mount table is matched against the path both as built
    /// and as resolved, since the kernel records a mount point resolved, and
    /// an entry on another device than the directory is a mount whatever the
    /// table says. Step 1 detached everything, so either is a volume that came
    /// back or never went.
    private func cleanCaches() async throws -> String {
        let root = AttachmentManager.cacheRoot.path
        guard FileManager.default.fileExists(atPath: root) else {
            return "nothing left behind"
        }
        let mounts = AttachmentManager.mountTable()
        let roots = Set([root, Self.resolved(root)].compactMap { $0 })
        let rootDevice = Self.device(root)
        var mounted: [String] = []
        var undeletable: [String] = []
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in contents {
            let path = root + "/" + name
            if roots.contains(where: { MountTableEntry.anyMounted(atOrBelow: $0 + "/" + name,
                                                                  in: mounts) })
                || Self.device(path).map({ $0 != rootDevice }) == true {
                mounted.append(name)
                continue
            }
            do { try FileManager.default.removeItem(atPath: path) } catch { undeletable.append(name) }
        }
        if !mounted.isEmpty { throw UninstallError.cacheNotEmpty(mounted) }
        if !undeletable.isEmpty { throw UninstallError.cacheUndeletable(undeletable) }
        // Not empty after all: something wrote there since the listing, most
        // likely this app's own URLSession cache, since the app is still
        // running. Say what is there now.
        if rmdir(root) != 0 && errno != ENOENT {
            throw UninstallError.cacheUndeletable(
                (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
        }
        return "removed"
    }

    private nonisolated static func device(_ path: String) -> dev_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    private nonisolated static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// Why the app could not move itself to the Trash, once it has tried.
    @Published private(set) var trashFailure: String?
    @Published private(set) var trashing = false

    /// The last step: the app moves its own bundle to the Trash. True when it
    /// is gone from where it was; the caller then closes the uninstall sheet
    /// and quits, in that order, since AppKit will not terminate an app with
    /// a sheet open (seen on the 26.7.2 VM: "App termination blocked by
    /// modal sheet").
    ///
    /// macOS lets a running app's bundle be moved, and by now nothing else
    /// runs from it: the daemon and the login item are unregistered and the
    /// extension is removed. This button once only revealed the app in
    /// Finder, under a label that said it moved it. Where the move is refused
    /// — a standard account cannot write /Applications — Finder is opened on
    /// the app instead, for a drag that can ask for an administrator.
    ///
    /// `FileManager.trashItem`, not `NSWorkspace.recycle`: on the 26.7.2 VM,
    /// 2026-11-03, `recycle` moved the bundle and never called back, so the
    /// app did not quit, and a second click reported the bundle it had just
    /// moved as unmovable. What decides success is whether the bundle is
    /// still where it was.
    func moveAppToTrash() async -> Bool {
        guard !trashing else { return false }
        trashing = true
        defer { trashing = false }
        trashFailure = nil
        let app = Bundle.main.bundleURL
        let moved = await Task.detached {
            Result { try FileManager.default.trashItem(at: app, resultingItemURL: nil) }
        }.value
        if case .failure(let error) = moved, FileManager.default.fileExists(atPath: app.path) {
            trashFailure = error.localizedDescription
            NSWorkspace.shared.activateFileViewerSelecting([app])
            return false
        }
        return true
    }
}

enum UninstallError: LocalizedError {
    case volumesBusy([String])
    case daemonStillRegistered(SMAppService.Status)
    case loginItemStillRegistered(SMAppService.Status)
    case commandLineLinkKept(String)
    case cacheNotEmpty([String])
    case cacheUndeletable([String])

    var errorDescription: String? {
        switch self {
        case .volumesBusy(let paths):
            return "still in use: \(paths.joined(separator: ", "))"
        case .daemonStillRegistered(let status),
             .loginItemStillRegistered(let status):
            return "the system still reports it as registered (status \(status.rawValue))"
        case .commandLineLinkKept(let why):
            // The step list shows this line and not `recoverySuggestion`.
            return "\(why). To remove it yourself: sudo rm \(CommandLineLink.path)"
        case .cacheNotEmpty(let names):
            return "a volume is still mounted there: \(names.joined(separator: ", "))"
        case .cacheUndeletable(let names):
            let folder = "~/Library/Caches/me.herko.iSCSIInitiator"
            return names.isEmpty
                ? "\(folder) could not be removed"
                : "could not delete \(names.joined(separator: ", ")) in \(folder)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .volumesBusy:
            return "Close anything using the volume — including Finder windows and "
                 + "Terminal sessions inside it — and try again."
        case .daemonStillRegistered:
            return "Remove it in System Settings → General → Login Items & Extensions."
        case .loginItemStillRegistered:
            return "Remove iSCSI Initiator from Open at Login in System Settings → "
                 + "General → Login Items & Extensions."
        case .commandLineLinkKept:
            return nil
        case .cacheNotEmpty:
            return "Restarting will release it, after which the folder can be deleted."
        case .cacheUndeletable:
            return "Delete the folder in Finder once the app has quit."
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

    static func otherAccountsWithData() async throws -> Int {
        try await call { proxy, finish in
            proxy.otherAccountsWithData { count in finish(.success(count.intValue)) }
        }
    }
}
