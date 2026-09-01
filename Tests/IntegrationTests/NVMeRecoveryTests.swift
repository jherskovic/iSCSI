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
}
