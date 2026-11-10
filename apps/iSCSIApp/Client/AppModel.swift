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
import ServiceManagement
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
        // "installing" is exactly when someone attaches. *Anything* counts —
        // a blank LUN attached as a raw device that Disk Utility is erasing,
        // the FSKit volume alone, an attach or detach still in flight — not
        // only a mounted filesystem: an update replaces the extension serving
        // every one of them.
        //
        // The mount table decides, not only the attachment list: that list
        // is this account's alone, empty until the first reconcile, and was
        // never filled while setup reported anything unsatisfied — which is
        // what a relaunch after an update often reports. Another account's
        // volume is served by the same extension.
        updates.isAnythingAttached = { [weak self] in
            guard let self else { return false }
            return !attachments.attachments.isEmpty || !busy.isEmpty
                || !AppReplacement.mountsItWouldDisconnect(AttachmentManager.mountTable()).isEmpty
        }
        updates.attachedVolumeNames = { [weak self] in
            guard let self else { return [] }
            let listed = rows.filter { $0.attachment != nil }.map { row in
                row.volumePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? row.target.displayName
            } + orphans.map(Self.orphanTitle)
            let ownRoot = AttachmentManager.cacheRoot.path + "/"
            let mounted = AppReplacement.mountsItWouldDisconnect(AttachmentManager.mountTable())
            // Another account's by whose they are; this account's own only
            // when the list has not caught up with them.
            let unlisted = mounted.filter { !$0.on.hasPrefix(ownRoot) || listed.isEmpty }
            return listed + unlisted.map(FSKitRestart.describe)
        }
        updates.detachEverything = { [weak self] in
            // "Detach and Install" was the consent to eject; a volume
            // something is still using is asked about on its own.
            await self?.detachAll()
        }

        // Watching the attachment list covers every way a volume goes away,
        // Finder ejects included. Deferred a runloop turn on purpose:
        // @Published fires on willSet, so a synchronous sink would see the old
        // list and leave the update stuck.
        attachments.$attachments.map { _ in () }
            .merge(with: $busy.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updates.installPendingUpdateIfReady() }
            }
            .store(in: &cancellables)

        // Read the targets the moment setup turns ready, whoever ran the
        // check. `refresh` reads them only when its own pass ends ready, and
        // the Setup screen checks on its own — when it appears, on Re-check,
        // after each step's button — so a launch that started not ready used
        // to finish green with an empty Targets pane, until the next return
        // to the foreground or a save. On a launch that is ready at once,
        // this and `refresh` both read; the reads are idempotent.
        setup.$reports
            .map(SetupCoordinator.isReady)
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Unreported: a failure here is reported by the next
                    // refresh, which every return to the foreground runs.
                    Task { await self.readTargets(reportingErrors: false) }
                }
            }
            .store(in: &cancellables)

        // Views read setup through this model (`isReady`, the sidebar's
        // spinner and "!"), and observe only this model. Without passing its
        // changes on, they redrew when something here happened to change too.
        setup.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    @Published private(set) var targets: [TargetRecord] = []
    /// Target reads under way: a whole `refresh`, its setup pass included —
    /// at launch that pass is most of the wait — or a read after setup
    /// turned ready. Counted, because they overlap.
    @Published private var targetReadsInFlight = 0
    var isLoadingTargets: Bool { targetReadsInFlight > 0 }
    /// The list has been read at least once since launch. Until then an
    /// empty `targets` means "not read yet", not "no targets".
    @Published private(set) var hasReadTargets = false

    /// Nothing to show on Targets *yet*: the list has not been read, and a
    /// read — or the setup check before it — is under way or has not started.
    /// The screen shows progress for this rather than "Finish setup first",
    /// which would be a claim nobody has checked.
    var isAwaitingFirstRead: Bool {
        !hasReadTargets && (isLoadingTargets || setup.isWorking || setup.reports.isEmpty)
    }
    @Published private(set) var sessions: [SessionInfo] = []
    /// Target ids with an operation in flight, so rows can show progress and
    /// refuse a second click without a modal.
    @Published private(set) var busy: Set<String> = []
    @Published var lastError: PresentableError?
    /// Set when Detach was pressed while the volume is still mounted: the UI
    /// asks first, because a mounted volume can have live writers.
    /// Explicitly-labelled eject paths skip the question — their click is the
    /// consent to eject. Neither is consent to *force*: a volume still in use
    /// is asked about separately (`ForceEjectPrompt`).
    @Published var pendingDetach: TargetRecord?
    /// A request to show the main window. Set by the app delegate and the
    /// auto-attach run; `MenuBarLabel` opens the window and clears it.
    @Published var wantsMainWindow = false
    /// Marked targets the login-time run could not attach, by target id. Set
    /// when the run ends; cleared for a target once it attaches by any path, or
    /// when the user removes it or unchecks it.
    @Published private(set) var autoAttachFailures: [String: PresentableError] = [:]
    /// Whether the app will be launched at login, which is what makes the
    /// "Attach at login" boxes do anything. Re-read on every refresh, so
    /// turning it off in System Settings shows up on returning to the app.
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered

    lazy var autoAttacher = AutoAttacher(model: self)

    var isReady: Bool { setup.isReady }

    /// The app was launched as a login item: attach what is marked, with
    /// nothing on screen. Sparkle waits for the run — an update alert is a
    /// window.
    func beginLoginLaunch() {
        autoAttacher.start { [weak self] in self?.updates.start() }
    }

    func recordAutoAttachFailures(_ failures: [String: PresentableError]) {
        autoAttachFailures.merge(failures) { _, new in new }
    }

    func clearAutoAttachFailure(for id: String) {
        autoAttachFailures[id] = nil
    }

    /// Marks a target busy for the duration of `work`, so its row shows
    /// progress and refuses a second click.
    func withBusy<T>(_ id: String, _ work: () async throws -> T) async rethrows -> T {
        busy.insert(id)
        defer { busy.remove(id) }
        return try await work()
    }

    /// Every configured target with whatever is currently true about it.
    struct Row: Identifiable {
        let target: TargetRecord
        let attachment: Attachment?
        let session: SessionInfo?
        let isBusy: Bool
        /// Why this marked target is not attached after the login-time run.
        let autoAttachFailure: PresentableError?
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
                isBusy: busy.contains(target.id),
                autoAttachFailure: autoAttachFailures[target.id])
        }
    }

    /// The one entry point. Called at launch and on every return to the
    /// foreground, because all of this can change without the app being told:
    /// the user can eject in Finder, the daemon can be denied in System
    /// Settings, a session can drop.
    ///
    /// Returns whether the target list was read. The login-time run passes
    /// `reportingErrors: false`: a daemon that is not answering yet a few
    /// seconds after login is expected there, not something to alert about.
    @discardableResult
    func refresh(reportingErrors: Bool = true) async -> Bool {
        targetReadsInFlight += 1
        defer { targetReadsInFlight -= 1 }
        loginItemStatus = LoginItem.status
        await setup.checkAll()
        guard setup.isReady else {
            sessions = []
            // What is mounted is still worth knowing: Detach All, the update
            // gate and Uninstall all read this list, and a relaunch after an
            // update often finds setup unsatisfied with volumes still up.
            // Without targets they show as orphans, which can be detached.
            await attachments.reconcile(targets: targets)
            return false
        }
        return await readTargets(reportingErrors: reportingErrors)
    }

    /// The daemon's half of `refresh`, for when setup is already known to be
    /// ready: the targets, the sessions, and what is mounted.
    @discardableResult
    private func readTargets(reportingErrors: Bool) async -> Bool {
        targetReadsInFlight += 1
        defer { targetReadsInFlight -= 1 }
        do {
            targets = try await DaemonConnection.listTargets()
            hasReadTargets = true
            sessions = try await DaemonConnection.sessions()
            await attachments.reconcile(targets: targets)
            for attachment in attachments.attachments where attachment.device != nil {
                autoAttachFailures[attachment.targetID] = nil
            }
            return true
        } catch {
            if reportingErrors { present(error, doing: "Reading your targets") }
            return false
        }
    }

    func save(_ target: TargetRecord, secret: String?, mutualSecret: String? = nil) async {
        // The editor locks these fields while the target is in use; this is
        // the same rule for anything that gets past it (the target attached
        // while the sheet was open). A mounted volume is found by its address,
        // port, name and unit (`MountpointTag`), so changing one under it
        // loses track of the volume — and a later attach becomes a second
        // writer on the same disk.
        if let old = targets.first(where: { $0.id == target.id }),
           !old.sameUnitAndPortal(as: target) {
            await refreshSessions()
        }
        if let old = targets.first(where: { $0.id == target.id }),
           !old.sameUnitAndPortal(as: target),
           let row = rows.first(where: { $0.id == target.id }),
           row.attachment != nil || row.session != nil {
            lastError = PresentableError(
                title: "“\(old.displayName)” is in use",
                message: "Its address, port, name or \(old.isNVMe ? "namespace" : "LUN") "
                       + "can't change while it is attached: the app finds the mounted "
                       + "volume by them.",
                suggestion: "Detach it, then edit it. Nothing was saved.")
            return
        }
        do {
            // Use the id the daemon stored under: re-adding an existing
            // target keeps the old record's id.
            let stored = try await DaemonConnection.saveTarget(target)
            if !stored.autoAttach {
                autoAttacher.cancel(targetID: stored.id)
                clearAutoAttachFailure(for: stored.id)
            }
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
            await syncLoginItem(savedIsMarked: stored.autoAttach)
        } catch {
            present(error, doing: "Saving “\(target.displayName)”")
        }
    }

    /// Keeps the login item in step with the boxes, after the user's own save
    /// or delete and never otherwise. `LoginItemPolicy` has the rules.
    private func syncLoginItem(savedIsMarked: Bool?) async {
        let status = LoginItem.status
        let action = LoginItemPolicy.action(
            savedIsMarked: savedIsMarked,
            anyMarked: targets.contains(where: \.autoAttach),
            isRegistered: status == .enabled || status == .requiresApproval,
            isEnabled: status == .enabled,
            canRegisterFromHere: LoginItem.canRegisterFromHere)
        do {
            switch action {
            case .register: try LoginItem.register()
            case .unregister: try await LoginItem.unregister()
            case .blockedByLocation, .none: break
            }
        } catch {
            // Turned off in System Settings: the banner on Targets already
            // says so, and an alert on every save would only repeat it.
            if !(action == .register && status == .requiresApproval) {
                present(error, doing: "Changing the login item")
            }
        }
        loginItemStatus = LoginItem.status
    }

    /// The banner's "Turn On": the user asked, so this registers even though
    /// no save happened.
    func turnOnLoginItem() {
        do {
            try LoginItem.register()
        } catch {
            present(error, doing: "Turning on the login item")
        }
        loginItemStatus = LoginItem.status
    }

    func delete(_ target: TargetRecord) async {
        // Not mid-attach: the mount it is making would outlive its record, and
        // `reconcile` only looks for mounts of targets that still exist.
        guard !busy.contains(target.id) else { return }
        autoAttacher.cancel(targetID: target.id)
        clearAutoAttachFailure(for: target.id)
        // Detach first, or the mounted volume outlives anything that can
        // take it down — and stop if that fails: removing the record of a
        // volume still in use leaves it with nothing that can detach it.
        if let attachment = attachments.attachments.first(where: { $0.targetID == target.id }) {
            do {
                try await attachments.detach(tag: attachment.tag)
            } catch {
                present(error, doing: "Removing “\(target.displayName)”")
                return
            }
        }
        do {
            try await DaemonConnection.deleteTarget(id: target.id)
            targets = try await DaemonConnection.listTargets()
            await syncLoginItem(savedIsMarked: nil)
        } catch {
            present(error, doing: "Removing “\(target.displayName)”")
        }
    }

    /// Check, mount, and refresh sessions — what Attach does, without the
    /// alerts or the busy marker, so the login-time run can share it.
    func performAttach(_ target: TargetRecord) async throws -> Attachment {
        // Check reachability and credentials before mounting: the only
        // place a wrong secret or unreachable portal is reported as
        // itself — during the mount it surfaces as "mount: Unable to
        // invoke task".
        _ = try await DaemonConnection.testConnection(
            host: target.host, port: target.port, targetIQN: target.targetIQN,
            lun: target.lun)

        let attachment = try await attachments.attach(target)
        sessions = try await DaemonConnection.sessions()
        return attachment
    }

    func attach(_ target: TargetRecord) async {
        // The user has taken this target over; the login-time run lets go.
        autoAttacher.cancel(targetID: target.id)
        do {
            let attachment = try await withBusy(target.id) { try await performAttach(target) }
            clearAutoAttachFailure(for: target.id)

            // Attached with nothing mounted. Blank — how every brand-new LUN
            // looks — is a normal outcome, not a failure. Anything else may be
            // data macOS cannot mount (ext4, ZFS, a still-checking volume), so
            // it is never met with advice to erase.
            //
            // A locked encrypted volume gets nothing here. The attach has
            // already tried the password macOS saved for it; without one it
            // stays locked, quietly. The row says so, and Disk Utility's Mount
            // unlocks it and can save the password for next time.
            if !attachment.isFullyAttached, attachment.lockedVolumes.isEmpty,
               let device = attachment.device {
                let unit = target.isNVMe ? "namespace" : "LUN"
                if attachment.isBlank == true {
                    lastError = PresentableError(
                        title: "“\(target.displayName)” is connected but not formatted",
                        message: "The \(unit) is attached as \(device) and has no filesystem "
                               + "on it yet, which is normal for a new \(unit).",
                        suggestion: "Open Disk Utility, select it, and erase it as APFS "
                                  + "or ExFAT. It will mount by itself afterwards.")
                } else {
                    lastError = PresentableError(
                        title: "“\(target.displayName)” is connected, but nothing mounted",
                        message: "The \(unit) is attached as \(device), and it is not empty, "
                               + "but macOS did not mount a volume from it. It may use a "
                               + "filesystem macOS cannot read, be encrypted and locked, or "
                               + "still be checking.",
                        suggestion: "Disk Utility shows what is on it. Do not erase it "
                                  + "unless you mean to delete what it holds.")
                }
            }
        } catch {
            present(error, doing: "Attaching “\(target.displayName)”")
        }
    }

    func detach(_ target: TargetRecord, ejectingMounted: Bool = false) async {
        autoAttacher.cancel(targetID: target.id)
        clearAutoAttachFailure(for: target.id)
        busy.insert(target.id)
        defer { busy.remove(target.id) }
        guard let attachment = attachments.attachments.first(where: { $0.targetID == target.id })
        else { return }
        if !ejectingMounted, !attachment.volumePaths.isEmpty {
            pendingDetach = target
            return
        }
        await detach(attachment, named: target.displayName)
    }

    /// The daemon's sessions, read now. A detach's session outlives the
    /// unmount by a moment (it ends when RunningBoard ends the extension), so
    /// a list read right after one can still show it; the editor's lock reads
    /// afresh rather than trust that.
    func refreshSessions() async {
        if let current = try? await DaemonConnection.sessions() { sessions = current }
    }

    /// A mounted disk no target accounts for any more (`Attachment.isOrphan`):
    /// left by editing a target while it was attached, or removing it. Its
    /// Eject button is the consent; a disk in use is still asked about.
    func detachOrphan(_ orphan: Attachment) async {
        busy.insert(orphan.tag)
        defer { busy.remove(orphan.tag) }
        await detach(orphan, named: Self.orphanTitle(orphan))
    }

    /// Every attachment, rows and orphans: the menu bar's Detach All and the
    /// updater's "Detach and Install". Each eject was consented to by the
    /// click; a disk in use is asked about on its own.
    func detachAll() async {
        for row in rows where row.attachment != nil {
            await detach(row.target, ejectingMounted: true)
        }
        for orphan in orphans {
            await detachOrphan(orphan)
        }
    }

    /// Attachments with no record behind them, for their own group in Targets.
    var orphans: [Attachment] { attachments.attachments.filter(\.isOrphan) }

    /// What an orphan is, from its mount source: the volume's name if one is
    /// mounted, otherwise the target and unit it was attached as.
    static func orphanTitle(_ orphan: Attachment) -> String {
        if let volume = orphan.volumePaths.first { return URL(fileURLWithPath: volume).lastPathComponent }
        guard let unit = orphan.mountSource.flatMap(AutoAttachRun.mountedUnit) else { return orphan.tag }
        return "\(unit.name) \(unit.isNVMe ? "namespace" : "LUN") \(unit.unit)"
    }

    /// The detach itself, shared by targets and orphans.
    private func detach(_ attachment: Attachment, named name: String) async {
        do {
            // Unmounting is what closes the session: the extension logs out
            // in deactivateVolume; the app owns no session of its own.
            do {
                try await attachments.detach(tag: attachment.tag)
            } catch DetachError.inUse(let detail) {
                // Finder's rule: a plain eject first, and forcing only on a
                // second, explicit yes. Asked even when the click was already
                // consent to eject — that was not consent to take the volume
                // from an app that has files open on it.
                let volume = attachment.volumePaths.first
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
                guard ForceEjectPrompt.confirm(volume: volume, detail: detail) else { return }
                try await attachments.detach(tag: attachment.tag, force: true)
            }
            sessions = try await DaemonConnection.sessions()
            // No installPendingUpdateIfReady() here: the sink in init() covers
            // this path and Finder ejects with one mechanism.
        } catch {
            present(error, doing: "Detaching “\(name)”")
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
        lastError = Self.presentable(error, title: what)
    }

    static func presentable(_ error: Error, title: String) -> PresentableError {
        let ns = error as NSError
        return PresentableError(
            title: title,
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

extension TargetRecord {
    /// Whether `other` names the same portal and unit — every input to the
    /// mount point (`MountpointTag`), with the host spelled as typed.
    func sameUnitAndPortal(as other: TargetRecord) -> Bool {
        host == other.host && port == other.port
            && targetIQN == other.targetIQN && lun == other.lun
    }
}

/// The question Finder asks about a disk something is still using. A modal
/// alert rather than SwiftUI state, because the eject can start in the menu
/// bar with no window open to hold one.
@MainActor
enum ForceEjectPrompt {
    static func confirm(volume: String, detail: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(volume)” is in use and was not ejected"
        alert.informativeText = """
            \(detail)

            Force Eject takes the volume away from whatever is using it. \
            Anything those apps have not saved is lost, and a file being \
            written at that moment can be left incomplete.
            """
        alert.addButton(withTitle: "Cancel")
        let force = alert.addButton(withTitle: "Force Eject")
        force.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
