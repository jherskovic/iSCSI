#if canImport(Network)
import Foundation
import Network
import iSCSIKit

/// A loopback TCP listener that serves one `MockTarget` per accepted
/// connection. Lets tests drive the real `NetworkTransport` end-to-end over
/// an actual socket instead of the in-memory pipe.
public actor MockTargetServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mocktarget.listener")
    private let makeConfig: @Sendable () -> MockTargetConfig
    private let disk: RAMDisk
    public private(set) var port: UInt16 = 0
    private var serveTasks: [Task<Void, Never>] = []

    public init(
        disk: RAMDisk = RAMDisk(),
        config: @escaping @Sendable () -> MockTargetConfig = { MockTargetConfig() }
    ) throws {
        self.disk = disk
        self.makeConfig = config
        self.listener = try NWListener(using: .tcp)
    }

    /// Start listening; returns the bound port.
    public func start() async throws -> UInt16 {
        let listener = self.listener
        let disk = self.disk
        let makeConfig = self.makeConfig
        listener.newConnectionHandler = { [weak self] connection in
            let transport = NWConnectionTransport(connection: connection, queue: self?.queueForConnection ?? DispatchQueue(label: "conn"))
            let target = MockTarget(config: makeConfig(), disk: disk, transport: transport)
            Task { await self?.track(Task { await target.run() }) }
        }
        return try await withCheckedThrowingContinuation { continuation in
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
    }

    private nonisolated var queueForConnection: DispatchQueue {
        DispatchQueue(label: "mocktarget.conn")
    }

    private func track(_ task: Task<Void, Never>) {
        serveTasks.append(task)
    }

    public func stop() {
        listener.cancel()
        for task in serveTasks { task.cancel() }
        serveTasks = []
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
