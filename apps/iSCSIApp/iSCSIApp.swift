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
    @StateObject private var controller = ExtensionController()
    @State private var portal = "192.168.0.101"
    @State private var target = "iqn.me.herko.planet-express:iscsi-driver-testing"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iSCSI Initiator")
                .font(.largeTitle).bold()

            GroupBox("Driver Extension (Backend B)") {
                HStack {
                    Circle()
                        .fill(controller.dextActivated ? .green : .secondary)
                        .frame(width: 10, height: 10)
                    Text(controller.dextStatus)
                    Spacer()
                    Button(controller.dextActivated ? "Deactivate" : "Activate") {
                        controller.toggleDext()
                    }
                }
                .padding(6)
            }

            GroupBox("Target") {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("Portal")
                        TextField("host", text: $portal)
                    }
                    GridRow {
                        Text("IQN")
                        TextField("iqn…", text: $target)
                    }
                }
                .padding(6)
            }

            Text(controller.log)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(24)
    }
}
