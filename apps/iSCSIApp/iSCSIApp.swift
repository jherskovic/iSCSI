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
                .frame(minWidth: 640, minHeight: 640)
        }
    }
}

struct ContentView: View {
    @StateObject private var setup = SetupCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iSCSI Initiator")
                .font(.largeTitle).bold()

            Text("Setup runs on every launch and reports what is actually true, "
                 + "rather than listing steps.")
                .font(.callout)
                .foregroundStyle(.secondary)

            SetupView(setup: setup)

            DisclosureGroup("Probes (M0-b / M2 instrumentation)") {
                VStack(alignment: .leading, spacing: 12) {
                    FSKitProbeView()
                    DaemonPanelView()
                }
                .padding(.top, 6)
            }

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
