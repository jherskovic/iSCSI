//
//  TargetsView.swift
//  The list people spend their time in: one row per target, attach or detach.
//

import AppKit
import SwiftUI
import iSCSIKit

struct TargetsView: View {
    @ObservedObject var model: AppModel
    @State private var editing: TargetRecord?
    @State private var isAdding = false

    var body: some View {
        Group {
            if model.rows.isEmpty {
                empty
            } else {
                List {
                    ForEach(model.rows) { row in
                        TargetRow(row: row, model: model) { editing = row.target }
                    }
                }
            }
        }
        .navigationTitle("Targets")
        .toolbar {
            Button {
                isAdding = true
            } label: {
                Label("Add Target", systemImage: "plus")
            }
            .disabled(!model.isReady)
            // Explaining the disabled control beats leaving the user to guess
            // why the only button on an empty screen does nothing.
            .help(model.isReady ? "Add a target"
                                : "Finish setup before adding targets")
        }
        .sheet(isPresented: $isAdding) {
            TargetEditor(model: model, target: nil)
        }
        .sheet(item: $editing) { target in
            TargetEditor(model: model, target: target)
        }
        // Detach on a target whose volume is mounted: offer to eject rather
        // than refuse or rip. The layers below fall back to a force-eject, and
        // a mounted volume can have live writers — a running VM, most likely —
        // so the one thing that must not happen is doing that silently.
        .alert(item: $model.pendingDetach) { target in
            Alert(
                title: Text("Eject “\(target.displayName)”?"),
                message: Text("Its volume is still mounted. Detaching will eject "
                            + "the volume first; anything still using files on it "
                            + "— a running virtual machine, an open document — "
                            + "should be shut down before continuing."),
                primaryButton: .default(Text("Eject and Detach")) {
                    Task { await model.detach(target, ejectingMounted: true) }
                },
                secondaryButton: .cancel())
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Targets", systemImage: "externaldrive.badge.plus")
        } description: {
            Text(model.isReady
                 ? "Add the address of an iSCSI or NVMe/TCP target, or use Discover "
                 + "to find what a storage device is offering."
                 : "Finish setup first — the background service and filesystem "
                 + "extension have to be running before a target can be attached.")
        }
    }
}

private struct TargetRow: View {
    let row: AppModel.Row
    @ObservedObject var model: AppModel
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.isAttached ? "externaldrive.fill.badge.checkmark"
                                             : "externaldrive")
                .font(.title2)
                .foregroundStyle(row.isAttached ? .green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.target.displayName).fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if row.isBusy {
                ProgressView().controlSize(.small)
            } else if row.isAttached {
                Button("Reveal") { model.reveal(row) }
                    .buttonStyle(.link)
                Button("Detach") { Task { await model.detach(row.target) } }
            } else {
                Button("Attach") { Task { await model.attach(row.target) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isReady)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Remove", role: .destructive) {
                Task { await model.delete(row.target) }
            }
        }
    }

    /// Says the most useful true thing available: where it is mounted if it is,
    /// its size if connected, and otherwise where it lives.
    private var subtitle: String {
        if let path = row.volumePath { return path }
        if let device = row.attachment?.device {
            return "connected as \(device) — not formatted yet"
        }
        if let bytes = row.session?.byteCount {
            return "\(row.target.host) — "
                 + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        return "\(row.target.host):\(row.target.port) · "
             + "\(row.target.isNVMe ? "NSID" : "LUN") \(row.target.lun)"
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
    /// This Mac's NVMe host NQN, from the daemon, for the user to copy into
    /// a subsystem's allowed hosts. nil until fetched, or on an old daemon.
    @State private var hostNQN: String?

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

    init(model: AppModel, target: TargetRecord?) {
        self.model = model
        self.existing = target
        _displayName = State(initialValue: target?.displayName ?? "")
        // A new target starts at the last address used; an existing one always
        // shows its own. Pre-filling an edit sheet with someone else's address
        // would be a data-loss bug wearing a convenience costume.
        _host = State(initialValue: target?.host ?? LastPortal.suggestedHost)
        _port = State(initialValue: String(target?.port ?? LastPortal.port))
        _targetIQN = State(initialValue: target?.targetIQN ?? "")
        _lun = State(initialValue: String(target?.lun ?? 0))
        _chapUser = State(initialValue: target?.chapUser ?? "")
        _mutualChapUser = State(initialValue: target?.mutualChapUser ?? "")
        _chapSecret = State(initialValue: "")
        _mutualChapSecret = State(initialValue: "")
        _flushInterval = State(initialValue: target?.flushIntervalSeconds)
    }

    /// The protocol is the name's prefix and nothing else: `nqn.` is
    /// NVMe/TCP. The picker is a view onto that fact, not a second field —
    /// flipping it rewrites the prefix, and only touches the port and unit
    /// number when they still hold the other protocol's defaults.
    private var isNVMe: Bool { IQN.isNQN(targetIQN) }

    private var protocolPicker: Binding<Bool> {
        Binding(get: { isNVMe }, set: { nvme in
            guard nvme != isNVMe else { return }
            let trimmed = targetIQN.trimmingCharacters(in: .whitespaces)
            if nvme {
                targetIQN = trimmed.hasPrefix("iqn.") || trimmed.isEmpty ? "nqn." : trimmed
                if port == "3260" { port = "4420" }
                if lun == "0" { lun = "1" }
            } else {
                targetIQN = trimmed == "nqn." ? "" : trimmed
                if port == "4420" { port = "3260" }
                if lun == "1" { lun = "0" }
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Protocol", selection: protocolPicker) {
                        Text("iSCSI").tag(false)
                        Text("NVMe/TCP").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $displayName, prompt: Text("Photos archive"))
                    TextField("Address", text: $host, prompt: Text("nas.local"))
                    TextField("Port", text: $port)
                    TextField(isNVMe ? "Subsystem NQN" : "Target", text: $targetIQN,
                              prompt: Text(isNVMe ? "nqn.2011-06.com.truenas:uuid:…:disk0"
                                                  : "iqn.2026-08.com.example:disk0"))
                    TextField(isNVMe ? "Namespace ID" : "LUN", text: $lun)
                }

                if isNVMe {
                    Section("Access") {
                        // NVMe-oF has no CHAP. The subsystem decides by host
                        // NQN, so the one thing to show here is ours.
                        HStack {
                            Text("This Mac's host NQN")
                            Spacer()
                            Text(hostNQN ?? "—")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            if let hostNQN {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(hostNQN, forType: .string)
                                }
                                .buttonStyle(.link)
                            }
                        }
                        Text("Add it to the subsystem's allowed hosts on the storage device, "
                             + "or allow any host there. Namespace IDs start at 1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Authentication") {
                        TextField("CHAP user", text: $chapUser)
                        SecureField(hasStoredSecret ? "Saved — type to replace" : "CHAP secret",
                                    text: $chapSecret)
                        // Enforced, not just advised. RFC 7143 §12.1.1 sets 12 bytes
                        // as the floor, and the error a target returns for a short
                        // secret says only "authentication failure", which sends
                        // people looking in the wrong place.
                        Text("Secrets must be at least 12 characters.")
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
                Section("Verify the target") {
                    TextField("Mutual CHAP user", text: $mutualChapUser,
                              prompt: Text("optional"))
                    SecureField(hasStoredMutualSecret ? "Saved — type to replace"
                                                      : "Mutual CHAP secret",
                                text: $mutualChapSecret)
                    // Its own section because it does the opposite job to the
                    // one above: that proves who we are to the target, this
                    // proves the target is the machine we think it is. On a
                    // plaintext link it is the only thing that would catch a
                    // stand-in feeding this Mac a fabricated disk.
                    Text(mutualHalfConfigured
                         ? "Enter the secret too, or clear the user — a name on its "
                           + "own does not verify anything."
                         : "Optional. Proves the target is who it claims to be.")
                        .font(.caption)
                        .foregroundStyle(mutualHalfConfigured ? AnyShapeStyle(.red)
                                                              : AnyShapeStyle(.secondary))
                }
                }

                Section("Write safety") {
                    Picker("Commit writes", selection: $flushInterval) {
                        Text("On every write — safest").tag(Int?.none)
                        ForEach([1, 5, 10, 30, 60], id: \.self) { seconds in
                            Text("Every \(seconds) second\(seconds == 1 ? "" : "s")")
                                .tag(Int?.some(seconds))
                        }
                        Text("Never — target cache is non-volatile").tag(Int?.some(0))
                    }
                    Text(flushInterval == nil
                         ? "Each write is on stable media before it is acknowledged."
                         : "⚠ If the target loses power, this volume can be corrupted. "
                           + "Takes effect the next time this target is attached.")
                        .font(.caption)
                        .foregroundStyle(flushInterval == nil ? AnyShapeStyle(.secondary)
                                                              : AnyShapeStyle(.red))
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
            .alert("Give up per-write durability?", isPresented: $showingFlushDisclaimer) {
                Button("Cancel", role: .cancel) { pendingFlushInterval = nil }
                Button("Accept the Risk", role: .destructive) {
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
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 460)
        .task {
            if let id = existing?.id {
                hasStoredSecret = (try? await DaemonConnection.hasCHAPSecret(targetID: id)) ?? false
                hasStoredMutualSecret =
                    (try? await DaemonConnection.hasMutualCHAPSecret(targetID: id)) ?? false
            }
            hostNQN = try? await DaemonConnection.info().hostNQN
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
            "No flushes will be sent while attached — only when the volume is detached."
        case .some(let seconds):
            "Cached writes will be committed every \(seconds) second\(seconds == 1 ? "" : "s") "
            + "and when the volume is detached."
        default:
            ""
        }
        return "Writes will be acknowledged while they are still in the target's "
            + "volatile cache. " + cadence
            + "\n\nIf the target loses power, uncommitted writes are lost out of "
            + "order — which can corrupt the volume's structure, not just recent "
            + "files. Choose this only if the target's cache is protected: "
            + "battery-backed, on a UPS, or with its write cache disabled."
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

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !targetIQN.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil && UInt64(lun) != nil
            && !nvmeIncomplete
            && !secretTooShort && !credentialIncomplete && !mutualHalfConfigured
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
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? (isNVMe ? 4420 : 3260),
            targetIQN: targetIQN.trimmingCharacters(in: .whitespaces),
            lun: UInt64(lun) ?? (isNVMe ? 1 : 0),
            chapUser: (isNVMe || chapUser.isEmpty) ? nil : chapUser,
            mutualChapUser: (isNVMe || mutualChapUser.isEmpty) ? nil : mutualChapUser,
            autoAttach: existing?.autoAttach ?? false,
            flushIntervalSeconds: flushInterval,
            // No UI: readahead depth adapts. An override hand-written into
            // targets.json is carried through an edit rather than erased by it.
            workloadProfile: existing?.workloadProfile)

        LastPortal.remember(host: record.host, port: record.port)
        Task {
            await model.save(record,
                             secret: (isNVMe || chapSecret.isEmpty) ? nil : chapSecret,
                             mutualSecret: (isNVMe || mutualChapSecret.isEmpty) ? nil : mutualChapSecret)
            dismiss()
        }
    }
}
