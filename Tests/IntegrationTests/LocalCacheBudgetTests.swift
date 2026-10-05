import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

/// The cache size reaches the extension the way the readahead budget does:
/// resolved from the record at login, keyed by the session handle, and only
/// for the connection that owns it.
@Suite("Per-target local cache size over XPC")
struct LocalCacheBudgetTests {

    private static let targetIQN = "iqn.2026-08.test.example:disk0"

    private func makeService(cacheGB: Int?) async throws -> (DaemonCore, HarnessBox, TargetStore) {
        let disk = RAMDisk()
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.test:initiator") { _, _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: MockTargetConfig(), disk: disk, transport: targetSide)
            harnesses.add(Task { await target.run() })
            return initiatorSide
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        let store = TargetStore(url: url)
        try await store.save(TargetRecord(id: UUID().uuidString, displayName: "Mock",
                                          host: "mock", port: 3260,
                                          targetIQN: Self.targetIQN, lun: 0,
                                          localCacheGB: cacheGB))
        return (core, harnesses, store)
    }

    private func login(_ service: ISCSIXPCService) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            service.login(host: "mock", port: 3260, targetIQN: Self.targetIQN, lun: 0) { h, e in
                if let e { c.resume(throwing: e) } else { c.resume(returning: h!) }
            }
        }
    }

    private func cacheBytes(_ service: ISCSIXPCService, session: String) async -> (NSNumber, Error?) {
        await withCheckedContinuation { c in
            service.localCacheBytes(session: session) { c.resume(returning: ($0, $1)) }
        }
    }

    @Test("a target set to 4 GB reports 4 GiB")
    func configuredSizeIsReported() async throws {
        let (core, _harness, store) = try await makeService(cacheGB: 4)
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)
        let (bytes, error) = await cacheBytes(service, session: handle)
        #expect(error == nil)
        #expect(bytes.intValue == 4 << 30)
    }

    @Test("a target with no cache setting reports 0")
    func unsetIsZero() async throws {
        let (core, _harness, store) = try await makeService(cacheGB: nil)
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)
        let (bytes, error) = await cacheBytes(service, session: handle)
        #expect(error == nil)
        #expect(bytes.intValue == 0)
    }

    @Test("a stranger cannot read the cache size of a session it did not open")
    func scoped() async throws {
        let (core, _harness, store) = try await makeService(cacheGB: 4)
        let owner = ISCSIXPCService(core: core, targets: store)
        let stranger = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)
        let (_, error) = await cacheBytes(stranger, session: handle)
        #expect(error != nil)
    }
}
