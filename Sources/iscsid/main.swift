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

// A task unanswered for this long is aborted and retried on a fresh session
// rather than waited on forever. Without it, a target that accepts commands
// and never answers them wedges APFS instead of failing an I/O — and the NOP
// keepalive does not notice, because such a target still answers pings.
//   ISCSI_TASK_TIMEOUT_SEC=0  -> wait forever (the old behaviour)
var policy = SessionPolicy()
if let raw = ProcessInfo.processInfo.environment["ISCSI_TASK_TIMEOUT_SEC"], let seconds = Int(raw) {
    policy.taskTimeout = seconds > 0 ? .seconds(seconds) : nil
}

let core = DaemonCore(
    initiatorName: initiatorName,
    writeThrough: writeThrough,
    policy: policy
) { host, port in
    try await NetworkTransport.connect(host: host, port: port)
}

let delegate = ISCSIListenerDelegate(core: core)
let listener = NSXPCListener(machServiceName: iscsiDaemonServiceName)
listener.delegate = delegate
listener.resume()

// Built in pieces: the Swift type checker fails on this as a single
// interpolated expression (it reports "failed to produce diagnostic").
let wtLabel = writeThrough ? "on" : "off"
let toLabel = policy.taskTimeout.map { "\($0)" } ?? "none"
var banner = "iscsid: listening on " + iscsiDaemonServiceName
banner += " (writeThrough=" + wtLabel + ", taskTimeout=" + toLabel + ")\n"
FileHandle.standardError.write(Data(banner.utf8))
dispatchMain()
#else
FileHandle.standardError.write(Data("iscsid requires macOS\n".utf8))
exit(1)
#endif
