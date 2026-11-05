//
//  UninstallView.swift
//  Removing everything, with per-step results rather than a spinner.
//
//  A progress bar here would be a lie: some steps genuinely fail, and the user
//  needs to know *which*, because a leftover root daemon and a leftover cache
//  directory need different things done about them.
//

import SwiftUI

struct UninstallView: View {
    @ObservedObject var model: AppModel
    /// The app has been moved to the Trash. The presenter quits the app once
    /// this sheet is gone, which AppKit requires.
    let movedToTrash: () -> Void
    @StateObject private var uninstaller: Uninstaller
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, movedToTrash: @escaping () -> Void) {
        self.model = model
        self.movedToTrash = movedToTrash
        _uninstaller = StateObject(wrappedValue: Uninstaller(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove iSCSI/NVMe/TCP Initiator")
                .font(.title2).bold()

            if uninstaller.steps.isEmpty {
                explanation
            } else {
                stepList
                if let failure = uninstaller.trashFailure {
                    Text("The app could not move itself to the Trash: \(failure) "
                         + "Finder is showing it — drag it to the Trash.")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
            Divider()
            controls
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .confirmationDialog("Remove iSCSI/NVMe/TCP Initiator and everything it stored?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove Everything", role: .destructive) {
                Task { await uninstaller.run() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your saved targets and their passwords will be deleted. "
                 + "Nothing on the storage device itself is touched.")
        }
    }

    /// Says what will happen before it happens, and — the part people actually
    /// want to know before clicking an uninstall button — what will not.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Volumes are unmounted first, and nothing is forced. "
                  + "If something is using a volume, removal stops and says so.",
                  systemImage: "eject")
            Label("This account's saved targets and stored passwords are deleted.",
                  systemImage: "key")
            Label("The background service is unregistered and the filesystem "
                  + "extension is turned off. An iscsictl link is removed if this "
                  + "app added one, which needs an administrator's password.",
                  systemImage: "gearshape")
            Label("**Nothing on the storage device itself is changed.** "
                  + "Your data stays where it is.", systemImage: "externaldrive")
                .foregroundStyle(.primary)
            Text("The app itself goes last: when everything else is removed, "
                 + "a button moves it to the Trash and quits.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(uninstaller.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: step.outcome).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label)
                        if let detail = detail(for: step.outcome) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(isFailure(step.outcome) ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            if uninstaller.finished {
                Text(uninstaller.steps.contains(where: { isFailure($0.outcome) })
                     ? "Some things could not be removed."
                     : "Everything has been removed.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if uninstaller.stoppedForVolumes {
                Text("Stopped: nothing else is removed while a volume is in use.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
            if uninstaller.finished {
                Button("Move App to Trash") {
                    Task {
                        guard await uninstaller.moveAppToTrash() else { return }
                        movedToTrash()
                        dismiss()
                    }
                }
                .disabled(uninstaller.trashing)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Remove Everything…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(uninstaller.isRunning)
            }
        }
    }

    @ViewBuilder
    private func icon(for outcome: Uninstaller.Outcome) -> some View {
        switch outcome {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        }
    }

    private func detail(for outcome: Uninstaller.Outcome) -> String? {
        switch outcome {
        case .pending, .running: return nil
        case .done(let what):    return what
        case .failed(let why):   return why
        case .skipped:           return "not run"
        }
    }

    private func isFailure(_ outcome: Uninstaller.Outcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }
}
