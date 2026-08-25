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

    /// A megabyte of unsolicited data, read back byte for byte: a
    /// `bufferOffset` off-by-one in the unsolicited tail would corrupt every
    /// megabyte written while benchmarks report the same rate.
    ///
    /// Two shapes, because they exercise different code:
    ///   - 1 MiB command: entirely unsolicited, no R2T at all.
    ///   - 2 MiB command: 1 MiB unsolicited, then R2T for the remainder.
    @Test(arguments: [1 << 20, 2 << 20])
    func megabyteFirstBurstRoundTrips(_ maxTransfer: Int) async throws {
        var config = MockTargetConfig()
        config.firstBurstLength = 1 << 20
        config.maxBurstLength = 1 << 20
        // Big enough that most of the first burst still arrives as unsolicited
        // Data-Out rather than immediate data.
        config.maxRecvDataSegmentLength = 262_144
        let fleet = TargetFleet(
            disk: RAMDisk(blockSize: 4096, capacityBlocks: 2048), configs: [config]
        )
        let session = ISCSISession(login: standardLogin(), policy: testPolicy()) {
            await fleet.makeTransport()
        }
        let login = try await session.activate()
        // Every other test here folds FirstBurst to 64 KiB; assert this one
        // negotiated the shape it claims to exercise.
        #expect(login.parameters.firstBurstLength == 1 << 20)
        #expect(login.parameters.initialR2T == false)

        let device = ISCSIBlockDevice(session: session, lun: 0, maxTransferBytes: maxTransfer)
        let payload = Data((0 ..< (4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try await device.write(offset: 0, data: payload)
        #expect(try await device.read(offset: 0, length: payload.count) == payload)
        await fleet.shutdown()
    }

    /// Same, at the mock target's small default MRDSL: 8 KiB of immediate data
    /// and the rest of the megabyte as an unsolicited tail — the most Data-Out
    /// PDUs per command of any configuration here.
    @Test func megabyteFirstBurstWithTinyImmediateSegment() async throws {
        var config = MockTargetConfig()
        config.firstBurstLength = 1 << 20
        config.maxBurstLength = 1 << 20
        let fleet = TargetFleet(
            disk: RAMDisk(blockSize: 4096, capacityBlocks: 1024), configs: [config]
        )
        let session = ISCSISession(login: standardLogin(), policy: testPolicy()) {
            await fleet.makeTransport()
        }
        let login = try await session.activate()
        #expect(login.parameters.firstBurstLength == 1 << 20)
        #expect(login.parameters.targetMaxRecvDataSegmentLength == 8192)

        let device = ISCSIBlockDevice(session: session, lun: 0, maxTransferBytes: 1 << 20)
        let payload = Data((0 ..< (2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) })
        try await device.write(offset: 0, data: payload)
        #expect(try await device.read(offset: 0, length: payload.count) == payload)
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

extension BlockDeviceTests {
    /// Chunks must be reassembled in the order they were requested.
    ///
    /// `largeTransferChunks` above cannot check this. Its payload is
    /// `(i * 7) & 0xFF`, which repeats every 256 bytes, and its chunks are 8192
    /// bytes — a whole number of periods. Swap any two chunks and the result is
    /// byte-identical, so it would pass against a device that reassembled them
    /// in arrival order.
    ///
    /// That was harmless while the chunks of one read were issued one after
    /// another. They are now issued together, so they complete in whatever
    /// order the target answers, and correctness depends entirely on
    /// reassembling by index. This makes each chunk's contents unique to its
    /// position, so any transposition changes the bytes.
    @Test func concurrentChunksAreReassembledInOrder() async throws {
        let blockSize = 512
        let chunkBytes = 8192
        let totalBytes = 262_144
        let (device, fleet) = try await makeDevice(
            blockSize: blockSize, capacityBlocks: 2048, maxTransferBytes: chunkBytes
        )

        // Byte i carries its own chunk index, so no two chunks hold the same
        // bytes and a swap is visible.
        var payload = Data(capacity: totalBytes)
        for i in 0 ..< totalBytes {
            let chunk = UInt8((i / chunkBytes) & 0xFF)
            payload.append(chunk ^ UInt8(i & 0xFF))
        }

        try await device.write(offset: 0, data: payload)
        let readback = try await device.read(offset: 0, length: totalBytes)
        #expect(readback == payload)

        // Where, if it did go wrong. A bare inequality on 256 KiB says nothing
        // about which chunk moved.
        if readback != payload {
            let firstBad = zip(readback, payload).enumerated()
                .first { $0.element.0 != $0.element.1 }?.offset ?? -1
            Issue.record("first mismatch at byte \(firstBad), chunk \(firstBad / chunkBytes)")
        }
        await fleet.shutdown()
    }
}
