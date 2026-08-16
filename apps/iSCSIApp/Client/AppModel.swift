//
//  AppModel.swift
//  The state the whole app renders, and the only place that mutates it.
//
//  Two rules worth stating because they are easy to erode:
//
//  Nothing here polls. Every refresh is triggered by something that actually
//  happened — a user action, returning to the foreground, or an operation
//  completing. A 2-second timer would be wrong nearly every time it fired and
//  would keep a root daemon's XPC service busy for a machine sitting idle.
//
//  Nothing here is gated on optimism. `isReady` comes from the setup checks, and
//  the Connect affordances are disabled until they pass, because an attach that
//  fails for a missing prerequisite produces an error about mounting when the
//  actual problem is that a background service was never approved.
//

import Combine
import Foundation
import SwiftUI
import iSCSIKit

@MainActor
final class AppModel: ObservableObject {
    let setup = SetupCoordinator()
    let attachments = AttachmentManager()
    let updates = UpdateController()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // The updater asks this before replacing the bundle. Answering it from
        // live state rather than a cached flag matters: the window between
        // "downloaded" and "installing" is exactly when someone attaches.
        updates.isAnythingAttached = { [weak attachments] in
            attachments?.attachments.contains(where: \.isFullyAttached) ?? false
        }
        updates.attachedVolumeNames = { [weak self] in
            self?.rows.filter(\.isAttached).map { row in
                row.volumePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? row.target.displayName
            } ?? []
        }
        updates.detachEverything = { [weak self] in
            guard let self else { return }
            for row in rows where row.isAttached {
                await detach(row.target)
            }
        }

        // A postponed update is released by the last volume going away — however
        // it goes away. Watching the attachment list covers pressing Detach,
        // ejecting in Finder, and anything added later, where a call placed in
        // detach() covers only the first: a Finder eject is handled inside
        // AttachmentManager and never passes through this type at all.
        //
        // Deferred a runloop turn on purpose. @Published fires on willSet, so a
        // sink that ran synchronously would ask "is anything attached?" while
        // the property still holds the old list, conclude yes, and leave the
        // update stuck — the exact bug this is here to fix, reintroduced in a
        // form that looks correct.
        attachments.$attachments
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updates.installPendingUpdateIfReady() }
            }
            .store(in: &cancellables)
    }

    @Published private(set) var targets: [TargetRecord] = []
    @Published private(set) var sessions: [SessionInfo] = []
    /// Target ids with an operation in flight, so rows can show progress and
    /// refuse a second click without a modal.
    @Published private(set) var busy: Set<String> = []
    @Published var lastError: PresentableError?

    var isReady: Bool { setup.isReady }

    /// Every configured target with whatever is currently true about it.
    struct Row: Identifiable {
        let target: TargetRecord
        let attachment: Attachment?
        let session: SessionInfo?
        let isBusy: Bool
        var id: String { target.id }

        var isAttached: Bool { attachment?.isFullyAttached ?? false }
        var volumePath: String? { attachment?.volumePaths.first }
    }

    var rows: [Row] {
        targets.map { target in
            Row(target: target,
                attachment: attachments.attachments.first { $0.targetID == target.id },
                session: sessions.first { $0.targetIQN == target.targetIQN
                                          && $0.lun == target.lun },
                isBusy: busy.contains(target.id))
        }
    }

    // MARK: - Refreshing

    /// The one entry point. Called at launch and on every return to the
    /// foreground, because all of this can change without the app being told:
    /// the user can eject in Finder, the daemon can be denied in System
    /// Settings, a session can drop.
    func refresh() async {
        await setup.checkAll()
        guard setup.isReady else {
            // Without a daemon there is nothing to ask, and asking produces
            // errors that describe the symptom rather than the cause.
            sessions = []
            return
        }
        do {
            targets = try await DaemonConnection.listTargets()
            sessions = try await DaemonConnection.sessions()
            attachments.reconcile(targets: targets)
        } catch {
            present(error, doing: "Reading your targets")
        }
    }

    // MARK: - Targets

    func save(_ target: TargetRecord, secret: String?, mutualSecret: String? = nil) async {
        do {
            // Use the id the daemon actually stored under. Adding a target
            // that already exists keeps the existing record's id, so filing the
            // secret under the id we sent would put it somewhere nothing looks.
            let stored = try await DaemonConnection.saveTarget(target)
            // Secrets go in their own calls and never into targets.json.
            //
            // Clearing a user name clears its secret with it. Otherwise the
            // secret outlives the username that gave it meaning, and re-adding
            // the same name later silently resurrects a credential the user
            // believes they removed.
            if let secret, !secret.isEmpty {
                try await DaemonConnection.setCHAPSecret(targetID: stored.id, secret: secret)
            } else if target.chapUser == nil {
                try? await DaemonConnection.deleteCHAPSecret(targetID: stored.id)
            }
            if let mutualSecret, !mutualSecret.isEmpty {
                try await DaemonConnection.setMutualCHAPSecret(targetID: stored.id,
                                                               secret: mutualSecret)
            } else if target.mutualChapUser == nil {
                try? await DaemonConnection.deleteMutualCHAPSecret(targetID: stored.id)
            }
            targets = try await DaemonConnection.listTargets()
        } catch {
            present(error, doing: "Saving “\(target.displayName)”")
        }
    }

    func delete(_ target: TargetRecord) async {
        // Detach first: deleting a target whose volume is mounted would leave a
        // volume in Finder that nothing in the app can see or take down.
        if let attachment = attachments.attachments.first(where: { $0.targetID == target.id }) {
            try? await attachments.detach(tag: attachment.tag)
        }
        do {
            try await DaemonConnection.deleteTarget(id: target.id)
            targets = try await DaemonConnection.listTargets()
        } catch {
            present(error, doing: "Removing “\(target.displayName)”")
        }
    }

    // MARK: - Attach / detach

    func attach(_ target: TargetRecord) async {
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        do {
            // Check reachability and credentials before mounting, without
            // holding a session.
            //
            // It cannot be a login/logout pair from here: handles belong to the
            // XPC connection that created them, and this client opens a fresh
            // connection per call, so the logout would arrive on a connection
            // that does not own the handle and be refused. That leaked one
            // session per attach. testConnection does both inside the daemon.
            //
            // Worth doing at all because it is the only place a wrong secret or
            // an unreachable portal is reported as itself. Once the mount is
            // performing the login, the same failure surfaces as "mount: Unable
            // to invoke task", which sends the user to the filesystem extension
            // instead of to their password.
            _ = try await DaemonConnection.testConnection(
                host: target.host, port: target.port, targetIQN: target.targetIQN,
                lun: target.lun)

            let attachment = try await attachments.attach(target)
            sessions = try await DaemonConnection.sessions()

            // Attached, but with nothing on it. A brand-new LUN always looks
            // like this, so it is a normal outcome rather than a failure — and
            // saying so beats an error dialog about a disk that is, in fact,
            // right there and ready to format.
            if !attachment.isFullyAttached, let device = attachment.device {
                lastError = PresentableError(
                    title: "“\(target.displayName)” is connected but not formatted",
                    message: "The LUN is attached as \(device) and has no filesystem "
                           + "on it yet, which is normal for a new LUN.",
                    suggestion: "Open Disk Utility, select it, and erase it as APFS "
                              + "or ExFAT. It will mount by itself afterwards.")
            }
        } catch {
            present(error, doing: "Attaching “\(target.displayName)”")
        }
    }

    func detach(_ target: TargetRecord) async {
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        guard let attachment = attachments.attachments.first(where: { $0.targetID == target.id })
        else { return }
        do {
            // Unmounting is what closes the session: the extension logs out in
            // deactivateVolume. The app owns no session of its own to close —
            // see the note in attach().
            try await attachments.detach(tag: attachment.tag)
            sessions = try await DaemonConnection.sessions()
            // No installPendingUpdateIfReady() here. The sink in init() sees the
            // attachment list change and handles this path and the Finder-eject
            // path with one mechanism; calling it here as well would work, and
            // would quietly suggest that this is the only path that needs it.
        } catch {
            present(error, doing: "Detaching “\(target.displayName)”")
        }
    }

    func reveal(_ row: Row) {
        guard let path = row.volumePath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    // MARK: - Errors

    /// Keeps the recovery suggestion the daemon attached. That text is the
    /// difference between "check the CHAP secret for this target" and a user
    /// staring at "the operation could not be completed".
    private func present(_ error: Error, doing what: String) {
        let ns = error as NSError
        lastError = PresentableError(
            title: what,
            message: ns.localizedDescription,
            suggestion: ns.localizedRecoverySuggestion
                ?? (error as? LocalizedError)?.recoverySuggestion)
    }
}

struct PresentableError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let suggestion: String?
}
