//
//  AppModel.swift
//  The state the whole app renders, and the only place that mutates it.
//
//  Nothing here polls. Every refresh is triggered by something that actually
//  happened — a user action, returning to the foreground, or an operation
//  completing. A 2-second timer would be wrong nearly every time it fired and
//  would keep a root daemon's XPC service busy for a machine sitting idle.
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
        // Answered from live state: the window between "downloaded" and
        // "installing" is exactly when someone attaches.
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
                // "Detach and Install" was the consent; asking again stalls.
                await detach(row.target, ejectingMounted: true)
            }
        }

        // Watching the attachment list covers every way a volume goes away,
        // Finder ejects included. Deferred a runloop turn on purpose:
        // @Published fires on willSet, so a synchronous sink would see the old
        // list and leave the update stuck.
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
    /// Set when Detach was pressed while the volume is still mounted: the UI
    /// asks first, because the layers below fall back to force-eject and a
    /// mounted volume can have live writers. Explicitly-labelled eject paths
    /// skip the question — their click is the consent.
    @Published var pendingDetach: TargetRecord?

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

    /// The one entry point. Called at launch and on every return to the
    /// foreground, because all of this can change without the app being told:
    /// the user can eject in Finder, the daemon can be denied in System
    /// Settings, a session can drop.
    func refresh() async {
        await setup.checkAll()
        guard setup.isReady else {
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

    func save(_ target: TargetRecord, secret: String?, mutualSecret: String? = nil) async {
        do {
            // Use the id the daemon stored under: re-adding an existing
            // target keeps the old record's id.
            let stored = try await DaemonConnection.saveTarget(target)
            // Secrets go in their own calls, never into targets.json; and
            // clearing a user name clears its secret, or re-adding the name
            // later silently resurrects a removed credential.
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
        // Detach first, or the mounted volume outlives anything that can
        // take it down.
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

    func attach(_ target: TargetRecord) async {
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        do {
            // Check reachability and credentials before mounting: the only
            // place a wrong secret or unreachable portal is reported as
            // itself — during the mount it surfaces as "mount: Unable to
            // invoke task".
            _ = try await DaemonConnection.testConnection(
                host: target.host, port: target.port, targetIQN: target.targetIQN,
                lun: target.lun)

            let attachment = try await attachments.attach(target)
            sessions = try await DaemonConnection.sessions()

            // Attached with nothing on it: how every brand-new LUN looks — a
            // normal outcome, not a failure.
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

    func detach(_ target: TargetRecord, ejectingMounted: Bool = false) async {
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        guard let attachment = attachments.attachments.first(where: { $0.targetID == target.id })
        else { return }
        if !ejectingMounted, !attachment.volumePaths.isEmpty {
            pendingDetach = target
            return
        }
        do {
            // Unmounting is what closes the session: the extension logs out
            // in deactivateVolume; the app owns no session of its own.
            try await attachments.detach(tag: attachment.tag)
            sessions = try await DaemonConnection.sessions()
            // No installPendingUpdateIfReady() here: the sink in init() covers
            // this path and Finder ejects with one mechanism.
        } catch {
            present(error, doing: "Detaching “\(target.displayName)”")
        }
    }

    func reveal(_ row: Row) {
        guard let path = row.volumePath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

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
