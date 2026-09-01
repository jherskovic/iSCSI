import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// The iSCSI crash-consistency proof, over NVMe/TCP: FUA on Write (CDW12 bit
/// 30) and the Flush command must reach stable media the way the SCSI FUA
/// bit and SYNCHRONIZE CACHE do, and cached writes must be lost the same
/// way. Both arms are asserted for the same reason as in
/// `CrashConsistencyTests`: a positive result alone cannot show the
/// experiment could have failed.
@Suite("Integration: NVMe/TCP crash consistency (volatile controller cache)", .timeLimit(.minutes(1)))
struct NVMeCrashConsistencyTests {
    static let blockSize = 4096
    static let capacityBlocks: UInt64 = 4096

    private func makeDevice(disk: RAMDisk, writeThrough: Bool) async throws -> (NVMeBlockDevice, NVMeFleet) {
        let fleet = NVMeFleet(disk: disk)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1,
                                     maxTransferBytes: 1 << 20, writeThrough: writeThrough)
        return (device, fleet)
    }

    private static func payload(_ seed: UInt8, blocks: Int = 8) -> Data {
        Data((0 ..< blocks * blockSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    @Test func fuaWritesSurviveTargetPowerLoss() async throws {
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, writeThrough: true)
        let data = Self.payload(1)

        try await device.write(offset: 0, data: data)
        #expect(await disk.dirtyBlocks == 0)
        #expect(await disk.fuaWrites > 0)
        #expect(await disk.cachedWrites == 0)

        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test func cachedWritesAreLostOnTargetPowerLoss() async throws {
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, writeThrough: false)
        let data = Self.payload(2)

        try await device.write(offset: 0, data: data)
        #expect(await disk.dirtyBlocks == data.count / Self.blockSize)
        #expect(await disk.fuaWrites == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)

        let lost = await disk.crash()
        #expect(lost == data.count / Self.blockSize)
        let after = try await device.read(offset: 0, length: data.count)
        #expect(after != data)
        #expect(after == Data(count: data.count))
        await fleet.shutdown()
    }

    @Test func flushMakesCachedWritesDurable() async throws {
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, writeThrough: false)
        let data = Self.payload(3)

        try await device.write(offset: 0, data: data)
        try await device.flush()
        #expect(await disk.dirtyBlocks == 0)

        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test func crashLosesOnlyTheUnflushedTail() async throws {
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, writeThrough: false)
        let committed = Self.payload(4)
        let tail = Self.payload(5)

        try await device.write(offset: 0, data: committed)
        try await device.flush()
        try await device.write(offset: UInt64(committed.count), data: tail)

        #expect(await disk.crash() == tail.count / Self.blockSize)
        #expect(try await device.read(offset: 0, length: committed.count) == committed)
        let tailAfter = try await device.read(offset: UInt64(committed.count), length: tail.count)
        #expect(tailAfter == Data(count: tail.count))
        await fleet.shutdown()
    }

    @Test func fuaWriteSupersedesAStaleCachedCopy() async throws {
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        let fleet = NVMeFleet(disk: disk)
        let controller = try await activatedController(fleet: fleet)
        let cached = NVMeBlockDevice(controller: controller, nsid: 1, writeThrough: false)
        let durable = NVMeBlockDevice(controller: controller, nsid: 1, writeThrough: true)
        let old = Self.payload(6, blocks: 1)
        let new = Self.payload(7, blocks: 1)

        try await cached.write(offset: 0, data: old)
        try await durable.write(offset: 0, data: new)
        #expect(await disk.dirtyBlocks == 0)

        try await cached.flush()
        #expect(try await durable.read(offset: 0, length: new.count) == new)
        await fleet.shutdown()
    }
}
