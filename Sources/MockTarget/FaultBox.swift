import Foundation

/// Faults that can be switched on and off while the target is serving —
/// for the standalone simulator, where the point is breaking things *during*
/// a run. A lock, not an actor: fault checks sit on the PDU path and an
/// `await` per PDU buys nothing.
public final class FaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var faults: MockTargetFaults
    /// Bumped by `drop`/`crash` so a connection can tell "I was told to die"
    /// from "the peer went away".
    private var generation: UInt64 = 0

    public init(_ initial: MockTargetFaults = MockTargetFaults()) {
        self.faults = initial
    }

    public var value: MockTargetFaults {
        lock.lock(); defer { lock.unlock() }
        return faults
    }

    public func set(_ faults: MockTargetFaults) {
        lock.lock(); defer { lock.unlock() }
        self.faults = faults
    }

    public func mutate(_ body: (inout MockTargetFaults) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&faults)
    }

    public func clear() {
        set(MockTargetFaults())
    }

    public var currentGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    public func bumpGeneration() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
    }
}
