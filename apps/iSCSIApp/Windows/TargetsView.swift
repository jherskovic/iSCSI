//
//  TargetsView.swift
//  The screen people spend their time in, laid out like System Settings'
//  Network pane: iSCSI and NVMe/TCP each in a group of their own, a row per
//  target with its state and an Attach/Detach button, and + and − at the
//  foot of each group.
//

import AppKit
import ServiceManagement
import SwiftUI
import iSCSIKit

/// Which group a target sits in, and which protocol a new one starts on.
/// Read off the name's prefix like everywhere else — there is no stored
/// discriminator to consult.
private enum TargetKind: String, CaseIterable, Identifiable {
    case iSCSI, nvme
    var id: String { rawValue }
    var isNVMe: Bool { self == .nvme }
    var title: String { isNVMe ? "NVMe/TCP" : "iSCSI" }
}

struct TargetsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: TargetRecord?
    @State private var adding: TargetKind?
    /// What a group's − acts on. One selection across both groups, as in
    /// System Settings; a group's − is live only when it holds it.
    @State private var selection: String?
    /// Waiting on the Remove confirmation.
    @State private var removing: TargetRecord?

    var body: some View {
        let rows = model.rows
        Group {
            if rows.isEmpty && model.isAwaitingFirstRead {
                ProgressView(String(localized: "Loading targets…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty && !model.isReady {
                notReady
            } else {
                Form {
                    ForEach(TargetKind.allCases) { kind in
                        section(kind, rows: rows.filter { $0.target.isNVMe == kind.isNVMe })
                    }
                    let orphans = model.orphans
                    if !orphans.isEmpty {
                        orphanSection(orphans)
                    }
                }
                .formStyle(.grouped)
                .alert(removing.map { String(localized: "Remove “\($0.displayName)”?") } ?? "",
                       isPresented: Binding(get: { removing != nil },
                                            set: { if !$0 { removing = nil } }),
                       presenting: removing) { target in
                    Button(String(localized: "Remove"), role: .destructive) {
                        if selection == target.id { selection = nil }
                        Task { await model.delete(target) }
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: { target in
                    Text(removalMessage(for: target))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.targets.contains(where: \.autoAttach) && model.loginItemStatus != .enabled {
                LoginItemBanner(model: model)
            }
        }
        .navigationTitle(String(localized: "Targets"))
        // A removed target takes its selection with it, or the − would stay
        // live for a row that is no longer there.
        .onChange(of: model.targets.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .sheet(item: $adding) { kind in
            TargetEditor(model: model, target: nil, nvme: kind.isNVMe)
        }
        .sheet(item: $editing) { target in
            TargetEditor(model: model, target: target)
        }
        // Detach on a target whose volume is mounted: offer to eject rather
        // than refuse or rip. A mounted volume can have live writers — a
        // running VM, most likely. If one still has files open, the eject is
        // refused and forcing it is a second question (`ForceEjectPrompt`).
        .alert(item: $model.pendingDetach) { target in
            Alert(
                title: Text("Eject “\(target.displayName)”?"),
                message: Text(String(localized: "Its volume is still mounted. Detaching will eject the volume first; anything still using files on it — a running virtual machine, an open document — should be shut down before continuing.")),
                primaryButton: .default(Text(String(localized: "Eject and Detach"))) {
                    Task { await model.detach(target, ejectingMounted: true) }
                },
                secondaryButton: .cancel())
        }
    }

    /// One protocol's group. Both are always shown, empty or not: each one's
    /// + is the way to add that protocol, and "NVMe/TCP is over here" is
    /// worth saying to someone who has only ever added iSCSI.
    private func section(_ kind: TargetKind, rows: [AppModel.Row]) -> some View {
        Section(kind.title) {
            if rows.isEmpty {
                Text("No \(kind.title) targets")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(rows) { row in
                TargetRow(row: row, model: model, isSelected: selection == row.id,
                          edit: { editing = row.target },
                          remove: { removing = row.target })
                    .contentShape(Rectangle())
                    .onTapGesture { selection = row.id }
            }
            addRemoveBar(kind, selected: rows.first { $0.id == selection })
        }
    }

    /// Disks this app attached that no target accounts for any more: the
    /// target was edited while attached, or removed. Shown only when there
    /// are some, so they can be ejected — before, they stayed mounted with
    /// nothing in the app that could reach them.
    private func orphanSection(_ orphans: [Attachment]) -> some View {
        Section {
            ForEach(orphans) { orphan in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.orange.gradient,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppModel.orphanTitle(orphan))
                        Text(orphanSubtitle(orphan))
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if model.busy.contains(orphan.tag) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(String(localized: "Eject")) { Task { await model.detachOrphan(orphan) } }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(String(localized: "Other Attached Disks"))
        } footer: {
            Text(String(localized: "Attached under a target's earlier address, name or LUN, or for a target that has since been removed."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func orphanSubtitle(_ orphan: Attachment) -> String {
        guard let unit = orphan.mountSource.flatMap(AutoAttachRun.mountedUnit) else {
            return orphan.hiddenPath
        }
        let what = orphan.volumePaths.isEmpty
            ? "\(unit.name) \(unit.isNVMe ? String(localized: "namespace") : "LUN") \(unit.unit)"
            : orphan.volumePaths.joined(separator: ", ")
        return "\(what) — \(unit.portal)"
    }

    /// + and −, at the foot of the group as in System Settings. − removes the
    /// selected row, after asking.
    private func addRemoveBar(_ kind: TargetKind, selected: AppModel.Row?) -> some View {
        HStack(spacing: 2) {
            Button {
                adding = kind
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 18)
            }
            .disabled(!model.isReady)
            // Explaining the disabled control beats leaving the user to guess
            // why the only button on an empty screen does nothing.
            .help(model.isReady ? String(localized: "Add an \(kind.title) target")
                                : String(localized: "Finish setup before adding targets"))
            .accessibilityLabel("Add \(kind.title) Target")

            Divider().frame(height: 14)

            Button {
                removing = selected?.target
            } label: {
                Image(systemName: "minus").frame(width: 22, height: 18)
            }
            // Not mid-attach: `AppModel.delete` refuses then, and a button
            // that does nothing when clicked is worse than a disabled one.
            .disabled(selected == nil || selected?.isBusy == true)
            .help(selected.map { String(localized: "Remove “\($0.target.displayName)”") }
                  ?? String(localized: "Select a \(kind.title) target to remove it"))
            .accessibilityLabel("Remove \(kind.title) Target")

            Spacer()
        }
        .buttonStyle(.borderless)
    }

    /// Removing a mounted target ejects it first (`AppModel.delete`), so the
    /// confirmation says so in the same words as Detach's; otherwise it says
    /// what goes, which includes a stored CHAP secret.
    private func removalMessage(for target: TargetRecord) -> String {
        let mounted = model.rows.first { $0.id == target.id }?.attachment != nil
        if mounted {
            return String(localized: "Its volume is still mounted and will be ejected first; anything still using files on it — a running virtual machine, an open document — should be shut down before continuing.")
        }
        return target.chapUser == nil
            ? String(localized: "Its settings are removed from this Mac. Nothing on the target changes.")
            : String(localized: "Its settings and saved CHAP secret are removed from this Mac. Nothing on the target changes.")
    }

    /// With setup unfinished and nothing configured, two empty groups with
    /// disabled + buttons would say nothing about why.
    private var notReady: some View {
        ContentUnavailableView {
            Label(String(localized: "No Targets"), systemImage: "externaldrive.badge.plus")
        } description: {
            Text(String(localized: "Finish setup first — the background service and filesystem extension have to be running before a target can be attached."))
        }
    }
}

/// A target is marked "Attach at login" but the app will not be launched at
/// login. A checked box that silently does nothing is the failure this exists
/// to prevent. Styled like the menu's setup banner: something to do, not an
/// error.
private struct LoginItemBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button(buttonTitle, action: act)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var text: String {
        if !LoginItem.canRegisterFromHere {
            return String(localized: "Attach at login needs the app in /Applications.")
        }
        if model.loginItemStatus == .requiresApproval {
            return String(localized: "Attach at login is turned off in System Settings.")
        }
        return String(localized: "iSCSI/NVMe/TCP Initiator is not set to open at login, so nothing will attach.")
    }

    private var buttonTitle: String {
        if !LoginItem.canRegisterFromHere { return String(localized: "Show in Finder") }
        if model.loginItemStatus == .requiresApproval { return String(localized: "Open Login Items…") }
        return String(localized: "Turn On")
    }

    private func act() {
        if !LoginItem.canRegisterFromHere {
            Task { await InstallLocation().perform() }
        } else if model.loginItemStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else {
            model.turnOnLoginItem()
        }
    }
}

private struct TargetRow: View {
    let row: AppModel.Row
    @ObservedObject var model: AppModel
    let isSelected: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Coloured while attached and grey otherwise, as Network does for
            // services; the dot below carries the finer state.
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(row.isAttached ? AnyShapeStyle(Color.accentColor.gradient)
                                           : AnyShapeStyle(Color.gray.gradient),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.target.displayName)
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
            }
            .help(failure.map { [$0.message, $0.suggestion].compactMap { $0 }
                .joined(separator: "\n\n") } ?? "")

            Spacer()

            if row.isBusy {
                ProgressView().controlSize(.small)
            } else if row.attachment != nil {
                // Any layer up is something to detach: a blank LUN's raw
                // device, or what a refused detach left listed.
                if row.isAttached {
                    Button(String(localized: "Reveal")) { model.reveal(row) }
                        .buttonStyle(.link)
                }
                Button(String(localized: "Detach")) { Task { await model.detach(row.target) } }
            } else {
                Button(String(localized: "Attach")) { Task { await model.attach(row.target) } }
                    .disabled(!model.isReady)
            }

            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Edit “\(row.target.displayName)”")
            .accessibilityLabel("Edit \(row.target.displayName)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, -6)
        .contextMenu {
            Button(String(localized: "Edit…"), action: edit)
            Button(String(localized: "Remove…"), role: .destructive, action: remove)
                .disabled(row.isBusy)
        }
    }

    /// Set only while the target is not attached: a warning about a volume
    /// that is plainly mounted would be stale.
    private var failure: PresentableError? {
        row.isAttached ? nil : row.autoAttachFailure
    }

    /// The dot: green mounted, yellow connected but not mounted, red failed
    /// at login, grey idle — Network's vocabulary, mapped onto ours.
    private enum Status {
        case on, partial, failed, off
        var color: Color {
            switch self {
            case .on:      .green
            case .partial: .yellow
            case .failed:  .red
            case .off:     .gray
            }
        }
    }

    private var status: Status {
        if row.isAttached { return .on }
        if failure != nil { return .failed }
        if row.attachment != nil || row.session != nil { return .partial }
        return .off
    }

    /// Says the most useful true thing available: where it is mounted if it is,
    /// why it did not attach at login, its size if connected, and otherwise
    /// where it lives.
    private var subtitle: String {
        if let path = row.volumePath { return path }
        if let failure { return String(localized: "Could not attach at login — \(failure.message)") }
        if let attachment = row.attachment, let device = attachment.device {
            if let locked = attachment.lockedVolumes.first {
                return String(localized: "connected as \(device) — “\(locked)” is encrypted and locked")
            }
            return attachment.isBlank == true
                ? String(localized: "connected as \(device) — not formatted yet")
                : String(localized: "connected as \(device) — no volume mounted")
        }
        if let bytes = row.session?.byteCount {
            return "\(row.target.host) — "
                 + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        return "\(row.target.host):\(row.target.port) · \(row.target.isNVMe ? "NSID" : "LUN") \(row.target.lun)"
    }
}

// MARK: - Editor

struct TargetEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let existing: TargetRecord?
    @State private var displayName: String
    @State private var host: String
    @State private var port: String
    @State private var targetIQN: String
    @State private var lun: String
    @State private var chapUser: String
    @State private var chapSecret: String
    @State private var mutualChapUser: String
    @State private var mutualChapSecret: String
    @State private var hasStoredSecret = false
    @State private var hasStoredMutualSecret = false
    /// This Mac's NVMe host NQN and iSCSI initiator IQN, from the daemon, for
    /// the user to copy into a subsystem's allowed hosts or a target's allowed
    /// initiators. nil until fetched, or on an old daemon. From the daemon
    /// rather than recomputed here: the IQN follows the computer name as it
    /// was when the daemon started, and only the daemon knows that.
    @State private var hostNQN: String?
    @State private var initiatorName: String?

    /// nil = FUA on every write, N > 0 = flush every N seconds, 0 = never.
    /// Mirrors `TargetRecord.flushIntervalSeconds` exactly.
    @State private var flushInterval: Int?
    /// The selection waiting on the disclaimer. The picker itself is reverted
    /// while the dialog is up, so cancelling costs nothing and confirming
    /// re-applies this.
    @State private var pendingFlushInterval: Int?
    @State private var showingFlushDisclaimer = false
    /// Set around programmatic picker changes (the revert and the confirm) so
    /// `onChange` only prompts for changes the user made.
    @State private var suppressFlushPrompt = false
    /// nil = Automatic. Mirrors `TargetRecord.networkInterface`.
    @State private var networkInterface: String?
    /// Prefer (true) or strict (false); stored only when an interface is set.
    @State private var interfaceFallback: Bool
    /// nil = off. Mirrors `TargetRecord.localCacheGB` for valid sizes.
    @State private var localCacheGB: Int?
    /// Mirrors `TargetRecord.autoAttach`.
    @State private var autoAttach: Bool
    /// The target's own answer to "which LUN?", from Find: REPORT LUNS (or
    /// the namespace list) with sizes. nil until asked. A Synology maps its
    /// first LUN at 1, and typing the default 0 there attaches a 32 KiB
    /// placeholder — the picker exists so the number comes from the target.
    @State private var foundUnits: [LUNInfo]?
    @State private var findingUnits = false
    @State private var findNote: String?
    @State private var findFailed = false

    /// `nvme` is the protocol a *new* target starts on — which list's + was
    /// clicked. An existing target's protocol is its name's, and `nvme` is
    /// ignored.
    init(model: AppModel, target: TargetRecord?, nvme: Bool = false) {
        self.model = model
        self.existing = target
        _displayName = State(initialValue: target?.displayName ?? "")
        // A new target starts at the last address used for its protocol; an
        // existing one always shows its own. Pre-filling an edit sheet with
        // someone else's address would be a data-loss bug wearing a
        // convenience costume.
        _host = State(initialValue: target?.host ?? LastPortal.suggestedHost(nvme: nvme))
        _port = State(initialValue: String(target?.port ?? LastPortal.port(nvme: nvme)))
        // A new NVMe/TCP target starts exactly where flipping the picker
        // would leave it: the bare prefix (which Save refuses until it is
        // completed) and namespace 1, since namespace IDs start there.
        _targetIQN = State(initialValue: target?.targetIQN ?? (nvme ? "nqn." : ""))
        _lun = State(initialValue: String(target?.lun ?? (nvme ? 1 : 0)))
        _chapUser = State(initialValue: target?.chapUser ?? "")
        _mutualChapUser = State(initialValue: target?.mutualChapUser ?? "")
        _chapSecret = State(initialValue: "")
        _mutualChapSecret = State(initialValue: "")
        _flushInterval = State(initialValue: target?.flushIntervalSeconds)
        _networkInterface = State(initialValue: target?.interfaceBinding?.name)
        _interfaceFallback = State(initialValue: target?.interfaceFallback ?? false)
        // A hand-edited out-of-range size shows as Off, which is what it is.
        _localCacheGB = State(initialValue: (target?.localCacheBytes ?? 0) > 0 ? target?.localCacheGB : nil)
        _autoAttach = State(initialValue: target?.autoAttach ?? false)
    }

    /// The protocol is the name's prefix and nothing else: `nqn.` is
    /// NVMe/TCP. Only a new target's can be chosen, and its picker is a view
    /// onto that fact, not a second field — flipping it rewrites the prefix.
    /// An existing target's protocol is its record's, whatever is typed:
    /// a name that would change it is refused (`protocolChanged`), not
    /// followed.
    private var isNVMe: Bool { existing?.isNVMe ?? IQN.isNQN(targetIQN) }

    /// Address, port, name and unit are what a mounted volume is found by
    /// (`MountpointTag`): changed under an attached target, the app loses the
    /// volume, and the next attach is a second writer on the same disk. So
    /// they are fixed while this target is attached here or has a session: an
    /// attach still connecting, which an edit would orphan just the same, or
    /// another account's, which the app cannot tell from one. `AppModel.save`
    /// enforces the same rule.
    private var identityLocked: Bool {
        guard let existing, let row = model.rows.first(where: { $0.id == existing.id }) else {
            return false
        }
        return row.attachment != nil || row.session != nil
    }

    private var identityLockNote: String? {
        guard identityLocked, let existing,
              let row = model.rows.first(where: { $0.id == existing.id }) else { return nil }
        return row.attachment != nil
            ? String(localized: "Detach to change the address, port, name or \(isNVMe ? String(localized: "namespace") : "LUN").")
            : String(localized: "Connected — attached in another account, or still connecting — so the address, port, name and \(isNVMe ? String(localized: "namespace") : "LUN") can't change.")
    }

    /// The name this Mac presents for the protocol being edited.
    private var hostIdentity: String? { isNVMe ? hostNQN : initiatorName }

    /// A new target's protocol choice. Its portal came from LastPortal, so it
    /// moves to the other protocol's remembered one, as Discover's does, and
    /// the unit number follows only while it is still the other default.
    private var protocolPicker: Binding<Bool> {
        Binding(get: { isNVMe }, set: { nvme in
            guard nvme != isNVMe else { return }
            let trimmed = targetIQN.trimmingCharacters(in: .whitespaces)
            LastPortal.switchProtocol(host: &host, port: &port, from: !nvme, to: nvme)
            if nvme {
                targetIQN = trimmed.hasPrefix("iqn.") || trimmed.isEmpty ? "nqn." : trimmed
                if lun == "0" { lun = "1" }
            } else {
                targetIQN = trimmed == "nqn." ? "" : trimmed
                if lun == "1" { lun = "0" }
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if existing == nil {
                        Picker(String(localized: "Protocol"), selection: protocolPicker) {
                            Text("iSCSI").tag(false)
                            Text("NVMe/TCP").tag(true)
                        }
                        .pickerStyle(.segmented)
                    } else {
                        // Shown, not offered: the other protocol is a new
                        // target, added from its own list.
                        LabeledContent(String(localized: "Protocol")) {
                            Text(isNVMe ? "NVMe/TCP" : "iSCSI").bold()
                        }
                    }
                    TextField(String(localized: "Name"), text: $displayName, prompt: Text(String(localized: "Photos archive")))
                    Group {
                        TextField(String(localized: "Address"), text: $host, prompt: Text("nas.local"))
                        TextField(String(localized: "Port"), text: $port)
                        TextField(isNVMe ? String(localized: "Subsystem NQN") : String(localized: "Target"), text: $targetIQN,
                                  prompt: Text(isNVMe ? "nqn.2011-06.com.truenas:uuid:…:disk0"
                                                      : "iqn.2026-08.com.example:disk0"))
                    }
                    .disabled(identityLocked)
                    if protocolChanged {
                        Text(isNVMe
                             ? String(localized: "An NVMe/TCP subsystem name starts with “nqn.”. For an iSCSI target, add one under iSCSI.")
                             : String(localized: "That is an NVMe/TCP subsystem name. Add it under NVMe/TCP instead."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let lockNote = identityLockNote {
                        Text(lockNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField(isNVMe ? String(localized: "Namespace ID") : String(localized: "LUN"), text: $lun)
                            .disabled(identityLocked)
                        if let foundUnits, !foundUnits.isEmpty {
                            Menu(String(localized: "Choose")) {
                                ForEach(foundUnits, id: \.lun) { unit in
                                    Button(unitTitle(unit)) { lun = String(unit.lun) }
                                }
                            }
                            .fixedSize()
                            .disabled(identityLocked)
                        }
                        Button(String(localized: "Find")) { findUnits() }
                            .disabled(findingUnits || !canFindUnits || identityLocked)
                            .help(credentialIncomplete
                                  ? String(localized: "Enter the CHAP secret first.")
                                  : unitsHelp)
                    }
                    if findingUnits {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "Asking the target…"))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else if let findNote {
                        Text(findNote)
                            .font(.caption)
                            .foregroundStyle(findFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }

                Section {
                    InterfacePicker(name: $networkInterface, fallback: $interfaceFallback)
                } header: {
                    Text(String(localized: "Network"))
                } footer: {
                    Text(String(localized: "Takes effect the next time this target is attached."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle(String(localized: "Attach at login"), isOn: $autoAttach)
                } footer: {
                    Text(String(localized: "Attaches by itself when you log in to this Mac. If the target can't be reached, keeps trying for 5 minutes, then shows a warning here."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section(String(localized: "Access")) {
                    // Both protocols gate on the name this Mac presents — a
                    // subsystem by host NQN, a target (optionally) by initiator
                    // IQN — so what to show here is ours. Only iSCSI has CHAP
                    // on top; that is the next section.
                    HStack {
                        Text(isNVMe ? String(localized: "This Mac's host NQN") : String(localized: "This Mac's initiator IQN"))
                        Spacer()
                        Text(hostIdentity ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        if let hostIdentity {
                            Button(String(localized: "Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hostIdentity, forType: .string)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    // The IQN caption says it follows the computer name because
                    // that is the one way it moves: a rename changes it at the
                    // next daemon start, and an allow-list keyed on the old
                    // name then refuses this Mac. The NQN is UUID-derived and
                    // has no such clause to earn.
                    Text(isNVMe
                         ? String(localized: "Add it to the subsystem's allowed hosts on the storage device, or allow any host there. Namespace IDs start at 1.")
                         : String(localized: "Add it to the target's allowed initiators on the storage device, or allow any initiator there. It follows this Mac's name, so renaming the Mac changes it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !isNVMe {
                    Section(String(localized: "Authentication")) {
                        TextField(String(localized: "CHAP user"), text: $chapUser)
                        SecureField(hasStoredSecret ? String(localized: "Saved — type to replace") : String(localized: "CHAP secret"),
                                    text: $chapSecret)
                        // Enforced, not just advised. RFC 7143 §12.1.1 sets 12 bytes
                        // as the floor, and the error a target returns for a short
                        // secret says only "authentication failure", which sends
                        // people looking in the wrong place.
                        Text(String(localized: "Secrets must be at least 12 characters."))
                            .font(.caption)
                            .foregroundStyle(secretTooShort ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }

                // Hidden while CHAP.mutualIsOffered is false. The fields are
                // gated rather than deleted because nothing here is wrong: the
                // exchange is correct on the wire and the only target available
                // to test against will not answer a challenge. See the note on
                // CHAP.mutualIsOffered.
                if CHAP.mutualIsOffered && !isNVMe {
                Section(String(localized: "Verify the target")) {
                    TextField(String(localized: "Mutual CHAP user"), text: $mutualChapUser,
                              prompt: Text(String(localized: "optional")))
                    SecureField(hasStoredMutualSecret ? String(localized: "Saved — type to replace")
                                                      : String(localized: "Mutual CHAP secret"),
                                text: $mutualChapSecret)
                    // Its own section because it does the opposite job to the
                    // one above: that proves who we are to the target, this
                    // proves the target is the machine we think it is. On a
                    // plaintext link it is the only thing that would catch a
                    // stand-in feeding this Mac a fabricated disk.
                    Text(mutualHalfConfigured
                         ? String(localized: "Enter the secret too, or clear the user — a name on its own does not verify anything.")
                         : String(localized: "Optional. Proves the target is who it claims to be."))
                        .font(.caption)
                        .foregroundStyle(mutualHalfConfigured ? AnyShapeStyle(.red)
                                                              : AnyShapeStyle(.secondary))
                }
                }

                Section(String(localized: "Write safety")) {
                    Picker(String(localized: "Commit writes"), selection: $flushInterval) {
                        Text(String(localized: "On every write — safest")).tag(Int?.none)
                        ForEach([1, 5, 10, 30, 60], id: \.self) { seconds in
                            Text(seconds == 1 ? String(localized: "Every second") : String(localized: "Every \(seconds) seconds"))
                                .tag(Int?.some(seconds))
                        }
                        Text(String(localized: "Never — target cache is non-volatile")).tag(Int?.some(0))
                    }
                    Text(flushInterval == nil
                         ? String(localized: "Each write is on stable media before it is acknowledged.")
                         : String(localized: "⚠ If the target loses power, this volume can be corrupted. Takes effect the next time this target is attached."))
                        .font(.caption)
                        .foregroundStyle(flushInterval == nil ? AnyShapeStyle(.secondary)
                                                              : AnyShapeStyle(.red))
                }

                Section {
                    Picker(String(localized: "Size"), selection: $localCacheGB) {
                        Text(String(localized: "Off")).tag(Int?.none)
                        ForEach(1 ... 16, id: \.self) { gb in
                            Text("\(gb) GB").tag(Int?.some(gb))
                        }
                    }
                } header: {
                    Text(String(localized: "Local cache"))
                } footer: {
                    Text(String(localized: "Kept on this Mac's disk, encrypted, only while the target is attached. Takes effect the next time it is attached."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onChange(of: flushInterval) { old, new in
                if suppressFlushPrompt { suppressFlushPrompt = false; return }
                // Tightening to FUA never needs a warning; every loosening
                // does, even from one relaxed setting to another.
                guard new != nil else { return }
                pendingFlushInterval = new
                suppressFlushPrompt = true
                flushInterval = old
                showingFlushDisclaimer = true
            }
            .alert(String(localized: "Give up per-write durability?"), isPresented: $showingFlushDisclaimer) {
                Button(String(localized: "Cancel"), role: .cancel) { pendingFlushInterval = nil }
                Button(String(localized: "Accept the Risk"), role: .destructive) {
                    suppressFlushPrompt = true
                    flushInterval = pendingFlushInterval
                    pendingFlushInterval = nil
                }
            } message: {
                Text(flushDisclaimer)
            }

            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 460)
        .task {
            // Fresh, for `identityLocked`: a session from a detach a moment
            // ago may still be in the list.
            if existing != nil { await model.refreshSessions() }
            if let id = existing?.id {
                hasStoredSecret = (try? await DaemonConnection.hasCHAPSecret(targetID: id)) ?? false
                hasStoredMutualSecret =
                    (try? await DaemonConnection.hasMutualCHAPSecret(targetID: id)) ?? false
            }
            if let info = try? await DaemonConnection.info() {
                hostNQN = info.hostNQN
                initiatorName = info.initiatorName
            }
        }
    }

    /// The words are chosen against the comfortable misreading. "You may lose
    /// the last N seconds" is what people expect this to mean, and it is
    /// wrong: without FUA the target commits cached writes in whatever order
    /// it likes, so a power cut can corrupt the volume's structure — the
    /// interval bounds how *stale* the disk can be, not how broken.
    private var flushDisclaimer: String {
        let cadence = switch pendingFlushInterval {
        case .some(0):
            String(localized: "No flushes will be sent while attached — only when the volume is detached.")
        case .some(let seconds):
            seconds == 1
                ? String(localized: "Cached writes will be committed every second and when the volume is detached.")
                : String(localized: "Cached writes will be committed every \(seconds) seconds and when the volume is detached.")
        default:
            ""
        }
        return String(localized: "Writes will be acknowledged while they are still in the target's volatile cache. ") + cadence
            + String(localized: "\n\nIf the target loses power, uncommitted writes are lost out of order — which can corrupt the volume's structure, not just recent files. Choose this only if the target's cache is protected: battery-backed, on a UPS, or with its write cache disabled.")
    }

    /// A secret was typed and is too short. Only checks what was typed: an
    /// already-stored secret is not readable from here, and re-prompting for one
    /// the user cannot see would be unanswerable.
    private var secretTooShort: Bool {
        (!chapSecret.isEmpty && chapSecret.utf8.count < 12)
            || (!mutualChapSecret.isEmpty && mutualChapSecret.utf8.count < 12)
    }

    /// A CHAP user with no secret, stored or typed — the state that used to save
    /// happily and then fail at login, or worse, log in with no authentication.
    private var credentialIncomplete: Bool {
        !chapUser.trimmingCharacters(in: .whitespaces).isEmpty
            && chapSecret.isEmpty && !hasStoredSecret
    }

    /// Mutual CHAP with a name but no secret. The daemon refuses this rather
    /// than quietly falling back to one-way, so catching it here turns a failed
    /// attach into a disabled Save button.
    ///
    /// False outright while the fields are hidden. A record saved when mutual
    /// CHAP was still offered can carry a user with no stored secret, and that
    /// would disable Save with the explanation invisible — a dead button and
    /// nothing on screen saying why.
    private var mutualHalfConfigured: Bool {
        guard CHAP.mutualIsOffered else { return false }
        return !mutualChapUser.trimmingCharacters(in: .whitespaces).isEmpty
            && mutualChapSecret.isEmpty && !hasStoredMutualSecret
    }

    /// An NQN that is only its prefix, or an NVMe namespace 0 (reserved),
    /// would fail at attach with an error that points elsewhere.
    private var nvmeIncomplete: Bool {
        guard isNVMe else { return false }
        return targetIQN.trimmingCharacters(in: .whitespaces) == "nqn." || UInt64(lun) == 0
    }

    /// An existing target's name retyped into the other protocol's: an NQN
    /// on an iSCSI target, or anything else on an NVMe/TCP one. The name is
    /// the only thing that says which protocol a record is, so saving this
    /// would switch protocols by the route the picker no longer offers.
    private var protocolChanged: Bool {
        guard let existing else { return false }
        return IQN.isNQN(targetIQN.trimmingCharacters(in: .whitespaces)) != existing.isNVMe
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !TargetPortal.host(typed: host).isEmpty
            && !targetIQN.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil && UInt64(lun) != nil
            && !nvmeIncomplete && !protocolChanged
            && !secretTooShort && !credentialIncomplete && !mutualHalfConfigured
    }

    /// Enough to open a session: the portal fields, a name, and no CHAP user
    /// waiting on a secret. Saving is not required — like Discover, this runs
    /// before the record exists.
    private var canFindUnits: Bool {
        !TargetPortal.host(typed: host).isEmpty
            && UInt16(port) != nil
            && !targetIQN.trimmingCharacters(in: .whitespaces).isEmpty
            && targetIQN.trimmingCharacters(in: .whitespaces) != "nqn."
            && !protocolChanged
            && !credentialIncomplete && !secretTooShort
    }

    private func unitTitle(_ unit: LUNInfo) -> String {
        let number = "\(isNVMe ? String(localized: "Namespace") : "LUN") \(unit.lun)"
        guard let bytes = unit.byteCount else { return number }
        return number + " — " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var unitsHelp: String {
        let kind = isNVMe ? String(localized: "namespaces") : String(localized: "LUNs")
        return String(localized: "Ask the target which \(kind) it has.")
    }

    /// Ask the target what it has. One answer fills the field outright; more
    /// than one goes in the Choose menu, with a note when the typed number
    /// is not among them. Errors land inline, like Discover's: the fields
    /// to fix are right here.
    private func findUnits() {
        findingUnits = true
        findNote = nil
        findFailed = false
        let asked = (host: TargetPortal.host(typed: host),
                     port: UInt16(port) ?? LastPortal.defaultPort(nvme: isNVMe),
                     name: targetIQN.trimmingCharacters(in: .whitespaces),
                     isNVMe: isNVMe)
        let typedUser = chapUser.trimmingCharacters(in: .whitespaces)
        let interface = InterfaceBinding.named(networkInterface, fallback: interfaceFallback)
        Task {
            defer { findingUnits = false }
            do {
                let units = try await DaemonConnection.listUnits(
                    host: asked.host, port: asked.port, targetIQN: asked.name,
                    chapUser: (asked.isNVMe || typedUser.isEmpty) ? nil : typedUser,
                    chapSecret: (asked.isNVMe || chapSecret.isEmpty) ? nil : chapSecret,
                    interface: interface)
                foundUnits = units
                let word = asked.isNVMe ? String(localized: "namespace") : String(localized: "LUN")
                let numbers = units.map { String($0.lun) }.joined(separator: ", ")
                if units.isEmpty {
                    findFailed = true
                    findNote = String(localized: "The target reports no \(word)s.")
                } else if units.count == 1, let only = units.first {
                    lun = String(only.lun)
                    findNote = String(localized: "The target has one \(word): \(unitTitle(only)).")
                } else if units.contains(where: { String($0.lun) == lun }) {
                    findNote = String(localized: "The target has \(word)s \(numbers).")
                } else {
                    findFailed = true
                    findNote = String(localized: "The target has \(word)s \(numbers); \(lun) is not one of them. Choose one.")
                }
            } catch {
                foundUnits = nil
                findFailed = true
                let ns = error as NSError
                let details = LocalizedStorageError.details(ns)
                findNote = [details.message, details.suggestion]
                    .compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    private func save() {
        // The id is stable for the life of the target: the keychain item and the
        // mount point are both derived from it, so regenerating it on edit would
        // orphan the secret and strand the mount.
        // NVMe records carry no CHAP at all — nilled, not merely hidden, so a
        // record flipped from iSCSI does not keep a user the daemon would
        // then find no secret for.
        let record = TargetRecord(
            id: existing?.id ?? UUID().uuidString,
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            host: TargetPortal.host(typed: host),
            port: UInt16(port) ?? LastPortal.defaultPort(nvme: isNVMe),
            targetIQN: targetIQN.trimmingCharacters(in: .whitespaces),
            lun: UInt64(lun) ?? (isNVMe ? 1 : 0),
            chapUser: (isNVMe || chapUser.isEmpty) ? nil : chapUser,
            mutualChapUser: (isNVMe || mutualChapUser.isEmpty) ? nil : mutualChapUser,
            autoAttach: autoAttach,
            flushIntervalSeconds: flushInterval,
            networkInterface: networkInterface,
            interfaceFallback: networkInterface == nil ? nil : interfaceFallback,
            localCacheGB: localCacheGB)

        LastPortal.remember(host: record.host, port: record.port, nvme: isNVMe)
        Task {
            await model.save(record,
                             secret: (isNVMe || chapSecret.isEmpty) ? nil : chapSecret,
                             mutualSecret: (isNVMe || mutualChapSecret.isEmpty) ? nil : mutualChapSecret)
            dismiss()
        }
    }
}
