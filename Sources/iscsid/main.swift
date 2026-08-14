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

// Write-through (FUA on every WRITE) defaults on: Backend A receives no barrier
// signal, so durability cannot be deferred to a flush we never get. Settable at
// runtime because it roughly halves write throughput, and because turning it
// off is how the crash-consistency negative control is run.
//   ISCSI_WRITE_THROUGH=0  -> disable
let writeThrough = (ProcessInfo.processInfo.environment["ISCSI_WRITE_THROUGH"] ?? "1") != "0"

let core = DaemonCore(initiatorName: initiatorName, writeThrough: writeThrough) { host, port in
    try await NetworkTransport.connect(host: host, port: port)
}

let delegate = ISCSIListenerDelegate(core: core)
let listener = NSXPCListener(machServiceName: iscsiDaemonServiceName)
listener.delegate = delegate
listener.resume()

// Built in pieces: the Swift type checker fails on this as a single
// interpolated expression (it reports "failed to produce diagnostic").
let wtLabel = writeThrough ? "on" : "off"
let banner = "iscsid: listening on " + iscsiDaemonServiceName + " (writeThrough=" + wtLabel + ")\n"
FileHandle.standardError.write(Data(banner.utf8))
dispatchMain()
#else
FileHandle.standardError.write(Data("iscsid requires macOS\n".utf8))
exit(1)
#endif
