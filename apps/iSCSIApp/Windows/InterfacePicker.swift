//
//  InterfacePicker.swift
//  The network-interface rows shared by the target editor and Discover.
//

import SwiftUI
import iSCSIKit

/// Automatic, or one interface plus what to do when it cannot be used. Lives
/// inside a Form section; the caller supplies the section and its footer.
struct InterfacePicker: View {
    /// nil: Automatic — macOS routing chooses.
    @Binding var name: String?
    /// false: strict (fail). true: prefer (fall back).
    @Binding var fallback: Bool
    @State private var choices: [InterfaceChoice] = []

    var body: some View {
        Group {
            Picker("Network interface", selection: $name) {
                Text("Automatic (macOS chooses)").tag(String?.none)
                ForEach(choices) { choice in
                    Text(choice.label).tag(String?.some(choice.name))
                }
            }
            if name != nil {
                Picker("When unavailable", selection: $fallback) {
                    Text("Fail the connection").tag(false)
                    Text("Use another interface").tag(true)
                }
                Text(fallback
                     ? "Falls back to whatever macOS picks when this interface is missing "
                       + "or has no route, and tries it again at the next reconnect."
                     : "Never uses another interface — not Wi-Fi, not a VPN. If this one "
                       + "is unavailable, the connection fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
    }

    /// Read when the sheet opens: interfaces come and go, and a stale list
    /// would offer one that is gone or hide one just plugged in.
    private func refresh() {
        choices = InterfaceChoices.list(snapshot: SystemInterfaces.snapshot(),
                                        displayNames: NetworkInterfaceNames.localized(),
                                        stored: name)
    }
}
