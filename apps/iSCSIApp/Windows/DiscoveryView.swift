//
//  DiscoveryView.swift
//  Ask a storage device what it is offering.
//
//  This is the first place CHAP-protected discovery has ever been reachable:
//  DaemonCore.discover has always accepted credentials and the XPC layer used
//  to drop them, so an authenticated portal could not be discovered at all.
//

import SwiftUI
import iSCSIKit

struct DiscoveryView: View {
    @ObservedObject var model: AppModel

    @State private var host = LastPortal.suggestedHost
    @State private var port = String(LastPortal.port)
    @State private var chapUser = ""
    @State private var chapSecret = ""
    @State private var found: [DiscoveredTargetInfo] = []
    @State private var isSearching = false
    @State private var searched = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Address", text: $host, prompt: Text("nas.local"))
                        .onSubmit(search)
                    TextField("Port", text: $port)
                } header: {
                    Text("Portal")
                } footer: {
                    Text("Some devices require credentials before they will list "
                         + "their targets. Leave these empty if yours does not.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Authentication (optional)") {
                    TextField("CHAP user", text: $chapUser)
                    SecureField("CHAP secret", text: $chapSecret)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 260)

            HStack {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .lineLimit(2)
                }
                Spacer()
                Button(isSearching ? "Searching…" : "Discover", action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(host.isEmpty || isSearching || !model.isReady)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Divider()
            results
        }
        .navigationTitle("Discover")
    }

    @ViewBuilder
    private var results: some View {
        if isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if found.isEmpty && searched {
            ContentUnavailableView("No Targets Offered", systemImage: "magnifyingglass",
                                   description: Text("The device answered, but is not "
                                                     + "offering any targets to this "
                                                     + "initiator."))
        } else {
            List(found, id: \.targetIQN) { target in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.targetIQN)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        if !target.addresses.isEmpty {
                            Text(target.addresses.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isAlreadyConfigured(target) {
                        Text("Added").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Add") { add(target) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func isAlreadyConfigured(_ target: DiscoveredTargetInfo) -> Bool {
        model.targets.contains { $0.targetIQN == target.targetIQN }
    }

    private func search() {
        isSearching = true
        failure = nil
        Task {
            defer { isSearching = false; searched = true }
            do {
                // Remembered on a *successful* search: an address that answered
                // is worth suggesting again, one that was mistyped is not.
                defer {
                    if !found.isEmpty {
                        LastPortal.remember(host: host.trimmingCharacters(in: .whitespaces),
                                            port: UInt16(port) ?? 3260)
                    }
                }
                found = try await DaemonConnection.discoverTargets(
                    host: host.trimmingCharacters(in: .whitespaces),
                    port: UInt16(port) ?? 3260,
                    chapUser: chapUser.isEmpty ? nil : chapUser,
                    chapSecret: chapSecret.isEmpty ? nil : chapSecret)
            } catch {
                found = []
                let ns = error as NSError
                // Inline rather than in an alert: the user is mid-task with the
                // fields still in front of them, and the fix is usually one of
                // those fields.
                failure = [ns.localizedDescription, ns.localizedRecoverySuggestion]
                    .compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    private func add(_ target: DiscoveredTargetInfo) {
        // Carry the discovery credentials onto the target: a portal that needed
        // them to list its targets will need them to log in, and asking twice
        // for the same secret is the kind of thing that makes people give up.
        let record = TargetRecord(
            id: UUID().uuidString,
            displayName: shortName(from: target.targetIQN),
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 3260,
            targetIQN: target.targetIQN,
            lun: 0,
            chapUser: chapUser.isEmpty ? nil : chapUser)
        Task { await model.save(record, secret: chapSecret.isEmpty ? nil : chapSecret) }
    }

    /// IQNs end in a human-chosen name after the last colon; that is a far
    /// better default label than the whole 60-character identifier.
    private func shortName(from iqn: String) -> String {
        iqn.split(separator: ":").last.map(String.init) ?? iqn
    }
}
