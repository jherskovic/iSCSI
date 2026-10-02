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

    // MARK: - Interface pinning, over real sockets

    @Test("the system snapshot lists loopback and its address")
    func snapshotListsLoopback() {
        let snapshot = SystemInterfaces.snapshot()
        #expect(snapshot.present.contains("lo0"))
        #expect(snapshot.addresses.contains(
            InterfaceAddress(name: "lo0", address: "127.0.0.1", isIPv6: false)))
    }

    @Test("the system resolver returns a literal as itself and resolves localhost")
    func resolverAnswers() throws {
        #expect(try SystemInterfaces.resolve("127.0.0.1") == ["127.0.0.1"])
        #expect(try SystemInterfaces.resolve("localhost").contains("127.0.0.1"))
        #expect(throws: (any Error).self) { try SystemInterfaces.resolve("nosuch.invalid") }
    }

    @Test("a connection pinned to lo0 runs over lo0")
    func pinnedToLoopback() async throws {
        let server = try MockTargetServer { MockTargetConfig() }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await NetworkTransport.connect(
            host: "127.0.0.1", port: port,
            binding: InterfaceBinding(name: "lo0", fallback: false))
        #expect(transport.connectedPath.interfaceName == "lo0")
        #expect(transport.connectedPath.fallback == nil)
        await transport.close()
    }

    /// Strict waits for a missing interface within the connect deadline, as
    /// an unpinned connect to a vanished link waits out its SYN — so a cable
    /// re-seated inside recovery's budget heals the session — then names it.
    @Test("strict: a missing interface fails once the deadline passes, naming it")
    func strictMissingInterfaceWaitsOutTheDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TransportError.interfaceUnavailable(
            name: "nosuch0", reason: "it is not present")) {
            _ = try await NetworkTransport.connect(
                host: "127.0.0.1", port: 9,
                binding: InterfaceBinding(name: "nosuch0", fallback: false),
                timeout: .milliseconds(800))
        }
        let elapsed = clock.now - start
        #expect(elapsed >= .milliseconds(500), "gave up without waiting for the interface")
        #expect(elapsed < .seconds(3))
    }

    /// A refusal (a stopped target, a NAS mid-reboot) is the target's answer,
    /// not the interface's: reporting it as "no route" blamed the cable and,
    /// failing instantly, cut a strict pin's recovery window to a quarter.
    @Test("strict: a refused connection is not reported as an interface failure")
    func strictRefusalIsNotAnInterfaceFailure() async {
        do {
            _ = try await NetworkTransport.connect(
                host: "127.0.0.1", port: 1,
                binding: InterfaceBinding(name: "lo0", fallback: false),
                timeout: .milliseconds(500))
            Issue.record("connected to a closed port")
        } catch let TransportError.interfaceUnavailable(name, reason) {
            Issue.record("a refusal was reported as an interface failure: \(name): \(reason)")
        } catch {
            // The deadline, exactly as an unpinned connect to a closed port.
        }
    }

    @Test("prefer: a missing interface falls back to macOS routing and says so")
    func preferMissingInterfaceFallsBack() async throws {
        let server = try MockTargetServer { MockTargetConfig() }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await NetworkTransport.connect(
            host: "127.0.0.1", port: port,
            binding: InterfaceBinding(name: "nosuch0", fallback: true))
        #expect(transport.connectedPath.interfaceName == "lo0")
        #expect(transport.connectedPath.fallback
                == InterfacePinning.Fallback(from: "nosuch0", reason: "it is not present"))
        await transport.close()
    }

    /// Bound to lo0, TEST-NET-1 is unroutable. macOS reports `.waiting`
    /// (EADDRNOTAVAIL) within a millisecond and never `.failed` (measured
    /// 2026-10-02), so without the `.waiting` rule this would sit out the
    /// whole 10 s deadline.
    @Test("strict: an interface with no route to the target fails at once")
    func strictNoRouteFailsFast() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await NetworkTransport.connect(
                host: "192.0.2.1", port: 3260,
                binding: InterfaceBinding(name: "lo0", fallback: false))
            Issue.record("connected through an interface with no route to the target")
        } catch let TransportError.interfaceUnavailable(name, reason) {
            #expect(name == "lo0")
            #expect(reason.contains("no route to 192.0.2.1"))
        }
        #expect(clock.now - start < .seconds(2))
    }
}
#endif
