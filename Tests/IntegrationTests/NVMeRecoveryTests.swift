import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// Connection loss on either queue destroys the controller and the next
/// command rebuilds a fresh admin + I/O pair — the `SessionRecoveryTests`
/// twin. Fault scripts are per connection, in the order the controller
/// opens them: admin first, then I/O, then the recovered pair.
@Suite("Integration: NVMe/TCP controller recovery", .timeLimit(.minutes(1)))
struct NVMeRecoveryTests {
    static let healthy = MockTargetFaults()

    static func dropping(after pdus: Int) -> MockTargetFaults {
        var faults = MockTargetFaults()
        faults.dropAfterSentPDUs = pdus
        return faults
    }

    @Test func controllerRecoversAfterTheIOQueueDrops() async throws {
        // The I/O queue dies right after its first completion; the next
        // command must transparently bring up a new pair.
        let fleet = NVMeFleet(faultScripts: [Self.healthy, Self.dropping(after: 1), Self.healthy])
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        _ = try await device.readCapacity()

        let pattern = Data(repeating: 0x77, count: 4096)
        try await device.write(offset: 4096, data: pattern)
        #expect(try await device.read(offset: 4096, length: 4096) == pattern)   // RAMDisk shared across "reboot"
        #expect(await controller.recoveryCount == 1)
        #expect(await fleet.connectionsServed == 4)
        await fleet.shutdown()
    }

    @Test func controllerRecoversAfterTheAdminQueueDrops() async throws {
        // Admin queue dies after Set Features (its last bring-up command);
        // the I/O queue was healthy, but the pair goes down as a unit.
        let fleet = NVMeFleet(faultScripts: [Self.dropping(after: 10), Self.healthy, Self.healthy])
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        // Drive admin traffic until the drop lands, then I/O must recover.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, await controller.recoveryCount == 0 {
            _ = try? await controller.activeNamespaces()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await controller.recoveryCount >= 1)
        #expect(try await device.readCapacity().blockSize == 4096)
        await fleet.shutdown()
    }

    @Test func dataSurvivesTargetReboot() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let pattern = Data((0 ..< 8192).map { UInt8(($0 &* 13) & 0xFF) })
        try await device.write(offset: 0, data: pattern)

        await fleet.shutdown()   // both connections torn down out from under us
        #expect(try await device.read(offset: 0, length: 8192) == pattern)
        #expect(await controller.recoveryCount >= 1)
        await fleet.shutdown()
    }

    /// A header digest error is fatal for the connection (NVMe/TCP 1.1
    /// §3.5): the host names it in an H2CTermReq, the controller pair goes,
    /// and the command is retried on a fresh pair — never completed from a
    /// header that failed its digest.
    @Test func aHeaderDigestErrorTearsTheQueueDownAndTheCommandIsRetried() async throws {
        var corrupt = MockTargetFaults()
        corrupt.corruptHeaderDigestOnce = true
        let fleet = NVMeFleet(faultScripts: [Self.healthy, corrupt, Self.healthy])
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 1, recoveryAttempts: 2)) { $0.requestDigests = true }
        #expect(await controller.digests.header)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        _ = try await device.readCapacity()                     // admin queue: clean

        let pattern = Data((0 ..< 4096).map { UInt8(($0 &* 29) & 0xFF) })
        try await device.write(offset: 0, data: pattern)       // first I/O completion arrives corrupted
        #expect(await eventually { await fleet.subsystem.h2cTermReqsReceived.count == 1 })
        #expect(await fleet.subsystem.h2cTermReqsReceived == [.headerDigestError])
        #expect(await controller.recoveryCount == 1)
        #expect(await fleet.connectionsServed == 4)
        #expect(try await device.read(offset: 0, length: 4096) == pattern)
        await fleet.shutdown()
    }

    /// A controller that solicits a write and then never takes the data:
    /// the task deadline, not the controller, ends the wait, and the retry
    /// runs on a fresh pair rather than behind the wedged one.
    @Test func aWriteStalledAfterItsR2TTimesOutAndRunsOnAFreshPair() async throws {
        var config = MockNVMeConfig()
        config.inCapsuleDataBytes = 0                          // every write is solicited
        var stall = MockTargetFaults()
        stall.stallAfterR2T = true
        let fleet = NVMeFleet(config: config, faultScripts: [Self.healthy, stall, Self.healthy])
        var policy = testPolicy(retries: 1, recoveryAttempts: 2)
        policy.taskTimeout = .milliseconds(300)
        let controller = try await activatedController(fleet: fleet, policy: policy)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        _ = try await device.readCapacity()

        let pattern = Data((0 ..< 8192).map { UInt8(($0 &* 11) & 0xFF) })
        // Bounded here too, so a missing task deadline fails rather than hangs.
        try await withDeadline(.seconds(10)) { try await device.write(offset: 0, data: pattern) }
        #expect(await fleet.subsystem.r2tsSent == 2)           // one swallowed, one answered
        #expect(await controller.recoveryCount == 1)
        #expect(try await device.read(offset: 0, length: 8192) == pattern)
        await fleet.shutdown()
    }

    static let rejecting: MockTargetFaults = {
        var f = MockTargetFaults(); f.rejectLoginStatus = (class: 3, detail: 1); return f
    }()

    // The log promises "every I/O on this session will now fail" once recovery
    // is exhausted. It must mean it: a dead controller latches, and later
    // commands fail at once rather than each re-running the full recovery
    // budget — the loop that kept the extension and app hung for 15 minutes
    // against an unreachable NAS on 2026-09-11.
    @Test func aDeadControllerLatchesInsteadOfRetryingEveryCommand() async throws {
        let fleet = NVMeFleet(faultScripts: [Self.healthy, Self.healthy, Self.rejecting])
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 1, recoveryAttempts: 2))
        let counter = RecoveryCoalescingTests.EventCounter()
        await controller.setEventHandler { counter.note($0) }
        await fleet.shutdown()
        await #expect(throws: (any Error).self) { _ = try await controller.activeNamespaces() }
        let attemptsAfterFirst = counter.recoveryAttempts
        #expect(attemptsAfterFirst > 0)
        await #expect(throws: (any Error).self) { _ = try await controller.activeNamespaces() }
        #expect(counter.recoveryAttempts == attemptsAfterFirst)
        await fleet.shutdown()
    }

    @Test func recoveryExhaustionSurfaces() async throws {
        var rejecting = MockTargetFaults()
        rejecting.rejectLoginStatus = (class: 3, detail: 1)   // any rejection: Connect Invalid Host
        let fleet = NVMeFleet(faultScripts: [rejecting])
        let controller = NVMeController(config: testControllerConfig(),
                                        policy: testPolicy(recoveryAttempts: 2)) {
            await fleet.makeTransport()
        }
        await #expect(throws: (any Error).self) { try await controller.activate() }
        await fleet.shutdown()
    }

    @Test func keepAliveDetectsAMutePeerAndTheControllerRecovers() async throws {
        // The first admin connection swallows Keep Alive: only the keepalive
        // can notice the peer is dead, and it must take the I/O queue with it.
        var mute = MockTargetFaults()
        mute.swallowNops = true
        let fleet = NVMeFleet(faultScripts: [mute, Self.healthy, Self.healthy])
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(nopInterval: .milliseconds(50)))

        // Polled with a real admin command each time (a cached geometry read
        // would never touch the wire): it succeeds against the mute
        // controller until the keepalive kills the pair, and the exit
        // condition is the recovered pair, not a successful command.
        let deadline = ContinuousClock.now + .seconds(10)
        var recovered: [UInt32]?
        while ContinuousClock.now < deadline {
            let attempt = try? await controller.activeNamespaces()
            if await fleet.connectionsServed >= 4 {
                recovered = attempt
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await fleet.connectionsServed >= 4, "the keepalive never noticed the mute peer within 10s")
        #expect(recovered == [1], "no command completed after recovery")
        await fleet.shutdown()
    }

    @Test func logoutStopsRecovery() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(fleet: fleet)
        try await controller.logout()
        await #expect(throws: SessionError.self) { _ = try await controller.activeNamespaces() }
        #expect(await fleet.connectionsServed == 2)
        await fleet.shutdown()
    }

    /// The user detaches while recovery is bringing a pair up. Before the
    /// fix that bring-up finished after `logout` returned and left two
    /// connections and a keepalive nothing would ever stop.
    @Test func logoutDuringRecoveryLeavesNoController() async throws {
        let fleet = NVMeFleet()
        let gate = ConnectGate()
        let controller = NVMeController(config: testControllerConfig(), policy: testPolicy()) {
            if await fleet.connectionsServed >= 2 { await gate.pass() }
            return await fleet.makeTransport()
        }
        try await controller.activate()
        await fleet.shutdown()

        let io = Task { try await controller.activeNamespaces() }
        #expect(await eventually { await gate.isHeld })
        let logout = Task { try await controller.logout() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        try await logout.value

        await #expect(throws: (any Error).self) { _ = try await io.value }
        #expect(await eventually {
            let ended = await fleet.connectionsEnded
            return await ended == fleet.connectionsServed
        }, "a connection recovery opened after logout is still being served")
        await fleet.shutdown()
    }

    @Test func recoveryOntoABrokenTargetSurfacesAnError() async throws {
        var rejecting = MockTargetFaults()
        rejecting.rejectLoginStatus = (class: 3, detail: 1)
        let fleet = NVMeFleet(faultScripts: [Self.healthy, Self.healthy, rejecting])
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 1, recoveryAttempts: 2))
        await fleet.shutdown()
        await #expect(throws: (any Error).self) { _ = try await controller.activeNamespaces() }
        await fleet.shutdown()
    }

    /// The 2026-11-09 failure, daemon side: a NAS holding I/O behind a slow
    /// flush while its admin queue still answers. The attempt times out, the
    /// controller reconnects and resends, and the resend lands once the hold
    /// ends. The extension saw none of that, because it gave up at the same
    /// 30 s; it now outwaits one retry (`DaemonStore.defaultTimeout`).
    @Test func aWriteHeldPastTheTaskTimeoutLandsOnTheResend() async throws {
        let faultBox = FaultBox()
        let fleet = NVMeFleet(disk: RAMDisk(blockSize: 512, capacityBlocks: 8192))
        var policy = testPolicy()
        policy.taskTimeout = .milliseconds(300)
        let controller = NVMeController(config: testControllerConfig(), policy: policy) {
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let subsystem = await fleet.subsystem
            Task { await subsystem.serve(targetSide, faultBox: faultBox) }
            return initiatorSide
        }
        try await controller.activate()
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        _ = try await device.readCapacity()

        faultBox.mutate { $0.holdIOUntil = .now + .milliseconds(500) }
        let payload = Data(repeating: 0x5A, count: 4096)
        let started = ContinuousClock.now
        try await device.write(offset: 0, data: payload)
        let took = ContinuousClock.now - started
        #expect(took >= .milliseconds(450), "the write was not held")
        #expect(took < .seconds(5))
        #expect(try await device.read(offset: 0, length: payload.count) == payload)
        await fleet.shutdown()
    }
}
