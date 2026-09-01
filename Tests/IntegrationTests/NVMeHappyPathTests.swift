import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

@Suite("Integration: NVMe/TCP happy paths", .timeLimit(.minutes(1)))
struct NVMeHappyPathTests {
    @Test func connectIdentifyAndLogout() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(fleet: fleet)
        let identity = try #require(await controller.identity)
        #expect(identity.subsystemNQN == MockNVMeConfig().subsystemNQN)
        #expect(identity.model == "MockNVMe")
        #expect(identity.volatileWriteCachePresent)
        let pairs = await controller.displayPairs
        #expect(pairs["MDTS"] != nil && pairs["CNTLID"] != nil && pairs["KATO"] != nil)
        #expect(await fleet.connectionsServed == 2)   // admin queue + one I/O queue
        try await controller.logout()
        await #expect(throws: SessionError.self) { _ = try await controller.activeNamespaces() }
        #expect(await fleet.connectionsServed == 2)   // no sneaky reconnect after logout
        await fleet.shutdown()
    }

    @Test func activeNamespacesAndGeometry() async throws {
        let disk = RAMDisk(blockSize: 4096, capacityBlocks: 1000)
        let fleet = NVMeFleet(disk: disk)
        let controller = try await activatedController(fleet: fleet)
        #expect(try await controller.activeNamespaces() == [1])
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let geometry = try await device.readCapacity()
        #expect(geometry.blockSize == 4096 && geometry.blockCount == 1000)
        #expect(await device.blockSize == 4096)
        #expect(try await device.writeCacheEnabled() == true)
        await fleet.shutdown()
    }

    @Test func smallWriteGoesInCapsuleAndReadsBack() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let payload = Data((0 ..< 8192).map { UInt8($0 & 0xFF) })
        try await device.write(offset: 8192, data: payload)
        #expect(try await device.read(offset: 8192, length: 8192) == payload)
        #expect(await fleet.subsystem.r2tsSent == 0)       // fit in the capsule
        #expect(await fleet.subsystem.inCapsuleWrites == 1)
        await fleet.shutdown()
    }

    @Test func largeWriteIsSolicitedByR2TAndChunkedToMAXH2CDATA() async throws {
        var config = MockNVMeConfig()
        config.inCapsuleDataBytes = 0
        config.maxH2CData = 4096
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let payload = Data((0 ..< 65536).map { UInt8(($0 &* 31) & 0xFF) })
        try await device.write(offset: 0, data: payload)
        #expect(try await device.read(offset: 0, length: 65536) == payload)
        #expect(await fleet.subsystem.r2tsSent >= 1)
        #expect(await fleet.subsystem.h2cDataPDUsReceived >= 16)   // 64 KiB / 4 KiB
        await fleet.shutdown()
    }

    @Test func multiPDUReadIsReassembled() async throws {
        var config = MockNVMeConfig()
        config.c2hChunkBytes = 4096
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let payload = Data((0 ..< 65536).map { UInt8(($0 &* 7) & 0xFF) })
        try await device.write(offset: 0, data: payload)
        #expect(try await device.read(offset: 0, length: 65536) == payload)
        await fleet.shutdown()
    }

    @Test func successFlagOnC2HDataCompletesTheRead() async throws {
        var config = MockNVMeConfig()
        config.emitSuccessFlag = true
        let fleet = NVMeFleet(config: config)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let payload = Data(repeating: 0x5C, count: 4096)
        try await device.write(offset: 4096, data: payload)
        #expect(try await device.read(offset: 4096, length: 4096) == payload)
        await fleet.shutdown()
    }

    @Test func digestsAreNegotiatedAndUsed() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(fleet: fleet) { $0.requestDigests = true }
        #expect(await controller.digests == NVMeTCPDigests(header: true, data: true))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        let payload = Data(repeating: 0xD1, count: 16384)
        try await device.write(offset: 0, data: payload)
        #expect(try await device.read(offset: 0, length: 16384) == payload)
        await fleet.shutdown()

        var plain = MockNVMeConfig()
        plain.acceptDigests = false
        let plainFleet = NVMeFleet(config: plain)
        let plainController = try await activatedController(fleet: plainFleet) { $0.requestDigests = true }
        #expect(await plainController.digests == NVMeTCPDigests())
        await plainFleet.shutdown()
    }

    @Test func flushAndFUAReachTheDisk() async throws {
        let disk = RAMDisk(blockSize: 4096, capacityBlocks: 4096)
        let fleet = NVMeFleet(disk: disk)
        let controller = try await activatedController(fleet: fleet)
        let cached = NVMeBlockDevice(controller: controller, nsid: 1, writeThrough: false)
        let durable = NVMeBlockDevice(controller: controller, nsid: 1, writeThrough: true)

        try await cached.write(offset: 0, data: Data(repeating: 1, count: 4096))
        #expect(await disk.cachedWrites == 1)
        #expect(await disk.dirtyBlocks == 1)
        try await cached.flush()
        try await cached.flush()
        #expect(await disk.flushCount == 2)
        #expect(await disk.dirtyBlocks == 0)

        try await durable.write(offset: 4096, data: Data(repeating: 2, count: 4096))
        #expect(await disk.fuaWrites == 1)
        #expect(await disk.dirtyBlocks == 0)
        await fleet.shutdown()
    }

    @Test func keepAliveIsSentOnTheAdminQueue() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(
            fleet: fleet, policy: testPolicy(nopInterval: .milliseconds(20)))
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, await fleet.subsystem.keepAlivesReceived < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fleet.subsystem.keepAlivesReceived >= 2)
        try await controller.logout()
        await fleet.shutdown()
    }

    @Test func concurrentCommandsInterleave() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 8192)
        let fleet = NVMeFleet(disk: disk)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 8 {
                group.addTask {
                    let pattern = Data(repeating: UInt8(i), count: 512)
                    try await device.write(offset: UInt64(i * 4096), data: pattern)
                    #expect(try await device.read(offset: UInt64(i * 4096), length: 512) == pattern)
                }
            }
            try await group.waitForAll()
        }
        await fleet.shutdown()
    }

    @Test func discoveryLogPageListsSubsystems() async throws {
        var config = MockNVMeConfig()
        config.discoveryEntries = [
            (subnqn: "nqn.2011-06.com.truenas:disk0", traddr: "192.168.20.1", trsvcid: "4420"),
            (subnqn: "nqn.2011-06.com.truenas:disk1", traddr: "192.168.20.1", trsvcid: "4420"),
        ]
        let fleet = NVMeFleet(config: config)
        let found = try await NVMeDiscovery.getLogPage(transport: await fleet.makeTransport(), host: testHost)
        #expect(found.map(\.name) == ["nqn.2011-06.com.truenas:disk0", "nqn.2011-06.com.truenas:disk1"])
        #expect(found[0].addresses == ["192.168.20.1:4420"])
        await fleet.shutdown()
    }

    @Test func connectIsRefusedForAHostNotOnTheList() async throws {
        var config = MockNVMeConfig()
        config.allowedHosts = ["nqn.2014-08.org.nvmexpress:uuid:someone-else"]
        let fleet = NVMeFleet(config: config)
        let controller = NVMeController(config: testControllerConfig(), policy: testPolicy(recoveryAttempts: 1)) {
            await fleet.makeTransport()
        }
        await #expect(throws: BlockDeviceError.nvmeStatus(sct: 1, sc: 0x84, opcode: 0x7F)) {
            try await controller.activate()
        }
        await fleet.shutdown()
    }

    @Test func authenticationRequiredIsSurfaced() async throws {
        var config = MockNVMeConfig()
        config.requireAuth = true
        let fleet = NVMeFleet(config: config)
        let controller = NVMeController(config: testControllerConfig(), policy: testPolicy(recoveryAttempts: 1)) {
            await fleet.makeTransport()
        }
        await #expect(throws: BlockDeviceError.nvmeStatus(sct: 1, sc: 0x91, opcode: 0x7F)) {
            try await controller.activate()
        }
        await fleet.shutdown()
    }

    @Test func aMissingNamespaceIsInvalidNS() async throws {
        let fleet = NVMeFleet()
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 7)
        await #expect(throws: BlockDeviceError.nvmeStatus(sct: 0, sc: 0x0B, opcode: 0x06)) {
            _ = try await device.readCapacity()
        }
        await fleet.shutdown()
    }
}
