//
//  TargetsView.swift
//  The list people spend their time in: one row per target, attach or detach.
//

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
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Targets", systemImage: "externaldrive.badge.plus")
        } description: {
            Text(model.isReady
                 ? "Add the address of an iSCSI target, or use Discover to find "
                 + "what a storage device is offering."
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
        if let bytes = row.session?.byteCount {
            return "\(row.target.host) — "
                 + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        return "\(row.target.host):\(row.target.port) · LUN \(row.target.lun)"
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
    @State private var hasStoredSecret = false

    init(model: AppModel, target: TargetRecord?) {
        self.model = model
        self.existing = target
        _displayName = State(initialValue: target?.displayName ?? "")
        _host = State(initialValue: target?.host ?? "")
        _port = State(initialValue: String(target?.port ?? 3260))
        _targetIQN = State(initialValue: target?.targetIQN ?? "")
        _lun = State(initialValue: String(target?.lun ?? 0))
        _chapUser = State(initialValue: target?.chapUser ?? "")
        _mutualChapUser = State(initialValue: target?.mutualChapUser ?? "")
        _chapSecret = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $displayName, prompt: Text("Photos archive"))
                    TextField("Address", text: $host, prompt: Text("nas.local"))
                    TextField("Port", text: $port)
                    TextField("Target", text: $targetIQN,
                              prompt: Text("iqn.2026-08.com.example:disk0"))
                    TextField("LUN", text: $lun)
                }

                Section("Authentication") {
                    TextField("CHAP user", text: $chapUser)
                    SecureField(hasStoredSecret ? "Saved — type to replace" : "CHAP secret",
                                text: $chapSecret)
                    // Named rather than left to fail at login: many targets
                    // reject a shorter secret, and the error they return says
                    // only "authentication failure".
                    Text("Most targets require a secret of at least 12 characters.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Mutual CHAP user", text: $mutualChapUser,
                              prompt: Text("optional"))
                }
            }
            .formStyle(.grouped)

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
            }
        }
    }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !targetIQN.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil && UInt64(lun) != nil
    }

    private func save() {
        // The id is stable for the life of the target: the keychain item and the
        // mount point are both derived from it, so regenerating it on edit would
        // orphan the secret and strand the mount.
        let record = TargetRecord(
            id: existing?.id ?? UUID().uuidString,
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 3260,
            targetIQN: targetIQN.trimmingCharacters(in: .whitespaces),
            lun: UInt64(lun) ?? 0,
            chapUser: chapUser.isEmpty ? nil : chapUser,
            mutualChapUser: mutualChapUser.isEmpty ? nil : mutualChapUser,
            autoAttach: existing?.autoAttach ?? false)

        Task {
            await model.save(record, secret: chapSecret.isEmpty ? nil : chapSecret)
            dismiss()
        }
    }
}
