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

import Foundation
import SwiftUI
import iSCSIKit

@MainActor
final class AppModel: ObservableObject {
    let setup = SetupCoordinator()
    let attachments = AttachmentManager()

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

    func save(_ target: TargetRecord, secret: String?) async {
        do {
            try await DaemonConnection.saveTarget(target)
            // The secret goes in its own call and never into targets.json.
            if let secret, !secret.isEmpty {
                try await DaemonConnection.setCHAPSecret(targetID: target.id, secret: secret)
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
            // A pre-flight login that is immediately closed again.
            //
            // The FSKit extension opens its *own* session when the mount
            // happens (iSCSIFSExtension.swift:309) and logs out when the volume
            // is deactivated, so the app must not hold one: doing that opened
            // two sessions per attach against the same LUN, and detach only
            // ever closed one of them.
            //
            // It is still worth making the round trip, because it is the only
            // place a credential or reachability problem can be reported as
            // itself. Once the mount is doing the login, the same failure
            // arrives as "mount: Unable to invoke task", which sends the user
            // looking at the filesystem extension instead of at their password.
            let probe = try await DaemonConnection.login(
                host: target.host, port: target.port, targetIQN: target.targetIQN,
                lun: target.lun, chapUser: target.chapUser)
            try? await DaemonConnection.logout(session: probe)

            _ = try await attachments.attach(target)
            sessions = try await DaemonConnection.sessions()
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
