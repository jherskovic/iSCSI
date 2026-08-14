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
