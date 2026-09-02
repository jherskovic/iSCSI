import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// Concurrent failures must coalesce onto ONE recovery.
///
/// Both engines guard against concurrent recovery with
/// `if let existing = recoveryTask { … }`, but assign `recoveryTask` only
/// *after* an `await` (closing the old connection / dropping the queues).
/// Actor isolation does not span a suspension point, so two callers can both
/// see `nil`, both tear the session down, and both rebuild it.
///
/// This is not theoretical. A live NVMe/TCP session logged it on 2026-09-02:
///
///     09:41:40.690699  recovery attempt 1/5
///     09:41:40.690771  recovery attempt 1/5     <- 72 µs later
///     09:41:40.697526  recovered (10 time(s) so far)
///     09:41:41.211807  recovered (11 time(s) so far)
///
/// Two in-flight commands hit their deadline together and each rebuilt the
/// session, double-counting the recovery and running the teardown twice
/// against a pair the other was rebuilding. See docs/resilience.md.
///
/// The shape here is the one that produced it: several commands in flight when
/// the connection dies, so they all take the recovery path at the same instant.
@Suite("Integration: recovery coalescing", .timeLimit(.minutes(1)))
struct RecoveryCoalescingTests {

    /// Lock rather than an actor: `setEventHandler` takes a synchronous
    /// `@Sendable` closure, and hopping to an actor from inside it would let
    /// the counts settle after the assertions read them.
    final class EventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var lost = 0
        private var recovered = 0
        private var attempts = 0

        func note(_ event: SessionEvent) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .connectionLost: lost += 1
            case .recovered: recovered += 1
            case .recoveryAttempt: attempts += 1
            case .recoveryExhausted: break
            }
        }
        var connectionLost: Int { lock.lock(); defer { lock.unlock() }; return lost }
        var recoveries: Int { lock.lock(); defer { lock.unlock() }; return recovered }
        var recoveryAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    }

    static func droppingNVMe(after pdus: Int) -> MockTargetFaults {
        var faults = MockTargetFaults()
        faults.dropAfterSentPDUs = pdus
        return faults
    }

    @Test func nvmeConcurrentFailuresCoalesceOntoOneRecovery() async throws {
        // Connection order: admin, I/O, then the recovered pair. The I/O queue
        // dies after its first completion, with the rest of the batch still in
        // flight — so several commands fail together.
        let fleet = NVMeFleet(faultScripts: [MockTargetFaults(),
                                             Self.droppingNVMe(after: 1),
                                             MockTargetFaults()])
        let controller = try await activatedController(fleet: fleet)
        let counter = EventCounter()
        await controller.setEventHandler { counter.note($0) }

        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        _ = try await device.readCapacity()

        let payload = Data(repeating: 0x5A, count: 4096)
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 8 {
                group.addTask { try? await device.write(offset: UInt64(i) * 4096, data: payload) }
            }
        }

        // One connection died, so exactly one recovery episode should be
        // reported and exactly one performed.
        #expect(counter.connectionLost == 1)
        #expect(counter.recoveries == 1)
        #expect(await controller.recoveryCount == 1)
        await fleet.shutdown()
    }

    @Test func iscsiConcurrentFailuresCoalesceOntoOneRecovery() async throws {
        var dropping = MockTargetConfig()
        dropping.faults.dropAfterSentPDUs = 1
        let fleet = TargetFleet(configs: [dropping, MockTargetConfig()])
        let session = ISCSISession(login: standardLogin(),
                                   policy: testPolicy(),
                                   transportFactory: { await fleet.makeTransport() })
        let counter = EventCounter()
        await session.setEventHandler { counter.note($0) }
        try await session.activate()

        let device = ISCSIBlockDevice(session: session, lun: 0)
        _ = try await device.readCapacity()

        let payload = Data(repeating: 0x3C, count: 4096)
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 8 {
                group.addTask { try? await device.write(offset: UInt64(i) * 4096, data: payload) }
            }
        }

        #expect(counter.connectionLost == 1)
        #expect(counter.recoveries == 1)
        #expect(await session.recoveryCount == 1)
        await fleet.shutdown()
    }
}
