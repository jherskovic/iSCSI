#if canImport(Network)
import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// End-to-end over a real loopback TCP socket, exercising `NetworkTransport`
/// (the same code path used against the NAS) rather than the in-memory pipe.
@Suite("Integration: real TCP loopback", .timeLimit(.minutes(1)))
struct LoopbackTCPTests {
    @Test func loginReadWriteVerifyOverTCP() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 2048)
        let server = try MockTargetServer(disk: disk) {
            var config = MockTargetConfig()
            config.digestPick = "CRC32C" // digests on, over a real socket
            return config
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await NetworkTransport.connect(host: "127.0.0.1", port: port)
        var config = LoginConfig(
            initiatorName: "iqn.2026-08.com.example:loopback",
            sessionType: .normal,
            targetName: "iqn.2026-08.test.example:disk0"
        )
        config.desired.offerDigests = true
        let connection = ISCSIConnection(transport: transport, login: config)
        let result = try await connection.login()
        #expect(result.parameters.headerDigest)
        #expect(result.parameters.dataDigest)

        // Capacity, write, flush, read-back with CRC32C digests on the wire.
        let capacity = try await connection.executeChecked(SCSITask(
            lun: 0, cdb: CDB.readCapacity16(), direction: .read(expectedLength: 32)
        ))
        #expect(capacity.data.beU64(0) == 2047)

        let payload = Data((0 ..< 16384).map { UInt8(($0 &* 41) & 0xFF) })
        _ = try await connection.executeChecked(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 8, blocks: 32), direction: .write(payload)
        ))
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.synchronizeCache16()))
        #expect(await disk.flushCount == 1)

        let readback = try await connection.executeChecked(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 8, blocks: 32), direction: .read(expectedLength: 16384)
        ))
        #expect(readback.data == payload)

        _ = try await connection.logout()
        await server.stop()
    }

    @Test func discoveryOverTCP() async throws {
        let server = try MockTargetServer {
            var config = MockTargetConfig()
            config.discoveryTargets = [
                (name: "iqn.2026-08.test.example:disk0", addresses: ["127.0.0.1:3260,1"]),
                (name: "iqn.2026-08.test.example:disk1", addresses: ["127.0.0.1:3260,1"]),
            ]
            return config
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await NetworkTransport.connect(host: "127.0.0.1", port: port)
        let targets = try await Discovery.sendTargets(
            transport: transport,
            initiatorName: "iqn.2026-08.com.example:loopback"
        )
        #expect(targets.count == 2)
        #expect(targets[0].name == "iqn.2026-08.test.example:disk0")
        await server.stop()
    }

    @Test func sessionRecoversOverTCP() async throws {
        // Session layer reconnecting via NetworkTransport to the same listener.
        let disk = RAMDisk()
        let server = try MockTargetServer(disk: disk)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        var policy = SessionPolicy()
        policy.nopInterval = nil
        policy.recoveryBackoffBase = .milliseconds(20)
        policy.maxRecoveryAttempts = 4
        policy.taskRetries = 3

        var config = LoginConfig(
            initiatorName: "iqn.2026-08.com.example:loopback",
            sessionType: .normal,
            targetName: "iqn.2026-08.test.example:disk0"
        )
        config.desired.offerDigests = false

        let session = ISCSISession(login: config, policy: policy) {
            try await NetworkTransport.connect(host: "127.0.0.1", port: port)
        }
        try await session.activate()
        let pattern = Data(repeating: 0xC3, count: 1024)
        _ = try await session.executeChecked(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 0, blocks: 2), direction: .write(pattern)
        ))
        let read = try await session.executeChecked(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 0, blocks: 2), direction: .read(expectedLength: 1024)
        ))
        #expect(read.data == pattern)
        try await session.logout()
        await server.stop()
    }
}
#endif
