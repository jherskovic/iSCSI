import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// Every test here scripts a misbehaving/hostile target and asserts the
/// initiator detects the condition and fails safely (ERL0: tear down the
/// connection) instead of hanging, corrupting data, or crashing.
@Suite("Integration: hostile target scripts", .timeLimit(.minutes(1)))
struct HostileTargetTests {
    // MARK: Login-phase hostility

    @Test func loginRejectedWithAuthFailure() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.rejectLoginStatus = (class: 2, detail: 1)
        let harness = TargetHarness.start(config: targetConfig)
        let connection = ISCSIConnection(transport: harness.transport, login: standardLogin())
        do {
            _ = try await connection.login()
            Issue.record("login must fail")
        } catch ConnectionError.loginFailed(.loginFailed(let statusClass, let statusDetail)) {
            #expect(statusClass == 2 && statusDetail == 1)
        }
        harness.serveTask.cancel()
    }

    @Test func loginRedirectSurfacesAddress() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.redirectTo = "10.9.9.9:3260,1"
        let harness = TargetHarness.start(config: targetConfig)
        let connection = ISCSIConnection(transport: harness.transport, login: standardLogin())
        do {
            _ = try await connection.login()
            Issue.record("expected redirect")
        } catch ConnectionError.redirected(let address, let permanent) {
            #expect(address == "10.9.9.9:3260,1")
            #expect(permanent)
        }
        harness.serveTask.cancel()
    }

    @Test func wrongTargetNameRefused() async throws {
        let harness = TargetHarness.start()
        let connection = ISCSIConnection(
            transport: harness.transport,
            login: standardLogin(targetName: "iqn.2026-08.test.example:no-such-disk")
        )
        do {
            _ = try await connection.login()
            Issue.record("login must fail")
        } catch ConnectionError.loginFailed(.loginFailed(let statusClass, let statusDetail)) {
            #expect(statusClass == 2 && statusDetail == 3) // target not found
        }
        harness.serveTask.cancel()
    }

    // MARK: Sequence-number attacks

    @Test func statSNJumpKillsConnection() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.statSNJump = 5
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        harness.serveTask.cancel()
    }

    @Test func duplicateStatSNKillsConnection() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.duplicateStatSN = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        harness.serveTask.cancel()
    }

    // MARK: Digest corruption

    @Test func corruptedDataDetectedByDataDigest() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.digestPick = "CRC32C"
        targetConfig.faults.corruptDataInPayload = true
        let (connection, harness, result) = try await loggedInConnection(targetConfig: targetConfig) {
            $0.desired.offerDigests = true
        }
        #expect(result.parameters.dataDigest)
        // The corrupted Data-In must be caught by CRC32C → connection dies;
        // the read MUST NOT return silently corrupted bytes.
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.execute(SCSITask(
                lun: 0, cdb: CDB.read16(lba: 0, blocks: 1), direction: .read(expectedLength: 512)
            ))
        }
        harness.serveTask.cancel()
    }

    @Test func corruptionInvisibleWithoutDigest() async throws {
        // Control case documenting WHY digests matter: with DataDigest=None
        // the same corruption sails through TCP checksums unnoticed.
        var targetConfig = MockTargetConfig()
        targetConfig.faults.corruptDataInPayload = true
        let disk = RAMDisk()
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig, disk: disk)
        let read = try await connection.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 0, blocks: 1), direction: .read(expectedLength: 512)
        ))
        #expect(read.isGood)
        let clean = await disk.read(lba: 0, blocks: 1)!
        #expect(read.data != clean) // silently corrupted — digests are the defense
        harness.serveTask.cancel()
    }

    @Test func corruptedHeaderDetectedByHeaderDigest() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.digestPick = "CRC32C"
        targetConfig.faults.corruptHeaderDigestOnce = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig) {
            $0.desired.offerDigests = true
        }
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        harness.serveTask.cancel()
    }

    // MARK: Data-path violations

    @Test func unexpectedR2TOnReadKillsConnection() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.unsolicitedR2T = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.execute(SCSITask(
                lun: 0, cdb: CDB.read16(lba: 0, blocks: 1), direction: .read(expectedLength: 512)
            ))
        }
        harness.serveTask.cancel()
    }

    @Test func oversizedDataInRejected() async throws {
        // We declared MRDSL 4096; target sends a 16 KiB Data-In segment.
        var targetConfig = MockTargetConfig()
        targetConfig.faults.oversizeDataIn = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig) {
            $0.desired.maxRecvDataSegmentLength = 4096
        }
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.execute(SCSITask(
                lun: 0, cdb: CDB.read16(lba: 0, blocks: 32), direction: .read(expectedLength: 16384)
            ))
        }
        harness.serveTask.cancel()
    }

    @Test func rejectPDUFailsOnlyThatTask() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.rejectAllCommands = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        do {
            _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
            Issue.record("expected task rejection")
        } catch ConnectionError.taskRejected(let reason) {
            #expect(reason == .commandNotSupported)
        }
        // Connection survives a task-scoped Reject: NOP still works.
        try await connection.ping()
        harness.serveTask.cancel()
    }

    @Test func checkConditionCarriesSense() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.checkConditionAll = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        let result = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(result.status == 0x02)
        let senseBytes = try #require(result.sense)
        let sense = try #require(SenseData(senseBytes))
        #expect(sense.key == 0x05) // ILLEGAL REQUEST
        #expect(sense.asc == 0x20) // INVALID COMMAND OPERATION CODE
        harness.serveTask.cancel()
    }

    // MARK: Stalls and timeouts

    @Test func timedOutCommandIsAutoAborted() async throws {
        // Cancelling execute() (here via deadline) must fire ABORT TASK at the
        // target so the orphaned command doesn't linger server-side.
        var targetConfig = MockTargetConfig()
        targetConfig.faults.stallCommands = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)

        await #expect(throws: DeadlineError.timedOut) {
            try await withDeadline(.milliseconds(200)) {
                _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
            }
        }
        // Give the cancellation-handler TMF a moment to land.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.target.stalledITTs.isEmpty)
        // The connection is still healthy after the abort.
        try await connection.ping()
        harness.serveTask.cancel()
    }

    @Test func lunResetClearsStalledTasks() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.stallCommands = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        // Unstructured tasks (not cancelled) pile up server-side.
        let hung = (0 ..< 3).map { _ in
            Task { try? await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady())) }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.target.stalledITTs.count == 3)

        let tmf = try await connection.taskManagement(.lunReset, lun: 0)
        #expect(tmf == .functionComplete)
        #expect(await harness.target.stalledITTs.isEmpty)

        // Tear down so the hung initiator-side tasks resolve rather than leak.
        await connection.close()
        for task in hung { _ = await task.value }
        harness.serveTask.cancel()
    }

    @Test func writeStallAfterR2TTimesOut() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.preferInitialR2T = true // all data solicited
        targetConfig.preferImmediateData = false
        targetConfig.faults.stallAfterR2T = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        await #expect(throws: DeadlineError.timedOut) {
            try await withDeadline(.milliseconds(300)) {
                _ = try await connection.execute(SCSITask(
                    lun: 0,
                    cdb: CDB.write16(lba: 0, blocks: 8),
                    direction: .write(Data(repeating: 1, count: 4096))
                ))
            }
        }
        harness.serveTask.cancel()
    }

    @Test func frozenCommandWindowBlocksSubmission() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.freezeWindow = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        // MaxCmdSN < CmdSN forever → the initiator must queue, not send.
        await #expect(throws: DeadlineError.timedOut) {
            try await withDeadline(.milliseconds(200)) {
                _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
            }
        }
        harness.serveTask.cancel()
    }

    // MARK: Connection drops

    @Test func dropMidReadFailsPendingTasks() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.maxRecvDataSegmentLength = 4096
        targetConfig.faults.dropDuringDataInAt = 2
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig) {
            $0.desired.maxRecvDataSegmentLength = 4096
        }
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.execute(SCSITask(
                lun: 0, cdb: CDB.read16(lba: 0, blocks: 64), direction: .read(expectedLength: 32768)
            ))
        }
        harness.serveTask.cancel()
    }

    @Test func abruptDropFailsAllInFlightOperations() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.stallCommands = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        // Queue several tasks, then kill the target side.
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    do {
                        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
                        return false
                    } catch {
                        return true // must fail, not hang
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                await harness.target.stop()
                return true
            }
            var all: [Bool] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.allSatisfy { $0 })
        harness.serveTask.cancel()
    }
}
