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
    /// Which discovery to run. Not stored anywhere: a target's protocol is
    /// its name's prefix, and Discover only decides which portal to ask.
    @State private var isNVMe = false
    @State private var chapUser = ""
    @State private var chapSecret = ""
    @State private var networkInterface: String?
    @State private var interfaceFallback = false
    @State private var found: [DiscoveredTargetInfo] = []
    @State private var isSearching = false
    @State private var searched = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Protocol", selection: $isNVMe) {
                        Text("iSCSI").tag(false)
                        Text("NVMe/TCP").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Address", text: $host, prompt: Text("nas.local"))
                        .onSubmit(search)
                    TextField("Port", text: $port)
                } header: {
                    Text("Portal")
                } footer: {
                    Text(isNVMe
                         ? "NVMe/TCP subsystems list themselves to any host that can reach "
                           + "the port. Whether this Mac may attach is decided per subsystem "
                           + "by its host NQN, shown when you edit the target."
                         : "Some devices require credentials before they will list "
                           + "their targets. Leave these empty if yours does not.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Network") {
                    InterfacePicker(name: $networkInterface, fallback: $interfaceFallback)
                }

                if !isNVMe {
                    Section("Authentication (optional)") {
                        TextField("CHAP user", text: $chapUser)
                        SecureField("CHAP secret", text: $chapSecret)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 400)
            .onChange(of: isNVMe) { _, nvme in
                // Swap the port only when it still holds the other protocol's
                // default; a port the user typed is theirs.
                if port == String(nvme ? 3260 : 4420) { port = String(nvme ? 4420 : 3260) }
            }

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
                    switch offer(for: target) {
                    case .add:
                        Button("Add") { add(target) }
                    case .saved:
                        Text("Added").font(.caption).foregroundStyle(.secondary)
                    case .updateCredentials(let records):
                        // Without this the credentials that just listed the
                        // target were dropped, and the next attach went out
                        // with no CHAP and was refused.
                        Text(records.allSatisfy { $0.chapUser == nil }
                             ? "Saved without CHAP" : "Saved with another CHAP user")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Use These Credentials") { useCredentials(on: records) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func offer(for target: DiscoveredTargetInfo) -> DiscoveryOffer {
        DiscoveryOffer.for(target.targetIQN, saved: model.targets,
                           chapUser: isNVMe ? "" : chapUser,
                           chapSecret: isNVMe ? "" : chapSecret)
    }

    /// The same save the editor makes: the user into the record, the secret
    /// through the daemon into the keychain.
    private func useCredentials(on records: [TargetRecord]) {
        Task {
            for var record in records {
                record.chapUser = chapUser
                await model.save(record, secret: chapSecret)
            }
        }
    }

    private var defaultPort: UInt16 { isNVMe ? 4420 : 3260 }

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
                                            port: UInt16(port) ?? defaultPort)
                    }
                }
                if isNVMe {
                    found = try await DaemonConnection.discoverSubsystems(
                        host: host.trimmingCharacters(in: .whitespaces),
                        port: UInt16(port) ?? defaultPort,
                        interface: InterfaceBinding.named(networkInterface,
                                                          fallback: interfaceFallback))
                } else {
                    found = try await DaemonConnection.discoverTargets(
                        host: host.trimmingCharacters(in: .whitespaces),
                        port: UInt16(port) ?? defaultPort,
                        chapUser: chapUser.isEmpty ? nil : chapUser,
                        chapSecret: chapSecret.isEmpty ? nil : chapSecret,
                        interface: InterfaceBinding.named(networkInterface,
                                                          fallback: interfaceFallback))
                }
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
        // Carry the discovery credentials and interface onto the target: a portal
        // that needed them to list its targets will need them to log in, and asking twice
        // for the same secret is the kind of thing that makes people give up.
        // NSID 0 is reserved: an NVMe subsystem's first namespace is 1.
        let record = TargetRecord(
            id: UUID().uuidString,
            displayName: shortName(from: target.targetIQN),
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? defaultPort,
            targetIQN: target.targetIQN,
            lun: isNVMe ? 1 : 0,
            chapUser: (isNVMe || chapUser.isEmpty) ? nil : chapUser,
            networkInterface: networkInterface,
            interfaceFallback: networkInterface == nil ? nil : interfaceFallback)
        Task { await model.save(record, secret: (isNVMe || chapSecret.isEmpty) ? nil : chapSecret) }
    }

    /// IQNs and NQNs end in a human-chosen name after the last colon; that is
    /// a far better default label than the whole 60-character identifier.
    private func shortName(from iqn: String) -> String {
        iqn.split(separator: ":").last.map(String.init) ?? iqn
    }
}
