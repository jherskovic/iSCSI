import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

/// The binding must reach every connect a session makes — the first, both
/// NVMe queues, and each recovery reconnect — or a pin holds until the
/// first dropped connection and then silently stops.
@Suite("Interface binding through the daemon", .timeLimit(.minutes(1)))
struct InterfaceBindingDaemonTests {

    private let pinned = InterfaceBinding(name: "en18", fallback: false)

    @Test("an iSCSI login hands its binding to the transport factory")
    func iscsiLoginCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let handle = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN,
                                          lun: 0, binding: pinned)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == pinned })
        try await core.logout(handle)
    }

    @Test("both NVMe queues are pinned")
    func nvmeQueuesCarryBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let handle = try await core.login(host: "nas", port: 4420, targetIQN: spyNQN,
                                          lun: 1, binding: pinned)
        #expect(log.all.count == 2, "admin queue and I/O queue")
        #expect(log.all.allSatisfy { $0 == pinned })
        try await core.logout(handle)
    }

    @Test("a recovery reconnect is pinned like the first connect")
    func recoveryCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let handle = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN,
                                          lun: 0, binding: pinned)
        let first = try #require(log.transports.first)
        await first.close()
        _ = try await core.read(handle, offset: 0, length: 512)
        #expect(log.all.count >= 2, "the read must have rebuilt the connection")
        #expect(log.all.allSatisfy { $0 == pinned })
    }

    @Test("an unpinned login hands the factory no binding")
    func unpinnedLoginPassesNil() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        _ = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == nil })
    }

    @Test("iSCSI discovery is pinned")
    func discoveryCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        _ = try await core.discover(host: "nas", port: 3260, binding: pinned)
        #expect(log.all.count == 1)
        #expect(log.all.first == pinned)
    }

    /// Whether the mock answers NVMe discovery does not matter here — only
    /// that the connect it attempted was pinned.
    @Test("NVMe discovery is pinned")
    func nvmeDiscoveryCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        _ = try? await core.discoverSubsystems(host: "nas", port: 4420, binding: pinned)
        #expect(log.all.first == pinned)
    }

    @Test("the session list reports the interface and the pin a fallback left")
    func sessionDetailsReportPath() async throws {
        let (core, _, harnesses) = makeSpyCore(path: ConnectedPath(
            interfaceName: "en0",
            fallback: InterfacePinning.Fallback(from: "en18", reason: "it is not present")))
        defer { harnesses.cancelAll() }
        _ = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0,
                                 binding: InterfaceBinding(name: "en18", fallback: true))
        let details = await core.sessionDetails()
        #expect(details.count == 1)
        #expect(details.first?.interfaceName == "en0")
        #expect(details.first?.interfaceFallbackFrom == "en18")
    }
}
