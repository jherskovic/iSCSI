//
//  MenuBarContent.swift
//  What drops down from the menu bar.
//
//  The fast path: see what is mounted, mount or unmount it, get to it in Finder.
//  Anything that needs typing lives in the window.
//

import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.isReady {
                setupBanner
                Divider()
            }

            if model.rows.isEmpty {
                Text(model.isReady ? "No targets yet" : "Setup is not finished")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ForEach(model.rows) { row in
                    MenuRow(row: row, model: model)
                }
            }

            Divider()

            if model.rows.contains(where: \.isAttached) {
                menuButton("Detach All", systemImage: "eject") {
                    Task {
                        for row in model.rows where row.isAttached {
                            await model.detach(row.target)
                        }
                    }
                }
            }
            menuButton("iSCSI Initiator…", systemImage: "macwindow") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            menuButton("Quit", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .task { await model.refresh() }
    }

    /// Not an error, and deliberately not styled as one: an unfinished setup is
    /// the expected state on a new install, and the useful thing is a way in
    /// rather than a warning.
    private var setupBanner: some View {
        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Finish setting up").fontWeight(.medium)
                    Text("A few permissions are still needed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func menuButton(_ title: String, systemImage: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}

private struct MenuRow: View {
    let row: AppModel.Row
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(row.isAttached ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.target.displayName).lineLimit(1)
                if let bytes = row.session?.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                                   countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if row.isBusy {
                ProgressView().controlSize(.small)
            } else if row.isAttached {
                Button("Show") { model.reveal(row) }.buttonStyle(.link)
                Button("Eject") { Task { await model.detach(row.target) } }
                    .buttonStyle(.borderless)
            } else {
                Button("Attach") { Task { await model.attach(row.target) } }
                    .buttonStyle(.borderless)
                    .disabled(!model.isReady)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
