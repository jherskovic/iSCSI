//
//  AutoAttacher.swift
//  Attaching marked targets after a login launch, silently, for five minutes.
//
//  Storage is often not reachable the moment a user logs in — Wi-Fi still
//  joining, the NAS still booting after a power cut — so each marked target is
//  retried every 15 s for up to 5 min with nothing on screen. Only what is still
//  unattached after that is shown: the main window opens with a warning on those
//  rows.
//
//  The run itself is `AutoAttachDriver`, in iSCSIKit, where it is tested; this
//  is its host — the app's state, the attach path, the window, the copy, and
//  App Nap. Each attempt runs the whole path — setup, connection test, mount —
//  because any of the daemon, the network and `fskit_agent` can be late at
//  login.
//
//  See docs/superpowers/specs/2026-10-22-auto-attach-at-login-design.md.
//

import Foundation
import iSCSIKit
import os

private let autoAttachLog = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "autoattach")

@MainActor
final class AutoAttacher: AutoAttachHost {
    static let inUseMessage = "In use by another session on this Mac."
    static let inUseSuggestion = "Attaching it from two accounts at once would corrupt it. "
        + "Eject it in the other account, then attach it here."
    static let stillAttachingMessage = "Still trying to attach after 5 minutes."
    static let stillAttachingSuggestion = "It will appear by itself if the target answers. "
        + "Otherwise check the target and press Attach."
    static let setupMessage = "Setup is not finished."
    static let setupSuggestion = "Open the Setup screen to see what is missing."

    static func failureTitle(_ name: String) -> String {
        "Could not attach “\(name)” at login"
    }

    private unowned let model: AppModel
    private lazy var driver = AutoAttachDriver(host: self, clock: ContinuousClock())
    /// Keeps App Nap off for the run. A windowless app in the background is
    /// napped within seconds, and its 15 s sleeps stretch to minutes: measured
    /// 2026-10-22 on the 26.6 VM, a run whose attempts made no XPC call went
    /// silent 3 s after RunningBoard enabled App Nap.
    private var activity: NSObjectProtocol?

    init(model: AppModel) { self.model = model }

    func start(onFinish: @escaping @MainActor () -> Void) { driver.start(onFinish: onFinish) }

    /// The user acted on this target — attached, detached, removed or unchecked
    /// it. It is never tried again by this run and is not a failure.
    func cancel(targetID id: String) { driver.cancel(targetID: id) }

    /// The app is being removed: stop for good, without the window or
    /// Sparkle. Attempts already in flight finish; nothing new starts.
    func cancelAll() { driver.cancelAll() }

    // MARK: - AutoAttachHost

    func readTargets() async -> Bool {
        if await model.refresh(reportingErrors: false), model.isReady { return true }
        autoAttachLog.notice("target list not readable yet; setup ready: \(self.model.isReady)")
        return false
    }

    var targets: [TargetRecord] { model.targets }

    /// Half-attached (FSKit mount up, no device) does not count: attach is
    /// idempotent and completes it.
    var attachedTargetIDs: Set<String> {
        Set(model.attachments.attachments.filter { $0.device != nil }.map(\.targetID))
    }

    func isBusy(_ targetID: String) -> Bool { model.busy.contains(targetID) }

    func ensureSetupReady() async -> Bool {
        if !model.isReady { await model.setup.checkAll() }
        return model.isReady
    }

    func mountTable() -> [MountTableEntry] { AttachmentManager.mountTable() }

    var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func attach(_ target: TargetRecord) async -> PresentableError? {
        do {
            _ = try await model.withBusy(target.id) { try await model.performAttach(target) }
            return nil
        } catch {
            return AppModel.presentable(error, title: Self.failureTitle(target.displayName))
        }
    }

    func failure(_ kind: AutoAttachFailureKind, displayName: String) -> PresentableError {
        let title = Self.failureTitle(displayName)
        switch kind {
        case .setupNotReady:
            return PresentableError(title: title, message: Self.setupMessage,
                                    suggestion: Self.setupSuggestion)
        case .inUseElsewhere:
            return PresentableError(title: title, message: Self.inUseMessage,
                                    suggestion: Self.inUseSuggestion)
        case .stillAttaching:
            return PresentableError(title: title, message: Self.stillAttachingMessage,
                                    suggestion: Self.stillAttachingSuggestion)
        }
    }

    func message(of failure: PresentableError) -> String { failure.message }

    func recordFailures(_ failures: [String: PresentableError]) {
        model.recordAutoAttachFailures(failures)
    }

    func clearFailure(for targetID: String) { model.clearAutoAttachFailure(for: targetID) }

    func hasRecordedFailure(for targetID: String) -> Bool {
        model.autoAttachFailures[targetID] != nil
    }

    /// The flag alone is not enough here: the run ends with the app in the
    /// background, where a hidden menu bar item's label is never evaluated.
    /// See `MainWindowURL`.
    func showWindow() {
        model.wantsMainWindow = true
        MainWindowURL.open()
    }

    func beginActivity() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Attaching storage at login")
    }

    func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func log(_ message: String) { autoAttachLog.notice("\(message, privacy: .public)") }
}
