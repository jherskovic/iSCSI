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

    @Test func aMAXH2CDATAThatIsNotAMultipleOfFourIsRefused() async throws {
        var config = MockNVMeConfig()
        config.maxH2CData = 4097
        let fleet = NVMeFleet(config: config)
        let controller = NVMeController(config: testControllerConfig(),
                                        policy: testPolicy(recoveryAttempts: 1)) { await fleet.makeTransport() }
        await #expect(throws: ConnectionError.self) { try await controller.activate() }
        await fleet.shutdown()
    }

    @Test func aTerminationRequestFailsTheCommandNotTheProcess() async throws {
        let fleet = hostileFleet { $0.terminateOnFirstIOCommand = true }
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1)) { $0.requestDigests = true }
        #expect(await controller.digests.header)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        // The C2HTermReq is decoded, not rejected as a framing error: the
        // controller's FES reaches the error text.
        await #expect {
            _ = try await device.read(offset: 0, length: 4096)
        } throws: { error in
            guard case ConnectionError.protocolError(let reason) = error else { return false }
            return reason.contains("FES 0x2")
        }
        await fleet.shutdown()
    }

    // NVMe/TCP 1.1 §3.5: on a fatal transport error the host sends an
    // H2CTermReq naming the error before it closes the connection.
    @Test func aFatalErrorSendsAnH2CTermReqBeforeClosing() async throws {
        let fleet = hostileFleet { $0.completeUnknownCID = true }
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        #expect(await eventually { await fleet.subsystem.h2cTermReqsReceived.count == 1 })
        #expect(await fleet.subsystem.h2cTermReqsReceived == [.invalidPDUHeader])
        await fleet.shutdown()
    }

    /// §3.3.2.2: the first R2T of a command starts at offset 0 and later
    /// ones follow on; a gap is a sequence error, not a partial write.
    @Test func aNonContiguousR2TIsAProtocolError() async throws {
        var config = MockNVMeConfig()
        config.inCapsuleDataBytes = 0
        config.hostility.r2tSkipsFirstBlock = true
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            try await device.write(offset: 0, data: Data(count: 8192))
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

    // NVMe/TCP 1.1 §3.3.2.1: C2HData PDUs are contiguous from offset 0,
    // SUCCESS implies LAST_PDU, and nothing follows LAST_PDU. Each of these
    // is a fatal transport error, never a read that completes with a hole.
    @Test func nonContiguousC2HDataIsAProtocolError() async throws {
        var config = MockNVMeConfig()
        config.c2hChunkBytes = 2048
        config.hostility.c2hDataRepeatsOffsetZero = true
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        await fleet.shutdown()
    }

    @Test func successWithoutLastPDUIsAProtocolError() async throws {
        let fleet = hostileFleet { $0.successWithoutLast = true }
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 0, recoveryAttempts: 1))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        await #expect(throws: ConnectionError.self) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        await fleet.shutdown()
    }

    @Test func c2hDataAfterLastPDUIsAProtocolError() async throws {
        var config = MockNVMeConfig()
        config.c2hChunkBytes = 2048
        config.hostility.lastPDUTooEarly = true
        let fleet = NVMeFleet(config: config)
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
        // Never bad bytes: the corruption surfaces as an error — a Transient
        // Transport Error on the command (NVMe/TCP 1.1 §3.5), not a torn-down
        // connection: the queue pair is still usable afterwards.
        await #expect(throws: BlockDeviceError.nvmeStatus(sct: 0, sc: 0x22, opcode: 0x02)) {
            _ = try await device.read(offset: 0, length: 4096)
        }
        #expect(await controller.recoveryCount == 0)
        try await device.flush()
        #expect(await fleet.connectionsServed == 2)
        await fleet.shutdown()
    }

    @Test func aOneOffDigestErrorIsRetriedOnTheSameConnection() async throws {
        let fleet = hostileFleet { $0.corruptFirstReadOnly = true }
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(retries: 2, recoveryAttempts: 1)) { $0.requestDigests = true }
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let payload = Data(repeating: 0x42, count: 4096)
        try await device.write(offset: 0, data: payload)
        #expect(try await device.read(offset: 0, length: 4096) == payload)
        #expect(await controller.recoveryCount == 0)
        #expect(await fleet.connectionsServed == 2)
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
