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
        let core = DaemonCore(initiatorName: "iqn.2026-08.com.example:daemon") { _, _, _ in
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

    // GitHub #3: a Synology (LIO) target with its LUN mapped at 1 answers LUN
    // 0 with a 32 KiB placeholder whose geometry is valid. REPORT LUNS is the
    // check that catches it, and the refusal must name the LUN that exists.
    @Test func loginRefusesLUNTheTargetDoesNotReport() async throws {
        var config = MockTargetConfig()
        config.luns = [1]
        let (core, cleanup) = makeDaemon(config: config)
        defer { cleanup() }

        await #expect(throws: DaemonUnitError.notPresent(requested: 0, available: [1], isNVMe: false)) {
            try await core.login(host: "nas", port: 3260,
                                 targetIQN: "iqn.2026-08.test.example:disk0", lun: 0)
        }
        // A refused login leaves no session behind.
        #expect(await core.sessionHandles().isEmpty)

        let error = DaemonUnitError.notPresent(requested: 0, available: [1], isNVMe: false)
        #expect(error.errorDescription == "The target has no LUN 0; it reports LUN 1.")
        #expect(error.recoverySuggestion == "Edit the target and set its LUN to 1.")
    }

    @Test func loginAcceptsTheLUNTheTargetReports() async throws {
        var config = MockTargetConfig()
        config.luns = [1, 300] // one in each REPORT LUNS addressing form
        let (core, cleanup) = makeDaemon(config: config)
        defer { cleanup() }

        for lun: UInt64 in [1, 300] {
            let handle = try await core.login(host: "nas", port: 3260,
                                              targetIQN: "iqn.2026-08.test.example:disk0", lun: lun)
            #expect(try await core.reportLUNs(handle).map(\.lun) == [1, 300])
            try await core.logout(handle)
        }
    }

    @Test func loginToleratesAnEmptyLUNList() async throws {
        // A target that answers REPORT LUNS with nothing gets the old
        // behaviour: READ CAPACITY decides.
        var config = MockTargetConfig()
        config.luns = []
        let (core, cleanup) = makeDaemon(config: config)
        defer { cleanup() }
        let handle = try await core.login(host: "nas", port: 3260,
                                          targetIQN: "iqn.2026-08.test.example:disk0", lun: 0)
        try await core.logout(handle)
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
