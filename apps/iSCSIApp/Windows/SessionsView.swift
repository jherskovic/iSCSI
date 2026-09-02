//
//  SessionsView.swift
//  The diagnostic screen.
//
//  Everything shown here already existed inside the daemon and had never
//  crossed XPC, which meant a bug report could say "it felt slow" and nothing
//  more. Negotiated parameters, recovery count and write-cache state are what
//  turn that into a report someone can act on, and they cost nothing to send.
//

import SwiftUI
import iSCSIKit

struct SessionsView: View {
    @ObservedObject var model: AppModel
    @State private var selected: SessionInfo.ID?

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                ContentUnavailableView("No Active Sessions", systemImage: "bolt.horizontal",
                                       description: Text("Attach a target to open a session."))
            } else {
                List(model.sessions, selection: $selected) { session in
                    SessionSummary(session: session)
                        .tag(session.id)
                }
            }
        }
        .navigationTitle("Sessions")
        .inspector(isPresented: .constant(selected != nil)) {
            if let session = model.sessions.first(where: { $0.id == selected }) {
                SessionDetail(session: session)
            }
        }
    }
}

private struct SessionSummary: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.targetIQN)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                Label("\(session.isNVMe ? "NSID" : "LUN") \(session.lun)", systemImage: "number")
                if let bytes = session.byteCount {
                    Label(ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                                    countStyle: .file),
                          systemImage: "internaldrive")
                }
                // Surfaced in the summary, not buried in the detail pane: a
                // session that has silently rebuilt itself several times is the
                // single most useful thing to notice about a connection that
                // "feels slow", and nobody would think to go looking for it.
                if session.recoveryCount > 0 {
                    Label("recovered \(session.recoveryCount)×",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct SessionDetail: View {
    let session: SessionInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Device") {
                    row(session.isNVMe ? "Subsystem" : "Target", session.targetIQN)
                    row(session.isNVMe ? "Namespace ID" : "LUN", String(session.lun))
                    if let size = session.blockSize { row("Block size", "\(size) bytes") }
                    if let count = session.blockCount { row("Blocks", String(count)) }
                    if let bytes = session.byteCount {
                        row("Capacity", ByteCountFormatter.string(
                            fromByteCount: Int64(bytes), countStyle: .file))
                    }
                }

                group("Durability") {
                    row("Write cache", session.writeCacheEnabled.map {
                        $0 ? "Enabled on the target" : "Disabled on the target"
                    } ?? "Not reported")
                    row("Write-through", session.writeThrough ? "On (FUA on every write)" : "Off")
                    row("Session recoveries", String(session.recoveryCount))
                }
                // The combination that quietly risks data, spelled out rather
                // than left to be inferred from two rows above: a target caching
                // writes while we do not force them through, on a path that
                // never receives a flush.
                if session.writeCacheEnabled == true && !session.writeThrough {
                    Label("This target caches writes and write-through is off. "
                          + "Data acknowledged as written may not survive a power loss.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Negotiated") {
                    ForEach(session.negotiated.keys.sorted(), id: \.self) { key in
                        row(key, session.negotiated[key] ?? "")
                    }
                }
            }
            .padding()
        }
        .inspectorColumnWidth(min: 280, ideal: 340)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
