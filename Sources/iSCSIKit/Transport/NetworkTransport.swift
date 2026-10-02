#if canImport(Network)
import Foundation
import Network
import os

/// TCP transport over Network.framework for a real iSCSI connection.
/// Used by the daemon and by `iscsictl` against a live target.
public final class NetworkTransport: ConnectionTransport, ConnectionPathReporting, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "iscsi.transport")
    /// The interface this connection ended up on, and whether a pin fell
    /// back. Written inside `connect`, before the transport is handed out,
    /// and never again.
    public private(set) var connectedPath = ConnectedPath()

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Open a TCP connection to host:port and wait until it is ready.
    ///
    /// A `binding` pins the connection by binding the interface's current
    /// address (`requiredLocalEndpoint`); macOS scoped routing then keeps it
    /// on that interface, route-less storage links included.
    /// `requiredInterface` cannot: the `NWInterface` it needs only comes from
    /// `NWPathMonitor`, which omits interfaces without a default route
    /// (measured 2026-10-02, see the interface-pinning spec).
    public static func connect(
        host: String,
        port: UInt16,
        binding: InterfaceBinding? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> NetworkTransport {
        // One deadline shared by every step of this connect — resolving, any
        // wait for the interface, the bound attempt and a fallback — so a
        // pinned connect never takes longer than an unpinned one would.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        func remaining() throws -> Duration {
            let left = clock.now.duration(to: deadline)
            guard left > .zero else { throw DeadlineError.timedOut }
            return left
        }
        let (transport, fallback) = try await InterfacePinning.connect(
            binding: binding, host: host,
            snapshot: SystemInterfaces.snapshot,
            resolve: { name in
                try await withDeadline(try remaining()) {
                    try await SystemInterfaces.resolveDetached(name)
                }
            },
            waitForInterface: {
                // Re-check the interface every quarter second until the
                // deadline: a re-seated cable takes seconds to get a lease.
                let poll = Duration.milliseconds(250)
                guard clock.now.advanced(by: poll) < deadline else { return false }
                try? await Task.sleep(for: poll)
                return true
            }
        ) { attempt in
            try await openConnection(host: host, port: port, attempt: attempt,
                                     pinnedName: binding?.name, timeout: try remaining())
        }
        transport.connectedPath.fallback = fallback
        return transport
    }

    private static func openConnection(
        host: String, port: UInt16, attempt: InterfacePinning.Attempt,
        pinnedName: String?, timeout: Duration
    ) async throws -> NetworkTransport {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true // iSCSI PDUs are latency-sensitive; disable Nagle
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        // Bound, connect to the address the policy resolved: a bound
        // connection resolves names through the bound interface alone.
        var target = host
        if case .bound(let local, let remote) = attempt {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(local), port: .any)
            target = remote
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(target),
            port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 3260)
        )
        let connection = NWConnection(to: endpoint, using: params)
        let transport = NetworkTransport(connection: connection)

        // While bound, `.waiting` means the interface has no route to the
        // target: macOS reports it within milliseconds (ENETDOWN,
        // EADDRNOTAVAIL) and never escalates it to `.failed`, so waiting it
        // out would only spend the whole deadline.
        let unroutable: (name: String, host: String)? = {
            if case .bound = attempt, let pinnedName { return (pinnedName, host) }
            return nil
        }()
        do {
            try await transport.start(timeout: timeout, unroutable: unroutable)
        } catch {
            // Never leave a failed attempt open: prefer mode is about to open
            // another, and an abandoned NWConnection keeps its socket.
            connection.cancel()
            throw error
        }
        transport.connectedPath.interfaceName =
            connection.currentPath?.availableInterfaces.first?.name
        return transport
    }

    private func start(timeout: Duration, unroutable: (name: String, host: String)?) async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let connection = self.connection
        let queue = self.queue
        try await withDeadline(timeout) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                @Sendable func resumeOnce(_ result: Result<Void, any Error>) {
                    let already = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return done
                    }
                    if !already { c.resume(with: result) }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumeOnce(.success(()))
                    case .failed(let error):
                        resumeOnce(.failure(TransportError.connectFailed("\(error)")))
                    case .cancelled:
                        resumeOnce(.failure(TransportError.closed))
                    case .waiting(let error):
                        if let unroutable, Self.isRouteFailure(error) {
                            resumeOnce(.failure(TransportError.interfaceUnavailable(
                                name: unroutable.name,
                                reason: "it has no route to \(unroutable.host) (\(error))")))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    /// The `.waiting` reasons that mean the bound interface cannot reach the
    /// target at all — measured: EADDRNOTAVAIL, ENETDOWN; plus their
    /// siblings ENETUNREACH and EHOSTUNREACH. Anything else, a refusal above
    /// all, is the target's answer: it runs the deadline exactly as an
    /// unbound connect does, rather than being blamed on the interface and
    /// spending recovery's attempts in milliseconds.
    static func isRouteFailure(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return [.EADDRNOTAVAIL, .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH].contains(code)
    }

    /// Deliver bytes, and give up if the caller stops waiting.
    ///
    /// Must be cancellable: `contentProcessed` never fires against a peer that
    /// stops draining a full socket buffer, and an uninterruptible send here
    /// blocks every command *and* the keepalive that would detect the dead
    /// peer. Cancelling tears down the whole `NWConnection` — correct, because
    /// an incomplete send may have left a partial PDU on the wire, so the
    /// stream is off frame boundary; the session layer rebuilds it.
    public func send(_ data: Data) async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                @Sendable func resumeOnce(_ result: Result<Void, any Error>) {
                    let already = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return done
                    }
                    if !already { c.resume(with: result) }
                }
                // Cancellation can land between installing the handler and
                // this running; a continuation nobody resumes is the bug.
                if Task.isCancelled {
                    resumeOnce(.failure(CancellationError()))
                    return
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        resumeOnce(.failure(TransportError.connectFailed("\(error)")))
                    } else {
                        resumeOnce(.success(()))
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    c.resume(throwing: TransportError.connectFailed("\(error)"))
                } else if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if isComplete {
                    c.resume(returning: nil) // orderly EOF
                } else {
                    c.resume(returning: Data()) // keep the read loop turning
                }
            }
        }
    }

    public func close() async {
        connection.cancel()
    }
}
#endif
