import Foundation

/// Byte-stream transport for one iSCSI connection. Implementations:
/// Network.framework TCP (daemon) and `MemoryPipe` (tests).
public protocol ConnectionTransport: Sendable {
    /// Deliver bytes to the peer. Throws when the connection is down.
    func send(_ data: Data) async throws
    /// Next chunk from the peer; nil on orderly EOF. Chunk boundaries carry
    /// no meaning — the deframer reassembles PDUs.
    func receive() async throws -> Data?
    /// Tear down; pending receives complete with nil/error.
    func close() async
}

public enum TransportError: Error, Equatable, Sendable {
    case closed
    case connectFailed(String)
}

/// In-memory duplex pipe: two coupled transports, used by unit/integration
/// tests and the in-process MockTarget.
public final class MemoryPipe: ConnectionTransport, @unchecked Sendable {
    private let outbound: Channel
    private let inbound: Channel

    private init(outbound: Channel, inbound: Channel) {
        self.outbound = outbound
        self.inbound = inbound
    }

    /// Two connected endpoints: bytes sent on one arrive at the other.
    public static func pair() -> (MemoryPipe, MemoryPipe) {
        let ab = Channel()
        let ba = Channel()
        return (
            MemoryPipe(outbound: ab, inbound: ba),
            MemoryPipe(outbound: ba, inbound: ab)
        )
    }

    public func send(_ data: Data) async throws {
        try await outbound.write(data)
    }

    public func receive() async throws -> Data? {
        try await inbound.read()
    }

    public func close() async {
        await outbound.close()
        await inbound.close()
    }

    /// One direction of the pipe: an async byte queue with EOF.
    actor Channel {
        private var buffer: [Data] = []
        private var closed = false
        private var waiter: CheckedContinuation<Data?, any Error>?

        func write(_ data: Data) throws {
            guard !closed else { throw TransportError.closed }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: data)
            } else {
                buffer.append(data)
            }
        }

        func read() async throws -> Data? {
            if !buffer.isEmpty {
                return buffer.removeFirst()
            }
            if closed { return nil }
            return try await withCheckedThrowingContinuation { c in
                assert(waiter == nil, "single reader only")
                waiter = c
            }
        }

        func close() {
            closed = true
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: nil)
            }
        }
    }
}
