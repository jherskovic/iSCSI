import Foundation
import iSCSIKit
import os

/// One session's most recent connect outcome. Every connect updates it — the
/// first and each recovery reconnect — so the Sessions window shows the path
/// the session is on now, not the one it started on.
final class ConnectedPathBox: Sendable {
    private let label: String
    private let state = OSAllocatedUnfairLock<ConnectedPath?>(initialState: nil)

    init(label: String) { self.label = label }

    var current: ConnectedPath? { state.withLock { $0 } }

    /// Note which interface `transport` connected over, log one line, and
    /// hand the transport back unchanged. A transport that cannot say (an
    /// in-memory pipe) is passed through and records nothing.
    func record(_ transport: any ConnectionTransport) -> any ConnectionTransport {
        guard let reporting = transport as? ConnectionPathReporting else { return transport }
        let path = reporting.connectedPath
        state.withLock { $0 = path }
        var line = "\(label): connected via \(path.interfaceName ?? "an unknown interface")"
        if let fallback = path.fallback {
            line += " — fell back from \(fallback.from): \(fallback.reason)"
        }
        DaemonLog.session(line)
        return transport
    }
}
