import Foundation

/// Faults that can be switched on and off while the target is serving.
///
/// The existing integration tests hand `MockTargetFaults` to a target at init
/// and never change it, and that path still works untouched. This box exists
/// for the standalone simulator, where the whole point is to break things
/// *during* a run — drop the connection in the middle of a soak, turn on
/// corruption for ten seconds, then turn it off and see whether the initiator
/// recovered.
///
/// A lock rather than an actor on purpose: every fault check in `MockTarget`
/// sits on the PDU path, and making them `await` would add a suspension point
/// per PDU and reorder nothing usefully. Reads are a lock, a struct copy, and
/// an unlock.
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
