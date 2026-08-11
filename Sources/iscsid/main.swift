import Foundation
import iSCSIDaemon
import iSCSIKit

// iscsid — the iSCSI initiator daemon. Runs as a launchd LaunchDaemon and
// vends the block-I/O + session-management XPC service to the FSKit extension,
// the dext-side helper, and iscsictl.
//
// launchd registers the Mach service (see the LaunchDaemon plist in
// docs/) and hands us the listener via NSXPCListener(machServiceName:).

#if canImport(Network)
let initiatorName = IQN.defaultInitiatorName(
    hostIdentifier: Host.current().localizedName ?? "mac"
)

let core = DaemonCore(initiatorName: initiatorName) { host, port in
    try await NetworkTransport.connect(host: host, port: port)
}

let delegate = ISCSIListenerDelegate(core: core)
let listener = NSXPCListener(machServiceName: iscsiDaemonServiceName)
listener.delegate = delegate
listener.resume()

FileHandle.standardError.write(Data("iscsid: listening on \(iscsiDaemonServiceName)\n".utf8))
dispatchMain()
#else
FileHandle.standardError.write(Data("iscsid requires macOS\n".utf8))
exit(1)
#endif
