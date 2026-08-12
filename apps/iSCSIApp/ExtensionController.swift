//
//  ExtensionController.swift
//  Drives DriverKit dext activation via SystemExtensions.framework. This is
//  the real activation flow — the dext bundle id must match the one embedded
//  in the app's Contents/Library/SystemExtensions.
//

import Foundation
import SystemExtensions
import os

@MainActor
final class ExtensionController: NSObject, ObservableObject {
    static let dextBundleID = "me.herko.iSCSIInitiator.dext"

    @Published var dextActivated = false
    @Published var dextStatus = "Not activated"
    @Published var log = ""

    private let logger = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "sysext")

    func toggleDext() {
        dextActivated ? deactivate() : activate()
    }

    func activate() {
        appendLog("Requesting activation of \(Self.dextBundleID)…")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.dextBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        appendLog("Requesting deactivation…")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.dextBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func appendLog(_ line: String) {
        logger.log("\(line, privacy: .public)")
        log += line + "\n"
    }
}

extension ExtensionController: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always take the newer bundle. Note: an always-matched virtual dext
        // may still require a reboot to swap (see docs/architecture.md); the
        // nub-teardown user client is the reboot-free path.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.dextStatus = "Awaiting approval in System Settings → General → Login Items & Extensions → Driver Extensions"
            self.appendLog("User approval required.")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let willReboot = (result == .willCompleteAfterReboot)
        Task { @MainActor in
            if willReboot {
                self.dextStatus = "Will complete after reboot"
                self.appendLog("Completed pending reboot.")
            } else {
                self.dextActivated.toggle()
                self.dextStatus = self.dextActivated ? "Activated" : "Deactivated"
                self.appendLog("Request finished: \(self.dextStatus).")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let ns = error as NSError
        let detail = "domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) userInfo=\(ns.userInfo)"
        Task { @MainActor in
            self.dextStatus = "Failed"
            self.appendLog("Request failed: \(detail)")
        }
    }
}
