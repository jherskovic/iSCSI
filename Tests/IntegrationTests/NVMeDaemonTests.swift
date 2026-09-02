import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIDaemon
@testable import iSCSIKit

/// The daemon serving both protocols from one registry. The transport
/// factory routes by port: 3260 gets an iSCSI MockTarget, 4420 the NVMe
/// mock subsystem — the same split the real network has.
private func makeDualDaemon(
    nvmeDisk: RAMDisk = RAMDisk(blockSize: 4096, capacityBlocks: 4096),
    nvmeConfig: MockNVMeConfig = MockNVMeConfig(),
    iscsiDisk: RAMDisk = RAMDisk(),
    writeThrough: Bool = true
) -> (DaemonCore, MockNVMeSubsystem, @Sendable () -> Void) {
    let harnesses = HarnessBox()
    let subsystem = MockNVMeSubsystem(config: nvmeConfig, disk: nvmeDisk)
    let core = DaemonCore(initiatorName: "iqn.2026-08.com.example:daemon",
                          writeThrough: writeThrough, policy: testPolicy(),
                          hostIdentity: testHost) { _, port in
        let (initiatorSide, targetSide) = MemoryPipe.pair()
        if port == 4420 {
            harnesses.add(Task { await subsystem.serve(targetSide) })
        } else {
            let target = MockTarget(config: MockTargetConfig(), disk: iscsiDisk, transport: targetSide)
            harnesses.add(Task { await target.run() })
        }
        return initiatorSide
    }
    return (core, subsystem, { harnesses.cancelAll() })
}

private let nqn = MockNVMeConfig().subsystemNQN
private let iqn = MockTargetConfig().targetName

@Suite("Integration: daemon core over NVMe/TCP", .timeLimit(.minutes(1)))
struct NVMeDaemonCoreTests {
    @Test func anNQNNameLogsInOverNVMeAndDoesBlockIO() async throws {
        let disk = RAMDisk(blockSize: 4096, capacityBlocks: 4096)
        let (core, _, cleanup) = makeDualDaemon(nvmeDisk: disk)
        defer { cleanup() }

        let handle = try await core.login(host: "nas", port: 4420, targetIQN: nqn, lun: 1)
        #expect(await core.sessionHandles() == [handle])
        let (bs, count) = try await core.capacity(handle)
        #expect(bs == 4096 && count == 4096)

        let payload = Data((0 ..< 8192).map { UInt8($0 & 0xFF) })
        try await core.write(handle, offset: 4096, data: payload)
        try await core.flush(handle)
        #expect(try await core.read(handle, offset: 4096, length: 8192) == payload)
        #expect(await disk.fuaWrites > 0)          // the daemon's write-through default, over NVMe

        let units = try await core.reportLUNs(handle)
        #expect(units.map(\.lun) == [1])            // the namespace list, in the LUN slot

        let details = await core.sessionDetails()
        #expect(details.count == 1)
        #expect(details[0].targetIQN == nqn && details[0].lun == 1)
        #expect(details[0].isNVMe)
        #expect(details[0].writeCacheEnabled == true)
        #expect(details[0].negotiated["MDTS"] != nil && details[0].negotiated["CNTLID"] != nil)

        try await core.logout(handle)
        #expect(await core.sessionHandles().isEmpty)
    }

    @Test func iscsiAndNVMeSessionsCoexistInOneRegistry() async throws {
        let (core, _, cleanup) = makeDualDaemon()
        defer { cleanup() }
        let scsi = try await core.login(host: "nas", port: 3260, targetIQN: iqn, lun: 0)
        let nvme = try await core.login(host: "nas", port: 4420, targetIQN: nqn, lun: 1)
        #expect(await core.sessionHandles().count == 2)
        #expect(try await core.capacity(scsi).blockSize == 512)
        #expect(try await core.capacity(nvme).blockSize == 4096)
        #expect(try await core.reportLUNs(scsi).map(\.lun) == [0])
        #expect(try await core.reportLUNs(nvme).map(\.lun) == [1])
        let details = await core.sessionDetails()
        #expect(details.filter { $0.isNVMe }.count == 1)
        try await core.logout(scsi)
        try await core.logout(nvme)
    }

    @Test func discoverSubsystemsThroughTheDaemon() async throws {
        var config = MockNVMeConfig()
        config.discoveryEntries = [(subnqn: nqn, traddr: "192.168.20.1", trsvcid: "4420")]
        let (core, _, cleanup) = makeDualDaemon(nvmeConfig: config)
        defer { cleanup() }
        let found = try await core.discoverSubsystems(host: "nas", port: 4420)
        #expect(found.map(\.name) == [nqn])
        #expect(found[0].addresses == ["192.168.20.1:4420"])
    }

    @Test func chapCredentialsAreIgnoredForAnNQNTarget() async throws {
        let (core, _, cleanup) = makeDualDaemon()
        defer { cleanup() }
        let handle = try await core.login(host: "nas", port: 4420, targetIQN: nqn, lun: 1,
                                          chap: CHAP.Credentials(name: "u", secret: "secretsecret1234"))
        #expect(try await core.capacity(handle).blockSize == 4096)
        try await core.logout(handle)
    }

    @Test func aNamespaceIDPastUInt32IsRefusedBeforeTheWire() async throws {
        let (core, subsystem, cleanup) = makeDualDaemon()
        defer { cleanup() }
        await #expect(throws: BlockDeviceError.self) {
            _ = try await core.login(host: "nas", port: 4420, targetIQN: nqn, lun: 1 << 40)
        }
        #expect(await subsystem.connectionsServed == 0)
    }

    @Test func intervalFlushPolicyCommitsCachedWritesOverNVMe() async throws {
        let disk = RAMDisk(blockSize: 4096, capacityBlocks: 4096)
        let (core, _, cleanup) = makeDualDaemon(nvmeDisk: disk)
        defer { cleanup() }
        let handle = try await core.login(host: "nas", port: 4420, targetIQN: nqn, lun: 1,
                                          flushPolicy: .interval(seconds: 1))
        try await core.write(handle, offset: 0, data: Data(repeating: 0xAB, count: 4096))
        #expect(await disk.fuaWrites == 0)
        #expect(await disk.dirtyBlocks == 1)

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, await disk.dirtyBlocks > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await disk.dirtyBlocks == 0)
        #expect(await disk.flushCount >= 1)
        try await core.logout(handle)
    }

    @Test func detachFlushesARelaxedSessionOverNVMe() async throws {
        let disk = RAMDisk(blockSize: 4096, capacityBlocks: 4096)
        let (core, _, cleanup) = makeDualDaemon(nvmeDisk: disk)
        defer { cleanup() }
        let handle = try await core.login(host: "nas", port: 4420, targetIQN: nqn, lun: 1,
                                          flushPolicy: .never)
        try await core.write(handle, offset: 0, data: Data(repeating: 0xCD, count: 4096))
        #expect(await disk.dirtyBlocks == 1)
        try await core.logout(handle)
        #expect(await disk.dirtyBlocks == 0)
        #expect(await disk.flushCount == 1)
    }
}

@Suite("XPC service surface over NVMe/TCP", .timeLimit(.minutes(1)))
struct NVMeXPCServiceTests {
    private func makeService() async throws -> (ISCSIXPCService, TargetRecord, @Sendable () -> Void) {
        let (core, _, cleanup) = makeDualDaemon()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        let store = TargetStore(url: url)
        let record = TargetRecord(id: UUID().uuidString, displayName: "NVMe mock",
                                  host: "nas", port: 4420, targetIQN: nqn, lun: 1)
        try await store.save(record)
        return (ISCSIXPCService(core: core, targets: store, hostNQN: testHost.nqn), record, cleanup)
    }

    @Test func daemonInfoCarriesTheHostNQN() async throws {
        let (service, _, cleanup) = try await makeService()
        defer { cleanup() }
        let data: Data = try await withCheckedThrowingContinuation { c in
            service.daemonInfo { data, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data!) }
            }
        }
        let info = try JSONDecoder().decode(DaemonInfo.self, from: data)
        #expect(info.hostNQN == testHost.nqn)
    }

    @Test func anNVMeRecordLogsInAndTestsItsConnection() async throws {
        let (service, record, cleanup) = try await makeService()
        defer { cleanup() }
        let handle: String = try await withCheckedThrowingContinuation { c in
            service.login(host: record.host, port: NSNumber(value: record.port),
                          targetIQN: record.targetIQN, lun: NSNumber(value: record.lun)) { handle, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: handle!) }
            }
        }
        let (bs, _): (NSNumber, NSNumber) = try await withCheckedThrowingContinuation { c in
            service.capacity(session: handle) { bs, count, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: (bs, count)) }
            }
        }
        #expect(bs.intValue == 4096)

        let probe: Data = try await withCheckedThrowingContinuation { c in
            service.testConnection(host: record.host, port: NSNumber(value: record.port),
                                   targetIQN: record.targetIQN, lun: NSNumber(value: record.lun)) { data, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data!) }
            }
        }
        let info = try JSONDecoder().decode(LUNInfo.self, from: probe)
        #expect(info.lun == 1 && info.blockSize == 4096)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            service.logout(session: handle) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    @Test func discoverSubsystemsRepliesWithSubsystemNames() async throws {
        var config = MockNVMeConfig()
        config.discoveryEntries = [(subnqn: nqn, traddr: "192.168.20.1", trsvcid: "4420")]
        let (core, _, cleanup) = makeDualDaemon(nvmeConfig: config)
        defer { cleanup() }
        let service = ISCSIXPCService(core: core, targets: TargetStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")))
        let data: Data = try await withCheckedThrowingContinuation { c in
            service.discoverSubsystems(host: "nas", port: 4420) { data, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data!) }
            }
        }
        let found = try JSONDecoder().decode([DiscoveredTargetInfo].self, from: data)
        #expect(found.map(\.targetIQN) == [nqn])
        #expect(found[0].addresses == ["192.168.20.1:4420"])
    }
}
