import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// A write larger than `maxTransferBytes` is split into chunks, and those chunks
/// are contiguous slices of one buffer — disjoint by construction. Nothing
/// depends on the order they complete in, which is the same argument
/// `ISCSIBlockDevice.read` makes for pipelining its own chunks.
///
/// The measurement is not wall-clock. CI runs `--no-parallel` precisely because
/// timing assertions measure the runner once it is loaded, and "this took less
/// than N ms" is the shape that failed there. Instead the target is told to
/// stall every command — accept it, never answer — and then asked how many it
/// was handed. A serialised writer can only ever have one command outstanding
/// against a target that never replies; a pipelined one has all of them.
@Suite("Integration: write chunk concurrency", .timeLimit(.minutes(1)))
struct WriteConcurrencyTests {
    /// Stalling has to be armed *after* login and after the capacity read that
    /// every block-device call makes first, or the write never gets issued at
    /// all and the test measures nothing.
    private func makeStallableDevice(
        blockSize: Int = 512,
        maxTransferBytes: Int
    ) async throws -> (ISCSIBlockDevice, MockTarget, FaultBox, Task<Void, Never>) {
        let faultBox = FaultBox()
        let disk = RAMDisk(blockSize: blockSize, capacityBlocks: 8192)
        let harness = TargetHarness.start(disk: disk, faultBox: faultBox)
        let session = ISCSISession(
            login: standardLogin(),
            policy: testPolicy(),
            transportFactory: { harness.transport }
        )
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: 0,
                                      maxTransferBytes: maxTransferBytes)
        _ = try await device.readCapacity()   // cached, so the write path won't re-ask
        return (device, harness.target, faultBox, harness.serveTask)
    }

    /// Polls rather than sleeping a fixed interval: the question is "have N
    /// commands arrived", and the answer arrives when it arrives.
    private func waitForStalledCommands(
        on target: MockTarget, atLeast wanted: Int, within: Duration = .seconds(2)
    ) async -> Int {
        let deadline = ContinuousClock.now.advanced(by: within)
        var seen = 0
        while ContinuousClock.now < deadline {
            seen = await target.stalledITTs.count
            if seen >= wanted { return seen }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return seen
    }

    @Test func aMultiChunkWriteIssuesEveryChunkWithoutWaiting() async throws {
        // 512-byte blocks, 1 KiB chunks, a 4 KiB write — four commands.
        let (device, target, faultBox, serve) = try await makeStallableDevice(
            maxTransferBytes: 1024)
        defer { serve.cancel() }

        faultBox.mutate { $0.stallCommands = true }
        let payload = Data(repeating: 0xAB, count: 4096)
        let writer = Task { try await device.write(offset: 0, data: payload) }
        defer { writer.cancel() }

        let seen = await waitForStalledCommands(on: target, atLeast: 4)
        #expect(seen == 4, "expected all four chunks outstanding at once, saw \(seen)")
    }

    @Test func aSingleChunkWriteIssuesExactlyOneCommand() async throws {
        // The floor of the same measurement: one chunk cannot be pipelined, so
        // a count above 1 here would mean the split itself is wrong.
        let (device, target, faultBox, serve) = try await makeStallableDevice(
            maxTransferBytes: 4096)
        defer { serve.cancel() }

        faultBox.mutate { $0.stallCommands = true }
        let payload = Data(repeating: 0xCD, count: 1024)
        let writer = Task { try await device.write(offset: 0, data: payload) }
        defer { writer.cancel() }

        _ = await waitForStalledCommands(on: target, atLeast: 1)
        // Give any spurious extra command a chance to show up before asserting.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await target.stalledITTs.count == 1)
    }

    /// Concurrency changes completion order, so the bytes are worth re-checking
    /// against a target that answers: chunk N landing before chunk N-1 must not
    /// change what ends up on the medium.
    @Test func aMultiChunkWriteLandsByteExactDespiteCompletionOrder() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 8192)
        let harness = TargetHarness.start(disk: disk)
        defer { harness.serveTask.cancel() }
        let session = ISCSISession(
            login: standardLogin(),
            policy: testPolicy(),
            transportFactory: { harness.transport }
        )
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: 0, maxTransferBytes: 1024)

        // Distinct per chunk, so a swapped or duplicated chunk is visible.
        var payload = Data()
        for chunk in 0 ..< 8 {
            payload.append(Data(repeating: UInt8(0x10 + chunk), count: 1024))
        }
        try await device.write(offset: 4096, data: payload)
        #expect(try await device.read(offset: 4096, length: payload.count) == payload)
    }

    /// The fan-out is bounded, and this is what bounds it.
    ///
    /// Every chunk of a write holds a copy of its slice from the moment its task
    /// starts until the command completes, so an unbounded group made a large
    /// request cost memory proportional to its own size — a 64 MiB write grew
    /// the process by 109 MiB. A stalled target never answers, so every command
    /// the initiator was willing to have outstanding is still sitting there to
    /// be counted.
    @Test func aLargeWriteKeepsOnlyAWindowInFlight() async throws {
        // 4 KiB commands, 4 MiB request: 1024 chunks, far more than the window.
        let (device, target, faultBox, serve) = try await makeStallableDevice(
            maxTransferBytes: 4096)
        defer { serve.cancel() }

        faultBox.mutate { $0.stallCommands = true }
        let writer = Task { try await device.write(offset: 0, data: Data(count: 4 << 20)) }
        defer { writer.cancel() }

        // Give it every chance to fan out further than it should.
        _ = await waitForStalledCommands(on: target, atLeast: ISCSIBlockDevice.maxChunksInFlight)
        try? await Task.sleep(for: .milliseconds(150))

        let inFlight = await target.stalledITTs.count
        #expect(inFlight == ISCSIBlockDevice.maxChunksInFlight,
                "a 1024-chunk write put \(inFlight) commands in flight")
    }
}
