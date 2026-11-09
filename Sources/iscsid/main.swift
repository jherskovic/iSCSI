import Foundation
import iSCSIDaemon
import iSCSIKit

// iscsid — the iSCSI initiator daemon: a launchd LaunchDaemon vending the
// block-I/O + session-management XPC service to the app and the FSKit
// extension (the signed iscsictl also connects). Clients act for the
// account they run in: see UserConfiguration. launchd registers the
// Mach service and hands us the listener via NSXPCListener(machServiceName:).

#if canImport(Network)
let initiatorName = IQN.defaultInitiatorName(
    hostIdentifier: Host.current().localizedName ?? "mac"
)

// A task unanswered for this long is aborted and retried on a fresh session
// rather than waited on forever. Without it, a target that accepts commands
// and never answers them wedges APFS instead of failing an I/O — and the NOP
// keepalive does not notice, because such a target still answers pings.
//   ISCSI_TASK_TIMEOUT_SEC=0  -> wait forever
var policy = SessionPolicy()
if let raw = ProcessInfo.processInfo.environment["ISCSI_TASK_TIMEOUT_SEC"], let seconds = Int(raw) {
    policy.taskTimeout = seconds > 0 ? .seconds(seconds) : nil
}

// The NVMe host identity is derived from the platform UUID: nothing to
// persist, nothing removeAllData can lose, nothing a hostname change moves.
let nvmeHost = HostIdentity.nvmeHost()

let core = DaemonCore(
    initiatorName: initiatorName,
    policy: policy,
    hostIdentity: nvmeHost
) { host, port, binding in
    try await NetworkTransport.connect(host: host, port: port, binding: binding)
}

let delegate = ISCSIListenerDelegate(core: core)
let listener = NSXPCListener(machServiceName: iscsiDaemonServiceName)
listener.delegate = delegate
listener.resume()

// Built in pieces: the Swift type checker fails on this as a single
// interpolated expression (it reports "failed to produce diagnostic").
// Durability is per target (`FlushPolicy`, from its record); the crash-
// consistency negative control is a target set to never flush. The daemon-
// wide ISCSI_WRITE_THROUGH switch that once did that had stopped reaching any
// filesystem session, and was removed.
let toLabel = policy.taskTimeout.map { "\($0)" } ?? "none"
var banner = "iscsid: listening on " + iscsiDaemonServiceName
banner += " (taskTimeout=" + toLabel + ")"
DaemonLog.lifecycle(banner)
DaemonLog.lifecycle("iscsid: initiator " + initiatorName + ", NVMe host " + nvmeHost.nqn)
dispatchMain()
#else
FileHandle.standardError.write(Data("iscsid requires macOS\n".utf8))  // DaemonLog is macOS-only
exit(1)
#endif
