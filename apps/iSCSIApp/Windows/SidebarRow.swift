//
//  SidebarRow.swift
//  One item in the main window's sidebar, with what it is doing.
//

import SwiftUI

/// A sidebar item with its state on the trailing edge: a spinner while the
/// screen's content is being worked on, or "!" when it holds something for
/// the user to address. Never both: work in progress can change the answer,
/// so the mark waits for it to finish. Without the spinner a screen that is
/// still loading looks like one with nothing in it.
struct SidebarRow: View {
    let title: String
    let symbol: String
    var isWorking = false
    var needsAttention = false

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Working"))
            }
        }
        .badge(!isWorking && needsAttention ? Text("!") : nil)
    }
}
