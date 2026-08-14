import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// Does `writeThrough` actually buy durability?
///
/// This could not be answered before. The real target's cache is real, but
/// cutting its power takes the test rig with it, and the earlier crash test cut
/// power to the *initiator* instead — where FUA and non-FUA writes behave
/// identically, so it could not discriminate. The simulated target's cache can
/// be made to evaporate on command while the harness survives to inspect the
/// damage.
///
/// Both arms are asserted on purpose. "FUA writes survived a crash" proves
/// nothing on its own: if nothing were ever cached, or if `crash()` did not
/// discard, the positive test would pass for the wrong reason. The negative arm
/// is what shows the experiment can fail.
@Suite("Integration: crash consistency (volatile target cache)", .timeLimit(.minutes(1)))
struct CrashConsistencyTests {
    static let blockSize = 4096
    static let capacityBlocks: UInt64 = 4096

    /// One session over a fleet that can serve several connections, so a test
    /// may drop and reconnect.
    private func makeDevice(
        disk: RAMDisk,
        writeThrough: Bool
    ) async throws -> (ISCSIBlockDevice, TargetFleet) {
        var config = MockTargetConfig()
        config.maxRecvDataSegmentLength = 262_144
        let fleet = TargetFleet(disk: disk, configs: [config])
        let session = ISCSISession(login: standardLogin(), policy: testPolicy()) {
            await fleet.makeTransport()
        }
        try await session.activate()
        let device = ISCSIBlockDevice(
            session: session,
            lun: 0,
            maxTransferBytes: 1 << 20,
            writeThrough: writeThrough
        )
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
        // Nothing may be sitting in the cache: FUA means the target had it on
        // stable media before it returned status.
        #expect(await disk.dirtyBlocks == 0)
        #expect(await disk.fuaWrites > 0)
        #expect(await disk.cachedWrites == 0)

        #expect(await disk.crash() == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)
        await fleet.shutdown()
    }

    @Test func cachedWritesAreLostOnTargetPowerLoss() async throws {
        // The negative control. Without FUA the target acknowledges from its
        // volatile cache, and a power cut takes the data with it — which is the
        // whole reason `writeThrough` defaults to on for Backend A.
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, writeThrough: false)
        let data = Self.payload(2)

        try await device.write(offset: 0, data: data)
        // Acknowledged, readable, and yet not durable — the dangerous state.
        #expect(await disk.dirtyBlocks == data.count / Self.blockSize)
        #expect(await disk.fuaWrites == 0)
        #expect(try await device.read(offset: 0, length: data.count) == data)

        let lost = await disk.crash()
        #expect(lost == data.count / Self.blockSize)
        let after = try await device.read(offset: 0, length: data.count)
        #expect(after != data)
        #expect(after == Data(count: data.count)) // back to the committed zeros
        await fleet.shutdown()
    }

    @Test func flushMakesCachedWritesDurable() async throws {
        // The third arm: barriers work when they are actually issued. This is
        // the behaviour Backend A would rely on if FSKit ever signalled one.
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
        // A crash is not all-or-nothing: everything up to the last barrier
        // survives, everything after it does not. A filesystem that trusts a
        // flush it never issued is what corrupts.
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        let (device, fleet) = try await makeDevice(disk: disk, writeThrough: false)
        let committed = Self.payload(4)
        let tail = Self.payload(5)

        try await device.write(offset: 0, data: committed)
        try await device.flush()
        try await device.write(offset: UInt64(committed.count), data: tail)

        #expect(await disk.crash() == tail.count / Self.blockSize)
        #expect(try await device.read(offset: 0, length: committed.count) == committed)
        let tailAfter = try await device.read(
            offset: UInt64(committed.count), length: tail.count
        )
        #expect(tailAfter == Data(count: tail.count))
        await fleet.shutdown()
    }

    @Test func fuaWriteSupersedesAStaleCachedCopy() async throws {
        // Ordering trap: block written without FUA, then rewritten with FUA.
        // If the target committed the FUA write but left the older cached copy
        // in place, the next flush would resurrect the stale version over the
        // durable one — silent corruption that only shows up after a flush.
        let disk = RAMDisk(blockSize: Self.blockSize, capacityBlocks: Self.capacityBlocks)
        var config = MockTargetConfig()
        config.maxRecvDataSegmentLength = 262_144
        let fleet = TargetFleet(disk: disk, configs: [config])
        let session = ISCSISession(login: standardLogin(), policy: testPolicy()) {
            await fleet.makeTransport()
        }
        try await session.activate()

        let cached = ISCSIBlockDevice(session: session, lun: 0, writeThrough: false)
        let durable = ISCSIBlockDevice(session: session, lun: 0, writeThrough: true)
        let old = Self.payload(6, blocks: 1)
        let new = Self.payload(7, blocks: 1)

        try await cached.write(offset: 0, data: old)
        try await durable.write(offset: 0, data: new)
        #expect(await disk.dirtyBlocks == 0)

        try await cached.flush() // must not resurrect `old`
        #expect(try await durable.read(offset: 0, length: new.count) == new)
        await fleet.shutdown()
    }
}
