import Foundation
import Network

/// A line-protocol control socket, loopback only.
///
/// One command per line, one line of response. Deliberately dumb so a shell
/// script or a Python test can drive it without a client library:
///
///     printf 'crash\n' | nc 127.0.0.1 3261
///
/// Binding to loopback is the whole of the access control, which is right for
/// a test fixture whose entire purpose is to corrupt data on demand — this must
/// never be reachable from the network the target serves.
actor ControlChannel {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "targetsim.control")
    private let handle: @Sendable (String) async -> String
    public private(set) var port: UInt16 = 0

    init(port: UInt16, handler: @escaping @Sendable (String) async -> String) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bind to 127.0.0.1 by pinning the local endpoint. Passing both this
        // and `on:` is rejected with EINVAL — the port is already implied here.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)
        self.listener = try NWListener(using: parameters)
        self.handle = handler
    }

    @discardableResult
    func start() async throws -> UInt16 {
        let listener = self.listener
        let handle = self.handle
        listener.newConnectionHandler = { connection in
            let queue = DispatchQueue(label: "targetsim.control.conn")
            connection.start(queue: queue)
            Task { await ControlChannel.serve(connection, handle) }
        }
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue, once.claim() {
                        continuation.resume(returning: p)
                    }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        port = bound
        return bound
    }

    func stop() {
        listener.cancel()
    }

    private static func serve(
        _ connection: NWConnection,
        _ handle: @Sendable (String) async -> String
    ) async {
        var pending = Data()
        while true {
            // `try?` would flatten the optional and lose the difference
            // between "socket error" and "peer closed"; both end the loop, but
            // only one of them should also drop a half-read command.
            let received: Data?
            do {
                received = try await receive(connection)
            } catch {
                return
            }
            guard let chunk = received else { break } // peer closed
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineBytes = pending[pending.startIndex ..< newline]
                pending = pending[pending.index(after: newline)...]
                let line = String(decoding: lineBytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                let reply = await handle(line) + "\n"
                try? await send(connection, Data(reply.utf8))
            }
        }
        // A command sent without a trailing newline is still a command.
        let trailing = String(decoding: pending, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            let reply = await handle(trailing) + "\n"
            try? await send(connection, Data(reply.utf8))
        }
        connection.cancel()
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    c.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if isComplete {
                    c.resume(returning: nil)
                } else {
                    c.resume(returning: Data())
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    /// True exactly once.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
