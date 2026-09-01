import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// `WriteConcurrencyTests` over NVMe/TCP: chunks of one write are issued
/// together, bounded by `maxChunksInFlight`, measured by counting the
/// commands a stalled controller was handed.
@Suite("Integration: NVMe/TCP write chunk concurrency", .timeLimit(.minutes(1)))
struct NVMeWriteConcurrencyTests {
    private func makeStallableDevice(
        maxTransferBytes: Int
    ) async throws -> (NVMeBlockDevice, NVMeFleet, FaultBox) {
        let faultBox = FaultBox()
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 8192)
        let fleet = NVMeFleet(disk: disk)
        // One shared box for every connection this fleet serves.
        let controller = NVMeController(config: testControllerConfig(), policy: testPolicy()) {
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let subsystem = await fleet.subsystem
            Task { await subsystem.serve(targetSide, faultBox: faultBox) }
            return initiatorSide
        }
        try await controller.activate()
        let device = NVMeBlockDevice(controller: controller, nsid: 1, maxTransferBytes: maxTransferBytes)
        _ = try await device.readCapacity()   // cached, so the write path won't re-ask
        return (device, fleet, faultBox)
    }

    private func waitForStalledCommands(
        on subsystem: MockNVMeSubsystem, atLeast wanted: Int, within: Duration = .seconds(2)
    ) async -> Int {
        let deadline = ContinuousClock.now.advanced(by: within)
        var seen = 0
        while ContinuousClock.now < deadline {
            seen = await subsystem.stalledCIDs.count
            if seen >= wanted { return seen }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return seen
    }

    @Test func aMultiChunkWriteIssuesEveryChunkWithoutWaiting() async throws {
        let (device, fleet, faultBox) = try await makeStallableDevice(maxTransferBytes: 1024)
        faultBox.mutate { $0.stallCommands = true }
        let writer = Task { try await device.write(offset: 0, data: Data(repeating: 0xAB, count: 4096)) }
        defer { writer.cancel() }
        let seen = await waitForStalledCommands(on: fleet.subsystem, atLeast: 4)
        #expect(seen == 4, "expected all four chunks outstanding at once, saw \(seen)")
    }

    @Test func aSingleChunkWriteIssuesExactlyOneCommand() async throws {
        let (device, fleet, faultBox) = try await makeStallableDevice(maxTransferBytes: 4096)
        faultBox.mutate { $0.stallCommands = true }
        let writer = Task { try await device.write(offset: 0, data: Data(repeating: 0xCD, count: 1024)) }
        defer { writer.cancel() }
        _ = await waitForStalledCommands(on: fleet.subsystem, atLeast: 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await fleet.subsystem.stalledCIDs.count == 1)
    }

    @Test func aMultiChunkWriteLandsByteExactDespiteCompletionOrder() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 8192)
        let fleet = NVMeFleet(disk: disk)
        let controller = try await activatedController(fleet: fleet)
        let device = NVMeBlockDevice(controller: controller, nsid: 1, maxTransferBytes: 1024)
        var payload = Data()
        for chunk in 0 ..< 8 {
            payload.append(Data(repeating: UInt8(0x10 + chunk), count: 1024))
        }
        try await device.write(offset: 4096, data: payload)
        #expect(try await device.read(offset: 4096, length: payload.count) == payload)
        await fleet.shutdown()
    }

    @Test func aLargeWriteKeepsOnlyAWindowInFlight() async throws {
        let (device, fleet, faultBox) = try await makeStallableDevice(maxTransferBytes: 4096)
        faultBox.mutate { $0.stallCommands = true }
        let writer = Task { try await device.write(offset: 0, data: Data(count: 4 << 20)) }
        defer { writer.cancel() }
        _ = await waitForStalledCommands(on: fleet.subsystem, atLeast: NVMeBlockDevice.maxChunksInFlight)
        try? await Task.sleep(for: .milliseconds(150))
        let inFlight = await fleet.subsystem.stalledCIDs.count
        #expect(inFlight == NVMeBlockDevice.maxChunksInFlight,
                "a 1024-chunk write put \(inFlight) commands in flight")
    }
}
