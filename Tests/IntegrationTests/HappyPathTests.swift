import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// Every test that reads runs twice: status on the final Data-In (phase
/// collapse), and status in a SCSI Response after the Data-In sequence. LIO
/// sends both, so the initiator must complete a read either way.
@Suite("Integration: happy paths", .timeLimit(.minutes(1)))
struct HappyPathTests {
    static let statusModes = [false, true]

    private static func config(separateStatus: Bool) -> MockTargetConfig {
        var config = MockTargetConfig()
        config.separateReadStatus = separateStatus
        return config
    }

    @Test(arguments: statusModes)
    func loginInquiryLogout(separateStatus: Bool) async throws {
        let (connection, harness, result) = try await loggedInConnection(
            targetConfig: Self.config(separateStatus: separateStatus))
        #expect(result.tsih == 0x0BAD)
        #expect(!result.parameters.headerDigest)

        let inquiry = try await connection.execute(SCSITask(
            lun: 0,
            cdb: CDB.inquiry(),
            direction: .read(expectedLength: 255)
        ))
        #expect(inquiry.isGood)
        #expect(inquiry.data.count == 36) // underflow trimmed
        #expect(String(data: inquiry.data.sub(8, 8), encoding: .ascii) == "MOCKTGT ")

        let logout = try await connection.logout()
        #expect(logout.response == .success)
        await harness.finish()
    }

    @Test(arguments: statusModes)
    func smallWriteReadRoundTrip(separateStatus: Bool) async throws {
        let (connection, harness, _) = try await loggedInConnection(
            targetConfig: Self.config(separateStatus: separateStatus))
        let payload = Data((0 ..< 1024).map { UInt8($0 & 0xFF) })

        let write = try await connection.execute(SCSITask(
            lun: 0,
            cdb: CDB.write16(lba: 4, blocks: 2),
            direction: .write(payload)
        ))
        #expect(write.isGood)

        let read = try await connection.execute(SCSITask(
            lun: 0,
            cdb: CDB.read16(lba: 4, blocks: 2),
            direction: .read(expectedLength: 1024)
        ))
        #expect(read.isGood)
        #expect(read.data == payload)
        await harness.finish()
    }

    @Test(arguments: statusModes)
    func largeWriteExercisesR2T(separateStatus: Bool) async throws {
        // Small bursts force: immediate data + unsolicited tail + several R2Ts.
        var targetConfig = Self.config(separateStatus: separateStatus)
        targetConfig.firstBurstLength = 4096
        targetConfig.maxBurstLength = 8192
        targetConfig.maxRecvDataSegmentLength = 4096
        let (connection, harness, result) = try await loggedInConnection(targetConfig: targetConfig)
        #expect(result.parameters.firstBurstLength == 4096)
        #expect(result.parameters.maxBurstLength == 8192)

        let payload = Data((0 ..< 65536).map { UInt8(($0 &* 31) & 0xFF) })
        let write = try await connection.execute(SCSITask(
            lun: 0,
            cdb: CDB.write16(lba: 0, blocks: 128),
            direction: .write(payload)
        ))
        #expect(write.isGood)

        let read = try await connection.execute(SCSITask(
            lun: 0,
            cdb: CDB.read16(lba: 0, blocks: 128),
            direction: .read(expectedLength: 65536)
        ))
        #expect(read.data == payload)
        await harness.finish()
    }

    @Test(arguments: statusModes)
    func solicitedOnlyWritePath(separateStatus: Bool) async throws {
        // Target insists InitialR2T=Yes and ImmediateData=No: every byte moves
        // via R2T-solicited Data-Out.
        var targetConfig = Self.config(separateStatus: separateStatus)
        targetConfig.preferInitialR2T = true
        targetConfig.preferImmediateData = false
        let (connection, harness, result) = try await loggedInConnection(targetConfig: targetConfig)
        #expect(result.parameters.initialR2T)
        #expect(!result.parameters.immediateData)
        #expect(!result.parameters.canSendUnsolicitedDataOut)

        let payload = Data(repeating: 0x5C, count: 8192)
        let write = try await connection.execute(SCSITask(
            lun: 0,
            cdb: CDB.write16(lba: 16, blocks: 16),
            direction: .write(payload)
        ))
        #expect(write.isGood)

        let read = try await connection.execute(SCSITask(
            lun: 0,
            cdb: CDB.read16(lba: 16, blocks: 16),
            direction: .read(expectedLength: 8192)
        ))
        #expect(read.data == payload)
        await harness.finish()
    }

    @Test(arguments: statusModes)
    func digestsNegotiatedAndUsed(separateStatus: Bool) async throws {
        var targetConfig = Self.config(separateStatus: separateStatus)
        targetConfig.digestPick = "CRC32C"
        let (connection, harness, result) = try await loggedInConnection(targetConfig: targetConfig) {
            $0.desired.offerDigests = true
        }
        #expect(result.parameters.headerDigest)
        #expect(result.parameters.dataDigest)

        // Real I/O flows with both digests on.
        let payload = Data(repeating: 0xD1, count: 2048)
        _ = try await connection.execute(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 0, blocks: 4), direction: .write(payload)
        ))
        let read = try await connection.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 0, blocks: 4), direction: .read(expectedLength: 2048)
        ))
        #expect(read.data == payload)
        await harness.finish()
    }

    @Test(arguments: statusModes)
    func readCapacityAndTestUnitReady(separateStatus: Bool) async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 4096)
        let (connection, harness, _) = try await loggedInConnection(
            targetConfig: Self.config(separateStatus: separateStatus), disk: disk)

        let tur = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(tur.isGood)

        let capacity = try await connection.execute(SCSITask(
            lun: 0, cdb: CDB.readCapacity16(), direction: .read(expectedLength: 32)
        ))
        #expect(capacity.isGood)
        #expect(capacity.data.beU64(0) == 4095) // last LBA
        #expect(capacity.data.beU32(8) == 512) // block size
        await harness.finish()
    }

    @Test func synchronizeCacheReachesDisk() async throws {
        let disk = RAMDisk()
        let (connection, harness, _) = try await loggedInConnection(disk: disk)
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.synchronizeCache16()))
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.synchronizeCache16()))
        #expect(await disk.flushCount == 2)
        await harness.finish()
    }

    @Test func nopPingRoundTrip() async throws {
        let (connection, harness, _) = try await loggedInConnection()
        try await connection.ping(payload: Data("hello".utf8))
        try await connection.ping()
        await harness.finish()
    }

    @Test func targetInitiatedPingIsEchoed() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.faults.nopPingOnConnect = true
        let (connection, harness, _) = try await loggedInConnection(targetConfig: targetConfig)
        // Drive some traffic so the echo lands, then check the target saw it.
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        try await Task.sleep(for: .milliseconds(50))
        let echoes = await harness.target.pingEchoes
        #expect(echoes == [Data("mock-ping".utf8)])
        await harness.finish()
    }

    @Test func chapLoginSucceeds() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "initiator-user"
        targetConfig.chapSecret = "super-secret-chap"
        let (connection, harness, result) = try await loggedInConnection(
            targetConfig: targetConfig,
            chap: CHAP.Credentials(name: "initiator-user", secret: "super-secret-chap")
        )
        #expect(result.tsih != 0)
        let tur = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(tur.isGood)
        await harness.finish()
    }

    @Test func mutualChapVerifiesTarget() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "u"
        targetConfig.chapSecret = "s"
        targetConfig.mutualSecret = "target-proof"
        targetConfig.mutualName = "mock-target"
        let (connection, harness, _) = try await loggedInConnection(
            targetConfig: targetConfig,
            chap: CHAP.Credentials(
                name: "u", secret: "s",
                mutualName: "mock-target", mutualSecret: "target-proof"
            )
        )
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        await harness.finish()
    }

    @Test func chapWrongSecretFails() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "u"
        targetConfig.chapSecret = "right"
        let harness = TargetHarness.start(config: targetConfig)
        let connection = ISCSIConnection(
            transport: harness.transport,
            login: standardLogin(chap: CHAP.Credentials(name: "u", secret: "wrong"))
        )
        await #expect(throws: ConnectionError.self) {
            _ = try await connection.login()
        }
        await harness.finish()
    }

    @Test func discoverySendTargets() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.discoveryTargets = [
            (name: "iqn.2026-08.test.example:disk0", addresses: ["10.0.0.5:3260,1"]),
            (name: "iqn.2026-08.test.example:disk1", addresses: ["10.0.0.5:3260,1", "10.0.0.6:3260,2"]),
        ]
        let harness = TargetHarness.start(config: targetConfig)
        let targets = try await Discovery.sendTargets(
            transport: harness.transport,
            initiatorName: "iqn.2026-08.com.example:initiator"
        )
        #expect(targets.count == 2)
        #expect(targets[0].name == "iqn.2026-08.test.example:disk0")
        #expect(targets[1].addresses == ["10.0.0.5:3260,1", "10.0.0.6:3260,2"])
        await harness.finish()
    }

    @Test func discoveryTextContinuationReassembled() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.discoveryTargets = [
            (name: "iqn.2026-08.test.example:disk0", addresses: ["192.168.44.10:3260,1"]),
            (name: "iqn.2026-08.test.example:disk1", addresses: ["192.168.44.10:3260,1"]),
        ]
        targetConfig.faults.splitTextResponsesAt = 24 // force C-bit continuation
        let harness = TargetHarness.start(config: targetConfig)
        let targets = try await Discovery.sendTargets(
            transport: harness.transport,
            initiatorName: "iqn.2026-08.com.example:initiator"
        )
        #expect(targets.count == 2)
        await harness.finish()
    }

    @Test(arguments: statusModes)
    func concurrentCommandsInterleave(separateStatus: Bool) async throws {
        let (connection, harness, _) = try await loggedInConnection(
            targetConfig: Self.config(separateStatus: separateStatus))
        // Several tasks in flight at once; all must complete correctly.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 8 {
                group.addTask {
                    let pattern = Data(repeating: UInt8(i), count: 512)
                    let write = try await connection.execute(SCSITask(
                        lun: 0,
                        cdb: CDB.write16(lba: UInt64(i * 8), blocks: 1),
                        direction: .write(pattern)
                    ))
                    #expect(write.isGood)
                    let read = try await connection.execute(SCSITask(
                        lun: 0,
                        cdb: CDB.read16(lba: UInt64(i * 8), blocks: 1),
                        direction: .read(expectedLength: 512)
                    ))
                    #expect(read.data == pattern)
                }
            }
            try await group.waitForAll()
        }
        await harness.finish()
    }
}
