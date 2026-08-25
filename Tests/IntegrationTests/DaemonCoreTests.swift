import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIDaemon
@testable import iSCSIKit

/// Tests the daemon's session registry + block-I/O engine directly (the XPC
/// transport is a thin shell over this and isn't exercisable in unit tests).
/// The transport factory hands out MockTarget-backed MemoryPipes.
@Suite("Integration: daemon core", .timeLimit(.minutes(1)))
struct DaemonCoreTests {
    /// A daemon whose transport factory serves a shared RAMDisk over MockTarget.
    func makeDaemon(
        disk: RAMDisk = RAMDisk(),
        config: MockTargetConfig = MockTargetConfig()
    ) -> (DaemonCore, @Sendable () -> Void) {
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.2026-08.com.example:daemon") { _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: config, disk: disk, transport: targetSide)
            let task = Task { await target.run() }
            harnesses.add(task)
            return initiatorSide
        }
        return (core, { harnesses.cancelAll() })
    }

    @Test func loginCapacityReadWrite() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 4096)
        let (core, cleanup) = makeDaemon(disk: disk)
        defer { cleanup() }

        let handle = try await core.login(
            host: "nas", port: 3260,
            targetIQN: "iqn.2026-08.test.example:disk0", lun: 0
        )
        #expect(await core.sessionHandles() == [handle])

        let (bs, count) = try await core.capacity(handle)
        #expect(bs == 512)
        #expect(count == 4096)

        let payload = Data((0 ..< 2048).map { UInt8($0 & 0xFF) })
        try await core.write(handle, offset: 1024, data: payload)
        try await core.flush(handle)
        let readback = try await core.read(handle, offset: 1024, length: 2048)
        #expect(readback == payload)

        try await core.logout(handle)
        #expect(await core.sessionHandles().isEmpty)
    }

    @Test func multipleSessions() async throws {
        let (core, cleanup) = makeDaemon()
        defer { cleanup() }
        let h1 = try await core.login(host: "a", port: 3260, targetIQN: "iqn.2026-08.test.example:disk0", lun: 0)
        let h2 = try await core.login(host: "a", port: 3260, targetIQN: "iqn.2026-08.test.example:disk0", lun: 0)
        #expect(h1 != h2)
        #expect(await core.sessionHandles().count == 2)
        try await core.logout(h1)
        #expect(await core.sessionHandles() == [h2])
        cleanup()
    }

    @Test func discoverThroughDaemon() async throws {
        var config = MockTargetConfig()
        config.discoveryTargets = [
            (name: "iqn.2026-08.test.example:disk0", addresses: ["10.0.0.1:3260,1"]),
        ]
        let (core, cleanup) = makeDaemon(config: config)
        defer { cleanup() }
        let targets = try await core.discover(host: "nas", port: 3260)
        #expect(targets.count == 1)
        #expect(targets[0].name == "iqn.2026-08.test.example:disk0")
    }

    @Test func readOnBadHandleThrows() async throws {
        let (core, cleanup) = makeDaemon()
        defer { cleanup() }
        await #expect(throws: BlockDeviceError.self) {
            _ = try await core.read("nonexistent", offset: 0, length: 512)
        }
    }
}

/// Thread-safe holder for serve tasks so the transport factory (which is
/// @Sendable and non-isolated) can register them for cleanup.
final class HarnessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    func add(_ task: Task<Void, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
    func cancelAll() { lock.lock(); let t = tasks; tasks = []; lock.unlock(); t.forEach { $0.cancel() } }
}

@Suite("Integration: REPORT LUNS parsing")
struct ReportLUNsParsingTests {
    /// SPC LUN entries come in peripheral or flat-space format; both must
    /// round-trip to the right LUN number, and other formats must be skipped.
    @Test func peripheralAndFlatEntriesParsed() {
        #expect(DaemonCore.lunNumber(fromReportLUNsEntry: Data([0, 5, 0, 0, 0, 0, 0, 0])) == 5)
        #expect(DaemonCore.lunNumber(fromReportLUNsEntry: Data([0x41, 0x2C, 0, 0, 0, 0, 0, 0])) == 300)
        #expect(DaemonCore.lunNumber(fromReportLUNsEntry: Data([0x80, 0, 0, 0, 0, 0, 0, 0])) == nil)
        #expect(DaemonCore.lunNumber(fromReportLUNsEntry: Data([0x01, 5, 0, 0, 0, 0, 0, 0])) == nil)
    }
}
