import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// A controller that breaks the protocol must produce an error, never bad
/// data and never a hang — the `HostileTargetTests` twin.
@Suite("Integration: hostile NVMe/TCP controller", .timeLimit(.minutes(1)))
struct NVMeHostileTests {
    private func hostileFleet(_ tune: (inout MockNVMeHostility) -> Void) -> NVMeFleet {
        var config = MockNVMeConfig()
        tune(&config.hostility)
        return NVMeFleet(config: config)
    }

    @Test func aForeignPDUFormatVersionIsRefused() async throws {
        let fleet = hostileFleet { $0.icrespPFV = 1 }
        let controller = NVMeController(config: testControllerConfig(),
                                        policy: testPolicy(recoveryAttempts: 1)) { await fleet.makeTransport() }
        await #expect(throws: ConnectionError.self) { try await controller.activate() }
        await fleet.shutdown()
    }

    @Test func aDemandForAlignedDataIsRefused() async throws {
        let fleet = hostileFleet { $0.icrespCPDA = 3 }
        let controller = NVMeController(config: testControllerConfig(),
                                        policy: testPolicy(recoveryAttempts: 1)) { await fleet.makeTransport() }
        await #expect(throws: ConnectionError.self) { try await controller.activate() }
        await fleet.shutdown()
    }

    @Test func aTerminationRequestFailsTheCommandNotTheProcess() async throws {
        let fleet = hostileFleet { $0.terminateOnFirstIOCommand = true }
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        await fleet.shutdown()
    }

    @Test func aCompletionForAnUnknownCIDIsAProtocolError() async throws {
        let fleet = hostileFleet { $0.completeUnknownCID = true }
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        await fleet.shutdown()
    }

    @Test func c2hDataPastTheReadBufferIsRefused() async throws {
        let fleet = hostileFleet { $0.c2hDataOverrun = true }
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        await fleet.shutdown()
    }

    @Test func anR2TPastTheWriteIsRefused() async throws {
        var config = MockNVMeConfig()
        config.inCapsuleDataBytes = 0
        config.hostility.r2tOverrun = true
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            try await device.write(offset: 0, data: Data(count: 4096))
        }
        await fleet.shutdown()
    }

    @Test func aCorruptedPayloadIsCaughtByTheDataDigest() async throws {
        var config = MockNVMeConfig()
        config.faults.corruptDataInPayload = true
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1)) { $0.requestDigests = true }
        #expect(await controller.digests.data)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        try await device.write(offset: 0, data: Data(repeating: 0x42, count: 4096))
        // Never bad bytes: the corruption surfaces as an error.
        await #expect(throws: ConnectionError.self) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        await fleet.shutdown()
    }

    @Test func aCorruptedPayloadPassesSilentlyWithoutDigests() async throws {
        // The negative control for the test above: with no data digest the
        // wire cannot tell, which is why the daemon offers digests.
        var config = MockNVMeConfig()
        config.faults.corruptDataInPayload = true
        config.acceptDigests = false
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let payload = Data(repeating: 0x42, count: 4096)
        try await device.write(offset: 0, data: payload)
        #expect(try await device.read(offset: 0, length: 4096) != payload)
        await fleet.shutdown()
    }

    @Test func aFailedCommandStatusIsSurfacedWithItsOpcode() async throws {
        var config = MockNVMeConfig()
        config.faults.checkConditionAll = true
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: BlockDeviceError.nvmeStatus(sct: 0, sc: 0x06, opcode: 0x02)) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        await fleet.shutdown()
    }
}
