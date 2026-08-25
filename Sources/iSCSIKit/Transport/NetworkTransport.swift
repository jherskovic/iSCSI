#if canImport(Network)
import Foundation
import Network
import os

/// TCP transport over Network.framework for a real iSCSI connection.
/// Used by the daemon and by `iscsictl` against a live target.
public final class NetworkTransport: ConnectionTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "iscsi.transport")

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Open a TCP connection to host:port and wait until it is ready.
    public static func connect(
        host: String,
        port: UInt16,
        timeout: Duration = .seconds(10)
    ) async throws -> NetworkTransport {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true // iSCSI PDUs are latency-sensitive; disable Nagle
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 3260)
        )
        let connection = NWConnection(to: endpoint, using: params)
        let transport = NetworkTransport(connection: connection)
        try await transport.start(timeout: timeout)
        return transport
    }

    private func start(timeout: Duration) async throws {
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
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
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
