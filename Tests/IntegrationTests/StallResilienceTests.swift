import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// A target that takes commands and never answers them.
///
/// This is the failure the NOP keepalive cannot see: the connection is up, the
/// pings come back, and every I/O hangs forever. Under Backend A that hang does
/// not surface as an error — it propagates through DiskImages into APFS and
/// becomes a wedged volume, which is worse than a reported failure.
@Suite("Integration: stalled-target resilience", .timeLimit(.minutes(1)))
struct StallResilienceTests {
    private func stallingConfig() -> MockTargetConfig {
        var config = MockTargetConfig()
        config.faults.stallCommands = true
        return config
    }

    private func policy(retries: Int = 1, timeout: Duration = .milliseconds(200)) -> SessionPolicy {
        var policy = testPolicy(retries: retries)
        policy.taskTimeout = timeout
        return policy
    }

    @Test func stalledCommandFailsInsteadOfHanging() async throws {
        let fleet = TargetFleet(disk: RAMDisk(), configs: [stallingConfig()])
        let session = ISCSISession(login: standardLogin(), policy: policy()) {
            await fleet.makeTransport()
        }
        try await session.activate()

        await #expect(throws: SessionError.taskTimedOut) {
            _ = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        await fleet.shutdown()
    }

    @Test func stalledCommandSucceedsWhenTheTargetRecovers() async throws {
        // The timeout is not just fail-fast: the retry lands on a re-login, so
        // a target that comes back is picked up without the caller noticing.
        let fleet = TargetFleet(disk: RAMDisk(), configs: [stallingConfig(), MockTargetConfig()])
        let session = ISCSISession(login: standardLogin(), policy: policy(retries: 2)) {
            await fleet.makeTransport()
        }
        try await session.activate()

        let result = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(result.isGood)
        #expect(await session.recoveryCount >= 1)
        await fleet.shutdown()
    }

    @Test func aWedgedSessionIsNotInheritedByTheNextCaller() async throws {
        // After giving up, the connection is dropped rather than left in place,
        // so the next call re-logs in instead of queueing behind the wedge.
        let fleet = TargetFleet(disk: RAMDisk(), configs: [
            stallingConfig(), stallingConfig(), MockTargetConfig(),
        ])
        let session = ISCSISession(login: standardLogin(), policy: policy(retries: 0)) {
            await fleet.makeTransport()
        }
        try await session.activate()

        await #expect(throws: SessionError.taskTimedOut) {
            _ = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        // Second connection is still the stalling one; the third is healthy.
        _ = try? await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        let result = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(result.isGood)
        await fleet.shutdown()
    }

    @Test func cancellationCompletesEvenWhenTaskManagementIsSwallowed() async throws {
        // Regression: cancelling a task used to wait for the ABORT TASK
        // response before resolving the caller. A target sick enough to ignore
        // commands can ignore task management too, and then the cancellation
        // itself hung — so the timeout above would have had nothing to land on.
        var config = MockTargetConfig()
        config.faults.stallCommands = true
        config.faults.swallowTMF = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: config)

        await #expect(throws: DeadlineError.timedOut) {
            try await withDeadline(.milliseconds(200)) {
                _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
            }
        }
        harness.serveTask.cancel()
    }

    @Test func blockDeviceSurfacesAnErrorRatherThanWedging() async throws {
        // What the layers above actually need: a bounded error. Backend A can
        // translate an error into a SCSI failure for DiskImages; it cannot
        // translate a hang into anything at all.
        let fleet = TargetFleet(
            disk: RAMDisk(blockSize: 4096, capacityBlocks: 1024),
            configs: [stallingConfig()]
        )
        let session = ISCSISession(login: standardLogin(), policy: policy(retries: 0)) {
            await fleet.makeTransport()
        }
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: 0, writeThrough: true)

        await #expect(throws: (any Error).self) {
            _ = try await device.readCapacity()
        }
        await fleet.shutdown()
    }
}

// MARK: - A transport that cannot finish a send

/// Wraps another transport and, once armed, accepts a `send` that never
/// completes and cannot be cancelled.
///
/// That is exactly what `NWConnection.send` does against a peer which has
/// stopped draining its socket: `contentProcessed` never fires. Before this was
/// fixed, `NetworkTransport.send` was a bare continuation, so nothing could
/// interrupt it — and because the NOP keepalive sends through the same path, it
/// could not detect the dead peer either. Eight hours of wedged Mac produced
/// not one recovery event, because nothing was ever able to notice.
///
/// `MemoryPipe` never blocks on send, which is why 226 passing tests missed
/// this: MockTarget stalls *responses*, and the incident stalled a *send*.
final class StallingSendTransport: ConnectionTransport, @unchecked Sendable {
    /// Shared with the test so the stall can be armed after login succeeds.
    final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func arm() { lock.lock(); value = true; lock.unlock() }
        var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let inner: any ConnectionTransport
    private let stall: Switch

    init(wrapping inner: any ConnectionTransport, stall: Switch) {
        self.inner = inner
        self.stall = stall
    }

    func send(_ data: Data) async throws {
        if stall.isArmed {
            // No cancellation handler, deliberately: the point is that the
            // layers above must survive a send they cannot interrupt.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        try await inner.send(data)
    }

    func receive() async throws -> Data? { try await inner.receive() }
    func close() async { await inner.close() }
}

extension StallResilienceTests {
    /// The regression test for the eight-hour wedge.
    ///
    /// A stalled *send* must surface as an error within the deadline. It used
    /// to hang forever: `withDeadline` raced the work against a sleep inside a
    /// task group, and a task group cannot return until every child finishes,
    /// so an uncancellable send held the whole thing open. The daemon then
    /// never sent its XPC reply, and the FSKit extension above it blocked until
    /// DiskImages retried — for ever.
    @Test func stalledSendFailsInsteadOfHangingForever() async throws {
        let fleet = TargetFleet(disk: RAMDisk(), configs: [MockTargetConfig()])
        let stall = StallingSendTransport.Switch()
        let session = ISCSISession(login: standardLogin(), policy: policy(retries: 0)) {
            StallingSendTransport(wrapping: await fleet.makeTransport(), stall: stall)
        }
        try await session.activate()

        // Healthy first, so the failure below is the stall and not the setup.
        let before = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(before.isGood)

        stall.arm()
        await #expect(throws: (any Error).self) {
            _ = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        await fleet.shutdown()
    }
}
