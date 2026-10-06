//
//  PerRequestFlushTests.swift
//
//  `WriteDurability.flushPerRequest`: a request larger than one command goes
//  out without FUA, then one flush, and is acknowledged only after the flush.
//  The claim is that this is exactly as durable at acknowledgement as FUA on
//  every command, so every test here ends with a target power cut.
//
//  The two recovery scenarios from GitHub issue #2 are the reason this file
//  exists: the target loses its cache after acknowledging the writes and
//  either reconnects or reports a reset, and the flush that follows succeeds
//  having committed nothing. Each one carries its negative arm — the same
//  fault under a plain write and flush, losing the data — because a replay
//  test that passes when the fault never bites proves nothing.
//

import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIDaemon
@testable import iSCSIKit

private let blockSize = 4096
private let capacityBlocks: UInt64 = 4096
/// Two blocks per command, so `payload()`'s eight blocks are four commands.
private let maxTransfer = 2 * blockSize

private func payload(_ seed: UInt8, blocks: Int = 8) -> Data {
    Data((0 ..< blocks * blockSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

@Suite("Integration: flush per request (iSCSI)", .timeLimit(.minutes(1)))
struct PerRequestFlushISCSITests {

    private func makeDevice(
        disk: RAMDisk,
        configs: [MockTargetConfig] = [MockTargetConfig()],
        durability: WriteDurability = .flushPerRequest
    ) async throws -> (ISCSIBlockDevice, TargetFleet) {
        let configs = configs.map { config -> MockTargetConfig in
            var config = config
            config.maxRecvDataSegmentLength = 262_144
            return config
        }
        let fleet = TargetFleet(disk: disk, configs: configs)
        let session = ISCSISession(login: standardLogin(), policy: testPolicy()) {
            await fleet.makeTransport()
        }
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: 0,
                                      maxTransferBytes: maxTransfer, durability: durability)
        return (device, fleet)
    }

    @Test("a multi-command request is written cached, then flushed once")
    func multiCommandRequestFlushesOnce() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk)
        let data = payload(1)

        try await device.write(offset: 0, data: data)
        #expect(await disk.cachedWrites == 4)
        #expect(await disk.fuaWrites == 0)
        #expect(await disk.flushCount == 1)
        // Acknowledged means committed: nothing left for a power cut to take.
        #expect(await disk.dirtyBlocks == 0)
        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test("a single-command request carries FUA and no flush")
    func singleCommandRequestUsesFUA() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk)
        let data = payload(2, blocks: 2)

        try await device.write(offset: 0, data: data)
        #expect(await disk.fuaWrites == 1)
        #expect(await disk.cachedWrites == 0)
        #expect(await disk.flushCount == 0)
        #expect(await disk.crash() == 0)
        await fleet.shutdown()
    }

    @Test("a failed flush fails the request, though every write succeeded")
    func failedFlushFailsTheRequest() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var config = MockTargetConfig()
        config.faults.failSynchronizeCache = true
        let (device, fleet) = try await makeDevice(disk: disk, configs: [config])

        await #expect(throws: BlockDeviceError.self) {
            try await device.write(offset: 0, data: payload(3))
        }
        #expect(await disk.cachedWrites == 4)
        await fleet.shutdown()
    }

    @Test("cache lost across a reconnect before the flush: replayed with FUA")
    func cacheLostAcrossReconnectIsReplayed() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var losing = MockTargetConfig()
        losing.faults.loseCacheAtSynchronizeCache = .dropConnection
        let (device, fleet) = try await makeDevice(disk: disk, configs: [losing, MockTargetConfig()])
        let data = payload(4)

        try await device.write(offset: 0, data: data)
        #expect(await fleet.connectionsServed == 2)
        #expect(await disk.blocksLostToCrash == 8)    // the fault did bite
        #expect(await disk.fuaWrites == 4)            // ...and the replay ran
        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test("negative control: the same reconnect under a plain flush loses the data")
    func cacheLostAcrossReconnectWithoutReplayLosesData() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var losing = MockTargetConfig()
        losing.faults.loseCacheAtSynchronizeCache = .dropConnection
        let (device, fleet) = try await makeDevice(disk: disk, configs: [losing, MockTargetConfig()],
                                                   durability: .cached)
        let data = payload(5)

        try await device.write(offset: 0, data: data)
        // Recovers onto the new connection and succeeds there — having
        // committed nothing, because the cache it should have committed is gone.
        try await device.flush()
        #expect(await fleet.connectionsServed == 2)
        #expect(try await device.read(offset: 0, length: data.count) == Data(count: data.count))
        await fleet.shutdown()
    }

    @Test("cache lost to a reset reported as UNIT ATTENTION: replayed with FUA")
    func cacheLostToResetIsReplayed() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var config = MockTargetConfig()
        config.faults.loseCacheAtSynchronizeCache = .unitAttention
        let (device, fleet) = try await makeDevice(disk: disk, configs: [config])
        let data = payload(6)

        try await device.write(offset: 0, data: data)
        // One connection throughout: only the absorbed UA can have told us.
        #expect(await fleet.connectionsServed == 1)
        #expect(await disk.blocksLostToCrash == 8)
        #expect(await disk.fuaWrites == 4)
        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test("negative control: the same reset under a plain flush loses the data")
    func cacheLostToResetWithoutReplayLosesData() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var config = MockTargetConfig()
        config.faults.loseCacheAtSynchronizeCache = .unitAttention
        let (device, fleet) = try await makeDevice(disk: disk, configs: [config], durability: .cached)
        let data = payload(7)

        try await device.write(offset: 0, data: data)
        try await device.flush()   // UA absorbed, retried, GOOD
        #expect(try await device.read(offset: 0, length: data.count) == Data(count: data.count))
        await fleet.shutdown()
    }

    @Test("a target without SYNCHRONIZE CACHE(16) is flushed with the 10-byte form")
    func syncCache16RejectionFallsBack() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var config = MockTargetConfig()
        config.faults.rejectSynchronizeCache16 = true
        let (device, fleet) = try await makeDevice(disk: disk, configs: [config])

        try await device.write(offset: 0, data: payload(8))
        try await device.write(offset: UInt64(8 * blockSize), data: payload(9))
        // Rejected (16)s never reach the disk, so each count is a (10).
        #expect(await disk.flushCount == 2)
        #expect(await disk.crash() == 0)
        await fleet.shutdown()
    }

    @Test("WCE=0: the flush is skipped, since it cannot matter")
    func writeCacheDisabledSkipsTheFlush() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var config = MockTargetConfig()
        config.writeCacheEnabled = false
        let (device, fleet) = try await makeDevice(disk: disk, configs: [config])

        try await device.write(offset: 0, data: payload(10))
        try await device.write(offset: UInt64(8 * blockSize), data: payload(11))
        #expect(await disk.cachedWrites == 8)
        #expect(await disk.fuaWrites == 0)
        #expect(await disk.flushCount == 0)
        await fleet.shutdown()
    }
}

@Suite("Integration: flush per request (NVMe/TCP)", .timeLimit(.minutes(1)))
struct PerRequestFlushNVMeTests {

    private func makeDevice(
        disk: RAMDisk,
        config: MockNVMeConfig = MockNVMeConfig(),
        faultScripts: [MockTargetFaults]? = nil,
        durability: WriteDurability = .flushPerRequest
    ) async throws -> (NVMeBlockDevice, NVMeFleet) {
        let fleet = NVMeFleet(config: config, disk: disk, faultScripts: faultScripts)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1,
                                     maxTransferBytes: maxTransfer, durability: durability)
        return (device, fleet)
    }

    /// Admin queue clean, I/O queue loses the cache at Flush, every later
    /// connection clean.
    private var losingIOQueue: [MockTargetFaults] {
        var losing = MockTargetFaults()
        losing.loseCacheAtSynchronizeCache = .dropConnection
        return [MockTargetFaults(), losing, MockTargetFaults()]
    }

    @Test("a multi-command request is written cached, then flushed once")
    func multiCommandRequestFlushesOnce() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk)
        let data = payload(21)

        try await device.write(offset: 0, data: data)
        #expect(await disk.cachedWrites == 4)
        #expect(await disk.fuaWrites == 0)
        #expect(await disk.flushCount == 1)
        #expect(await disk.dirtyBlocks == 0)
        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test("a single-command request carries FUA and no flush")
    func singleCommandRequestUsesFUA() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk)

        try await device.write(offset: 0, data: payload(22, blocks: 2))
        #expect(await disk.fuaWrites == 1)
        #expect(await disk.flushCount == 0)
        #expect(await disk.crash() == 0)
        await fleet.shutdown()
    }

    @Test("a failed Flush fails the request")
    func failedFlushFailsTheRequest() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var failing = MockTargetFaults()
        failing.failSynchronizeCache = true
        let (device, fleet) = try await makeDevice(disk: disk, faultScripts: [failing])

        await #expect(throws: BlockDeviceError.self) {
            try await device.write(offset: 0, data: payload(23))
        }
        await fleet.shutdown()
    }

    @Test("cache lost across a reconnect before the Flush: replayed with FUA")
    func cacheLostAcrossReconnectIsReplayed() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, faultScripts: losingIOQueue)
        let data = payload(24)

        try await device.write(offset: 0, data: data)
        #expect(await fleet.connectionsServed == 4)   // two queue pairs
        #expect(await disk.blocksLostToCrash == 8)
        #expect(await disk.fuaWrites == 4)
        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test("negative control: the same reconnect under a plain Flush loses the data")
    func cacheLostAcrossReconnectWithoutReplayLosesData() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, faultScripts: losingIOQueue,
                                                   durability: .cached)
        let data = payload(25)

        try await device.write(offset: 0, data: data)
        try await device.flush()
        #expect(await fleet.connectionsServed == 4)
        #expect(try await device.read(offset: 0, length: data.count) == Data(count: data.count))
        await fleet.shutdown()
    }

    @Test("VWC=0: the Flush is skipped, since it cannot matter")
    func noVolatileCacheSkipsTheFlush() async throws {
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        var config = MockNVMeConfig()
        config.volatileWriteCache = false
        let (device, fleet) = try await makeDevice(disk: disk, config: config)

        try await device.write(offset: 0, data: payload(26))
        #expect(await disk.cachedWrites == 4)
        #expect(await disk.flushCount == 0)
        await fleet.shutdown()
    }
}

@Suite("Integration: flush per request (daemon)", .timeLimit(.minutes(1)))
struct PerRequestFlushDaemonTests {

    @Test("the policy reaches the wire, and detach adds no flush")
    func daemonSessionFlushesPerRequest() async throws {
        let disk = RAMDisk()
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.2026-08.com.example:daemon") { _, _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: MockTargetConfig(), disk: disk, transport: targetSide)
            harnesses.add(Task { await target.run() })
            return initiatorSide
        }
        defer { harnesses.cancelAll() }

        let handle = try await core.login(host: "nas", port: 3260,
                                          targetIQN: "iqn.2026-08.test.example:disk0", lun: 0,
                                          flushPolicy: .flushPerRequest)
        // 1 MiB against the daemon's 256 KiB commands: four of them.
        try await core.write(handle, offset: 0, data: Data(repeating: 0x5A, count: 1 << 20))
        #expect(await disk.cachedWrites == 4)
        #expect(await disk.flushCount == 1)
        #expect(await disk.dirtyBlocks == 0)

        let details = await core.sessionDetails()
        #expect(details.first?.writeThrough == true)

        try await core.logout(handle)
        #expect(await disk.flushCount == 1)
    }
}
