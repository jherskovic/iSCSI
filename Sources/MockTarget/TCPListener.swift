#if canImport(Network)
import Foundation
import Network
import iSCSIKit

/// A TCP listener serving one target connection per accepted socket: an
/// ephemeral port for socket-level tests, a fixed port for the standalone
/// simulator. Tracks live connections so `drop` can kill them. What serves
/// a connection is injected, so the same listener fronts an iSCSI
/// `MockTarget` or an NVMe/TCP `MockNVMeSubsystem`.
public actor MockTargetServer {
    public typealias Handler = @Sendable (any ConnectionTransport) async -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mocktarget.listener")
    private let serve: Handler
    public private(set) var port: UInt16 = 0

    private struct LiveConnection {
        let connection: NWConnection
        let task: Task<Void, Never>
    }

    private var live: [UInt64: LiveConnection] = [:]
    private var nextID: UInt64 = 0
    /// While paused, accepted connections are reset immediately. That is a
    /// portal that answers and then hangs up, not a black hole — enough to
    /// exercise re-login backoff and recovery exhaustion, but it does not
    /// simulate a dropped route (that needs pf).
    private var paused = false

    public private(set) var acceptedCount = 0
    public private(set) var refusedWhilePaused = 0

    /// The iSCSI form: one `MockTarget` per connection over a shared disk.
    public init(
        port: UInt16 = 0,
        disk: RAMDisk = RAMDisk(),
        faultBox: FaultBox = FaultBox(),
        config: @escaping @Sendable () -> MockTargetConfig = { MockTargetConfig() }
    ) throws {
        try self.init(port: port) { transport in
            await MockTarget(config: config(), disk: disk, faultBox: faultBox, transport: transport).run()
        }
    }

    /// The general form: `serve` runs one accepted connection to completion.
    public init(port: UInt16 = 0, serve: @escaping Handler) throws {
        self.serve = serve
        if port == 0 {
            self.listener = try NWListener(using: .tcp)
        } else {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                throw NWError.posix(.EINVAL)
            }
            self.listener = try NWListener(using: .tcp, on: endpointPort)
        }
    }

    /// Start listening; returns the bound port.
    public func start() async throws -> UInt16 {
        let listener = self.listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBool()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue, !resumed.setTrue() {
                        continuation.resume(returning: p)
                    }
                case .failed(let error):
                    if !resumed.setTrue() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        port = bound
        return bound
    }

    private func accept(_ connection: NWConnection) {
        if paused {
            refusedWhilePaused += 1
            connection.cancel()
            return
        }
        acceptedCount += 1
        let id = nextID
        nextID &+= 1
        let transport = NWConnectionTransport(
            connection: connection,
            queue: DispatchQueue(label: "mocktarget.conn.\(id)")
        )
        let serve = self.serve
        let task = Task { [weak self] in
            await serve(transport)
            await self?.retire(id)
        }
        live[id] = LiveConnection(connection: connection, task: task)
    }

    private func retire(_ id: UInt64) {
        live.removeValue(forKey: id)
    }

    /// Hard-drop every live connection. The initiator sees the transport die
    /// mid-command, which is the ERL0 recovery trigger.
    @discardableResult
    public func dropAll() -> Int {
        let count = live.count
        for entry in live.values {
            entry.connection.cancel()
            entry.task.cancel()
        }
        live.removeAll()
        return count
    }

    public func pauseAccepting() {
        paused = true
    }

    public func resumeAccepting() {
        paused = false
    }

    public var isPaused: Bool { paused }
    public var liveConnections: Int { live.count }

    public func stop() {
        listener.cancel()
        dropAll()
    }
}

/// Server-side transport wrapping an accepted NWConnection.
final class NWConnectionTransport: ConnectionTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var started = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        connection.start(queue: queue)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
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

    func close() async {
        connection.cancel()
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Returns the previous value; sets to true.
    func setTrue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { value = true }
        return value
    }
}
#endif
