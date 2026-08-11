import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

@Suite("Integration: block device over iSCSI", .timeLimit(.minutes(1)))
struct BlockDeviceTests {
    func makeDevice(
        blockSize: Int = 512,
        capacityBlocks: UInt64 = 8192,
        maxTransferBytes: Int = 1 << 20,
        targetTune: (inout MockTargetConfig) -> Void = { _ in }
    ) async throws -> (ISCSIBlockDevice, TargetFleet) {
        var config = MockTargetConfig()
        targetTune(&config)
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: capacityBlocks)
        let fleet = TargetFleet(disk: disk, configs: [config])
        let session = ISCSISession(
            login: standardLogin(),
            policy: testPolicy(),
            transportFactory: { await fleet.makeTransport() }
        )
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: 0, maxTransferBytes: maxTransferBytes)
        return (device, fleet)
    }

    @Test func readCapacityGeometry() async throws {
        let (device, fleet) = try await makeDevice(blockSize: 4096, capacityBlocks: 1000)
        #expect(await device.blockSize == 4096)
        #expect(await device.blockCount == 1000)
        await fleet.shutdown()
    }

    @Test func writeReadRoundTrip() async throws {
        let (device, fleet) = try await makeDevice()
        let payload = Data((0 ..< 4096).map { UInt8($0 & 0xFF) })
        try await device.write(offset: 2048, data: payload) // block 4
        let readback = try await device.read(offset: 2048, length: 4096)
        #expect(readback == payload)
        await fleet.shutdown()
    }

    @Test func largeTransferChunks() async throws {
        // maxTransferBytes forces the 256 KiB write/read to split into many
        // SCSI commands; the device must stitch them back seamlessly.
        let (device, fleet) = try await makeDevice(
            blockSize: 512, capacityBlocks: 2048, maxTransferBytes: 8192
        )
        let payload = Data((0 ..< 262_144).map { UInt8(($0 &* 7) & 0xFF) })
        try await device.write(offset: 0, data: payload)
        let readback = try await device.read(offset: 0, length: 262_144)
        #expect(readback == payload)
        await fleet.shutdown()
    }

    @Test func flushIssuesSynchronizeCache() async throws {
        let disk = RAMDisk()
        let fleet = TargetFleet(disk: disk, configs: [MockTargetConfig()])
        let session = ISCSISession(login: standardLogin(), policy: testPolicy()) {
            await fleet.makeTransport()
        }
        try await session.activate()
        let device = ISCSIBlockDevice(session: session)
        try await device.flush()
        try await device.flush()
        #expect(await disk.flushCount == 2)
        await fleet.shutdown()
    }

    @Test func misalignedAccessRejected() async throws {
        let (device, fleet) = try await makeDevice(blockSize: 512)
        await #expect(throws: BlockDeviceError.self) {
            _ = try await device.read(offset: 100, length: 512) // offset not block-aligned
        }
        await #expect(throws: BlockDeviceError.self) {
            _ = try await device.read(offset: 0, length: 500) // length not a multiple
        }
        await fleet.shutdown()
    }

    @Test func outOfRangeRejected() async throws {
        let (device, fleet) = try await makeDevice(blockSize: 512, capacityBlocks: 16)
        await #expect(throws: BlockDeviceError.self) {
            _ = try await device.read(offset: 512 * 15, length: 512 * 4) // runs past capacity
        }
        await fleet.shutdown()
    }

    @Test func scsiErrorSurfaced() async throws {
        let (device, fleet) = try await makeDevice { $0.faults.checkConditionAll = true }
        do {
            _ = try await device.read(offset: 0, length: 512)
            Issue.record("expected SCSI error")
        } catch let BlockDeviceError.scsiError(status, sense) {
            #expect(status == 0x02)
            #expect(sense?.key == 0x05)
        }
        await fleet.shutdown()
    }

    @Test func survivesTargetDropMidWorkload() async throws {
        // Block device on top of a recovering session: a target drop between
        // chunks must be transparent.
        var dropping = MockTargetConfig()
        dropping.faults.dropAfterSentPDUs = 6
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 4096)
        let fleet = TargetFleet(disk: disk, configs: [dropping, MockTargetConfig()])
        let session = ISCSISession(login: standardLogin(), policy: testPolicy(retries: 4)) {
            await fleet.makeTransport()
        }
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, maxTransferBytes: 4096)

        let payload = Data((0 ..< 65536).map { UInt8(($0 &* 3) & 0xFF) })
        try await device.write(offset: 0, data: payload)
        let readback = try await device.read(offset: 0, length: 65536)
        #expect(readback == payload)
        await fleet.shutdown()
    }
}
