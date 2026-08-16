//
//  SetupView.swift
//  Renders the result of the setup checks. Contains no instructions of its own.
//
//  Every line of explanatory text on this screen comes from a step's `check()`,
//  which means it is describing the machine's current state rather than a
//  procedure someone wrote down once. A step that is already satisfied says so
//  and offers no button; the first one that is not gets the button.
//

import SwiftUI

struct SetupView: View {
    @ObservedObject var setup: SetupCoordinator
    /// The step whose consent dialog is showing, if any.
    @State private var consentFor: SetupCoordinator.Report?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                header

                ForEach(setup.reports) { report in
                    Divider().padding(.vertical, 8)
                    row(report)
                }
            }
            .padding(6)
        }
        .task { await setup.checkAll() }
        // The states here are all changed from outside this app — System
        // Settings, launchd, LaunchServices. Coming back to the foreground is
        // the moment any of them might have changed, and it beats a polling
        // timer that is wrong most of the time it fires.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.checkAll() }
        }
        .confirmationDialog(
            "Enable the filesystem extension?",
            isPresented: Binding(get: { consentFor != nil },
                                 set: { if !$0 { consentFor = nil } }),
            presenting: consentFor
        ) { report in
            Button("Enable") {
                let id = report.id
                consentFor = nil
                Task { await setup.perform(id) }
            }
            Button("Not now", role: .cancel) { consentFor = nil }
        } message: { report in
            Text(report.consentPrompt ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if setup.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: setup.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(setup.isReady ? .green : .orange)
            }
            Text(setup.isReady ? "Ready" : "Setup")
                .font(.headline)
            Spacer()
            Button("Re-check") { Task { await setup.checkAll() } }
                .disabled(setup.isChecking)
        }
    }

    @ViewBuilder
    private func row(_ report: SetupCoordinator.Report) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(for: report.state)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(report.title)
                    .fontWeight(report.isNext ? .semibold : .regular)
                Text(report.state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            // Only the first unsatisfied step gets its button. Offering "Enable"
            // while the daemon it depends on is still missing produces a failure
            // that tells the user nothing about what to do next.
            if setup.busyStepID == report.id {
                // Kept in the button's place, same shape, so the row does not
                // reflow and the eye stays where it was. Disabled rather than
                // hidden: a control that vanishes reads as a crash, and one
                // that stays live invites a second press that would start the
                // whole thing again.
                Button {} label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(setup.busyLabel ?? "Working")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
            } else if report.isNext, let label = report.actionLabel {
                Button(label) {
                    if report.consentPrompt != nil {
                        consentFor = report
                    } else {
                        Task { await setup.perform(report.id) }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func icon(for state: StepState) -> some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small)
        case .satisfied:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .actionable:
            Image(systemName: "circle.dashed").foregroundStyle(.orange)
        case .blocked:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
