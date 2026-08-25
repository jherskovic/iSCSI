import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// A transport factory that "reboots" the MockTarget: every call spins up a
/// fresh target connection sharing one RAMDisk, so state survives like a real
/// NAS reboot. Configs are consumed in order; the last one repeats.
actor TargetFleet {
    let disk: RAMDisk
    private var configs: [MockTargetConfig]
    private(set) var connectionsServed = 0
    private var harnesses: [TargetHarness] = []

    init(disk: RAMDisk = RAMDisk(), configs: [MockTargetConfig]) {
        precondition(!configs.isEmpty)
        self.disk = disk
        self.configs = configs
    }

    func makeTransport() -> any ConnectionTransport {
        let config = configs.count > 1 ? configs.removeFirst() : configs[0]
        let harness = TargetHarness.start(config: config, disk: disk)
        harnesses.append(harness)
        connectionsServed += 1
        return harness.transport
    }

    func shutdown() async {
        for h in harnesses {
            await h.target.stop()
            h.serveTask.cancel()
        }
        harnesses = []
    }
}

@Suite("Integration: session recovery (ERL0)", .timeLimit(.minutes(1)))
struct SessionRecoveryTests {
    func makeSession(
        fleet: TargetFleet,
        policy: SessionPolicy = testPolicy(),
        chap: CHAP.Credentials? = nil
    ) -> ISCSISession {
        ISCSISession(
            login: standardLogin(chap: chap),
            policy: policy,
            transportFactory: { await fleet.makeTransport() }
        )
    }

    @Test func sessionRecoversAfterTargetDrop() async throws {
        var dropping = MockTargetConfig()
        dropping.faults.dropAfterSentPDUs = 1 // dies right after the first response
        let fleet = TargetFleet(configs: [dropping, MockTargetConfig()])
        let session = makeSession(fleet: fleet)
        try await session.activate()

        // First target completes the write, then drops the connection; the
        // subsequent read must transparently recover onto the second target.
        let pattern = Data(repeating: 0x77, count: 512)
        let write = try await session.execute(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 9, blocks: 1), direction: .write(pattern)
        ))
        #expect(write.isGood)

        let read = try await session.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 9, blocks: 1), direction: .read(expectedLength: 512)
        ))
        #expect(read.data == pattern) // RAMDisk shared across "reboot"
        #expect(await session.recoveryCount >= 1)
        #expect(await fleet.connectionsServed == 2)
        await fleet.shutdown()
    }

    @Test func dataSurvivesTargetReboot() async throws {
        let fleet = TargetFleet(configs: [MockTargetConfig(), MockTargetConfig()])
        let session = makeSession(fleet: fleet)
        try await session.activate()

        let pattern = Data((0 ..< 2048).map { UInt8(($0 &* 13) & 0xFF) })
        _ = try await session.executeChecked(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 100, blocks: 4), direction: .write(pattern)
        ))

        // Simulated reboot: current connection torn down out from under us.
        await fleet.shutdown()
        let read = try await session.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 100, blocks: 4), direction: .read(expectedLength: 2048)
        ))
        #expect(read.data == pattern) // RAMDisk persisted across "reboot"
        #expect(await session.recoveryCount >= 1)
        await fleet.shutdown()
    }

    @Test func recoveryExhaustionSurfaces() async throws {
        var rejecting = MockTargetConfig()
        rejecting.faults.rejectLoginStatus = (class: 3, detail: 1) // target error
        let fleet = TargetFleet(configs: [rejecting])
        let session = makeSession(fleet: fleet, policy: testPolicy(recoveryAttempts: 2))
        await #expect(throws: (any Error).self) {
            try await session.activate()
        }
        await fleet.shutdown()
    }

    @Test func keepaliveDetectsDeadPeerAndSessionRecovers() async throws {
        // First target keeps TCP up but silently swallows NOPs: only the
        // keepalive can notice the peer is dead.
        var mute = MockTargetConfig()
        mute.faults.swallowNops = true
        let fleet = TargetFleet(configs: [mute, MockTargetConfig()])
        let session = makeSession(
            fleet: fleet,
            policy: testPolicy(nopInterval: .milliseconds(50))
        )
        try await session.activate()

        // Keepalive ping times out (250 ms) → connection closed → the next
        // execute() recovers onto the healthy target.
        //
        // Polled, not slept: fixed waits fail on loaded CI runners. execute()
        // is inside the loop because it drives recovery and succeeds against
        // the mute target until the keepalive kills that connection — the exit
        // condition is the second connection, not a successful command.
        let deadline = ContinuousClock.now + .seconds(10)
        var recovered: SCSITaskResult?
        while ContinuousClock.now < deadline {
            let attempt = try? await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
            if await fleet.connectionsServed >= 2 {
                recovered = attempt
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await fleet.connectionsServed >= 2,
                "the keepalive never noticed the mute peer within 10s")
        let result = try #require(recovered, "no command completed after recovery")
        #expect(result.isGood)
        await fleet.shutdown()
    }

    @Test func logoutStopsRecovery() async throws {
        let fleet = TargetFleet(configs: [MockTargetConfig()])
        let session = makeSession(fleet: fleet)
        try await session.activate()
        try await session.logout()
        await #expect(throws: SessionError.self) {
            _ = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        // No sneaky reconnect after explicit logout.
        #expect(await fleet.connectionsServed == 1)
        await fleet.shutdown()
    }

    @Test func chapSurvivesRecovery() async throws {
        var chapTarget = MockTargetConfig()
        chapTarget.requireChap = true
        chapTarget.chapUser = "u"
        chapTarget.chapSecret = "s"
        var droppingChap = chapTarget
        droppingChap.faults.dropAfterSentPDUs = 1
        let fleet = TargetFleet(configs: [droppingChap, chapTarget])
        let session = makeSession(fleet: fleet, chap: CHAP.Credentials(name: "u", secret: "s"))
        try await session.activate()
        // First command succeeds, then the connection drops; the second must
        // re-run the whole CHAP login during recovery.
        _ = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        let result = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(result.isGood)
        #expect(await session.recoveryCount >= 1)
        await fleet.shutdown()
    }

    @Test func recoveryOntoBrokenTargetSurfacesError() async throws {
        // Healthy target dies; every replacement refuses login. The retry +
        // recovery budget must run out and surface an error, not spin forever.
        var rejecting = MockTargetConfig()
        rejecting.faults.rejectLoginStatus = (class: 3, detail: 1)
        let fleet = TargetFleet(configs: [MockTargetConfig(), rejecting])
        let session = makeSession(
            fleet: fleet,
            policy: testPolicy(retries: 1, recoveryAttempts: 2)
        )
        try await session.activate()
        await fleet.shutdown() // kill the healthy connection
        await #expect(throws: (any Error).self) {
            _ = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        await fleet.shutdown()
    }
}
