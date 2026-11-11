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

    // Discover opens on iSCSI, so it opens on iSCSI's remembered portal.
    @State private var host = LastPortal.suggestedHost(nvme: false)
    @State private var port = String(LastPortal.port(nvme: false))
    /// Which discovery to run. Not stored anywhere: a target's protocol is
    /// its name's prefix, and Discover only decides which portal to ask.
    @State private var isNVMe = false
    @State private var chapUser = ""
    @State private var chapSecret = ""
    @State private var networkInterface: String?
    @State private var interfaceFallback = false
    @State private var found: [DiscoveredTargetInfo] = []
    /// What produced `found`: the portal asked and the credentials offered.
    /// Add and Use These Credentials bind to this, never to the fields as they
    /// are now — those can have been edited since, and a row from one portal
    /// must not be saved against another.
    @State private var lastSearch: Search?
    @State private var isSearching = false
    @State private var searched = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker(String(localized: "Protocol"), selection: $isNVMe) {
                        Text("iSCSI").tag(false)
                        Text("NVMe/TCP").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField(String(localized: "Address"), text: $host, prompt: Text("nas.local"))
                        .onSubmit(search)
                    TextField(String(localized: "Port"), text: $port)
                } header: {
                    Text(String(localized: "Portal"))
                } footer: {
                    Text(isNVMe
                         ? String(localized: "NVMe/TCP subsystems list themselves to any host that can reach the port. Whether this Mac may attach is decided per subsystem by its host NQN, shown when you edit the target.")
                         : String(localized: "Some devices require credentials before they will list their targets. Leave these empty if yours does not."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section(String(localized: "Network")) {
                    InterfacePicker(name: $networkInterface, fallback: $interfaceFallback)
                }

                if !isNVMe {
                    Section("Authentication (optional)") {
                        TextField(String(localized: "CHAP user"), text: $chapUser)
                        SecureField(String(localized: "CHAP secret"), text: $chapSecret)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 400)
            .onChange(of: isNVMe) { wasNVMe, nvme in
                LastPortal.switchProtocol(host: &host, port: &port, from: wasNVMe, to: nvme)
            }

            HStack {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .lineLimit(2)
                }
                Spacer()
                Button(isSearching ? String(localized: "Searching…") : String(localized: "Discover"), action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(host.isEmpty || isSearching || !model.isReady)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Divider()
            results
        }
        .navigationTitle(String(localized: "Discover"))
    }

    @ViewBuilder
    private var results: some View {
        if isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if found.isEmpty && searched {
            ContentUnavailableView(String(localized: "No Targets Offered"), systemImage: "magnifyingglass",
                                   description: Text(String(localized: "The device answered, but is not offering any targets to this initiator.")))
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
                    switch offer(for: target, from: lastSearch) {
                    case .add:
                        Button(String(localized: "Add")) { if let lastSearch { add(target, from: lastSearch) } }
                    case .saved:
                        Text(String(localized: "Added")).font(.caption).foregroundStyle(.secondary)
                    case .updateCredentials(let records):
                        // Without this the credentials that just listed the
                        // target were dropped, and the next attach went out
                        // with no CHAP and was refused.
                        Text(records.allSatisfy { $0.chapUser == nil }
                             ? String(localized: "Saved without CHAP") : String(localized: "Saved with another CHAP user"))
                            .font(.caption).foregroundStyle(.orange)
                        Button(String(localized: "Use These Credentials")) {
                            if let lastSearch { useCredentials(of: lastSearch, on: records) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private struct Search {
        var host: String
        var port: UInt16
        var isNVMe: Bool
        /// Empty when none were offered; always empty for NVMe.
        var chapUser: String
        var chapSecret: String
        var networkInterface: String?
        var interfaceFallback: Bool
    }

    private func offer(for target: DiscoveredTargetInfo, from search: Search?) -> DiscoveryOffer {
        guard let search else { return .saved }
        return DiscoveryOffer.for(target.targetIQN, at: search.host, port: search.port,
                                  saved: model.targets,
                                  chapUser: search.chapUser, chapSecret: search.chapSecret)
    }

    /// The same save the editor makes: the user into the record, the secret
    /// through the daemon into the keychain.
    private func useCredentials(of search: Search, on records: [TargetRecord]) {
        Task {
            for var record in records {
                record.chapUser = search.chapUser
                await model.save(record, secret: search.chapSecret)
            }
        }
    }

    private func search() {
        isSearching = true
        failure = nil
        let asked = Search(host: TargetPortal.host(typed: host),
                           port: UInt16(port) ?? LastPortal.defaultPort(nvme: isNVMe),
                           isNVMe: isNVMe,
                           chapUser: isNVMe ? "" : chapUser,
                           chapSecret: isNVMe ? "" : chapSecret,
                           networkInterface: networkInterface,
                           interfaceFallback: interfaceFallback)
        Task {
            defer { isSearching = false; searched = true }
            do {
                // Remembered on a *successful* search: an address that answered
                // is worth suggesting again, one that was mistyped is not.
                defer {
                    if !found.isEmpty {
                        LastPortal.remember(host: asked.host, port: asked.port,
                                            nvme: asked.isNVMe)
                    }
                }
                let interface = InterfaceBinding.named(asked.networkInterface,
                                                       fallback: asked.interfaceFallback)
                if asked.isNVMe {
                    found = try await DaemonConnection.discoverSubsystems(
                        host: asked.host, port: asked.port, interface: interface)
                } else {
                    found = try await DaemonConnection.discoverTargets(
                        host: asked.host, port: asked.port,
                        chapUser: asked.chapUser.isEmpty ? nil : asked.chapUser,
                        chapSecret: asked.chapSecret.isEmpty ? nil : asked.chapSecret,
                        interface: interface)
                }
                lastSearch = asked
            } catch {
                found = []
                lastSearch = nil
                let ns = error as NSError
                // Inline rather than in an alert: the user is mid-task with the
                // fields still in front of them, and the fix is usually one of
                // those fields.
                let details = LocalizedStorageError.details(ns)
                failure = [details.message, details.suggestion]
                    .compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    private func add(_ target: DiscoveredTargetInfo, from search: Search) {
        // Carry the discovery credentials and interface onto the target: a portal
        // that needed them to list its targets will need them to log in, and asking twice
        // for the same secret is the kind of thing that makes people give up.
        // NSID 0 is reserved: an NVMe subsystem's first namespace is 1.
        let record = TargetRecord(
            id: UUID().uuidString,
            displayName: shortName(from: target.targetIQN),
            host: search.host,
            port: search.port,
            targetIQN: target.targetIQN,
            lun: search.isNVMe ? 1 : 0,
            chapUser: search.chapUser.isEmpty ? nil : search.chapUser,
            networkInterface: search.networkInterface,
            interfaceFallback: search.networkInterface == nil ? nil : search.interfaceFallback)
        Task { await model.save(record, secret: search.chapSecret.isEmpty ? nil : search.chapSecret) }
    }

    /// IQNs and NQNs end in a human-chosen name after the last colon; that is
    /// a far better default label than the whole 60-character identifier.
    private func shortName(from iqn: String) -> String {
        iqn.split(separator: ":").last.map(String.init) ?? iqn
    }
}
