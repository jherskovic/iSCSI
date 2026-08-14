//
//  iSCSIApp.swift
//  Container app for the iSCSI initiator. Its jobs: host and activate the
//  DriverKit dext (Backend B) and FSKit extension (Backend A) via
//  SystemExtensions, and provide a small UI to manage targets and sessions.
//

import SwiftUI

@main
struct ISCSIInitiatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iSCSI Initiator")
                .font(.largeTitle).bold()

            Text("Milestone 0-b probe build — measures whether a notarized "
                 + "Developer ID build can be enabled in System Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            FSKitProbeView()

            Spacer()
        }
        .padding(24)
    }
}

// The dext panel and its `.task { controller.activate() }` auto-fire lived here.
// Both are gone for v1: the app no longer embeds the dext (see the comment in
// apps/project.yml), so an activation request could only ever fail — and firing
// a doomed OSSystemExtensionRequest inside the build under test would add noise
// to exactly the logs M0-b needs to read. ExtensionController.swift is kept
// intact for when Backend B comes back.
