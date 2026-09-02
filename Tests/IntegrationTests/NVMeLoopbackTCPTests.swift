#if canImport(Network)
import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// End-to-end over a real loopback TCP socket, exercising `NetworkTransport`
/// (the code path used against the NAS) with both digests on, through the
/// same listener the simulator uses.
@Suite("Integration: NVMe/TCP over real TCP loopback", .timeLimit(.minutes(1)))
struct NVMeLoopbackTCPTests {
    @Test func attachWriteFlushReadOverTCP() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 2048)
        var config = MockNVMeConfig()
        config.discoveryEntries = [(subnqn: config.subsystemNQN, traddr: "127.0.0.1", trsvcid: "0")]
        let subsystem = MockNVMeSubsystem(config: config, disk: disk)
        let server = try MockTargetServer { await subsystem.serve($0) }
        let port = try await server.start()

        let found = try await NVMeDiscovery.getLogPage(
            transport: try await NetworkTransport.connect(host: "127.0.0.1", port: port), host: testHost)
        #expect(found.map(\.name) == [config.subsystemNQN])

        let controller = NVMeController(config: testControllerConfig(), policy: testPolicy()) {
            try await NetworkTransport.connect(host: "127.0.0.1", port: port)
        }
        try await controller.activate()
        #expect(await controller.digests == NVMeTCPDigests(header: true, data: true))
        let device = NVMeBlockDevice(controller: controller, nsid: 1)
        #expect(try await device.readCapacity().blockCount == 2048)

        let payload = Data((0 ..< 65536).map { UInt8(($0 &* 41) & 0xFF) })
        try await device.write(offset: 4096, data: payload)
        try await device.flush()
        #expect(await disk.flushCount == 1)
        #expect(try await device.read(offset: 4096, length: 65536) == payload)

        try await controller.logout()
        await server.stop()
    }
}
#endif
