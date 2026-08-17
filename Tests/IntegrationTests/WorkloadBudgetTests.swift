//
//  WorkloadBudgetTests.swift
//
//  The readahead budget is the one piece of per-target policy that the daemon
//  cannot apply itself. Flushing is a wire behaviour, so `FlushPolicy` is read
//  at login and acted on inside the daemon; readahead lives in the FSKit
//  extension, which builds its `ReadaheadPolicy` before it has ever seen a
//  TargetRecord. So the budget has to travel back over XPC, and these tests
//  cover that trip: the right number when a record pins one, 0 when it does
//  not — the normal case, meaning the extension's depth controller decides —
//  and the same ownership check every other session-scoped call has.
//

import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

@Suite("Per-target readahead budget over XPC")
struct WorkloadBudgetTests {

    private static let targetIQN = "iqn.2026-08.test.example:disk0"

    /// Same harness shape as HandleScopingTests: a MemoryPipe per connection
    /// with a MockTarget on the far end, and a TargetStore in a temp file so
    /// the daemon can resolve the portal it is asked for.
    private func makeCore(profile: String?) async throws
        -> (DaemonCore, HarnessBox, TargetStore) {
        let disk = RAMDisk()
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.test:initiator") { _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: MockTargetConfig(), disk: disk,
                                    transport: targetSide)
            harnesses.add(Task { await target.run() })
            return initiatorSide
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        let store = TargetStore(url: url)
        var record = TargetRecord(id: UUID().uuidString, displayName: "Mock",
                                  host: "mock", port: 3260,
                                  targetIQN: Self.targetIQN, lun: 0)
        record.workloadProfile = profile
        try await store.save(record)
        return (core, harnesses, store)
    }

    private func login(_ service: ISCSIXPCService) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            service.login(host: "mock", port: 3260, targetIQN: Self.targetIQN,
                          lun: 0) { handle, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: handle!) }
            }
        }
    }

    private func budget(_ service: ISCSIXPCService,
                        session: String) async -> (NSNumber, Error?) {
        await withCheckedContinuation { continuation in
            service.readaheadBudget(session: session) {
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    @Test("a sequential target reports the 4 MiB budget")
    func sequentialProfileReportsItsBudget() async throws {
        let (core, _harness, store) = try await makeCore(profile: "sequential")
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)

        let (bytes, error) = await budget(service, session: handle)
        #expect(error == nil)
        #expect(bytes.intValue == 4 << 20)
    }

    @Test("a random-access target reports the 512 KiB budget")
    func randomProfileReportsItsBudget() async throws {
        let (core, _harness, store) = try await makeCore(profile: "random")
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)

        let (bytes, error) = await budget(service, session: handle)
        #expect(error == nil)
        #expect(bytes.intValue == 512 << 10)
    }

    /// The normal case now: no profile pinned, so the daemon reports 0 and the
    /// extension lets `ReadaheadDepthController` choose the depth from measured
    /// waste instead.
    @Test("a target with no saved profile reports no pinned budget")
    func absentProfileReportsNoPinnedBudget() async throws {
        let (core, _harness, store) = try await makeCore(profile: nil)
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)

        let (bytes, error) = await budget(service, session: handle)
        #expect(error == nil)
        #expect(bytes.intValue == 0, "0 means nothing is pinned — adapt")
    }

    /// Same scoping every other session-keyed call has. A stranger asking about
    /// a handle it does not own learns nothing about that target's settings.
    @Test("a stranger cannot read the budget of a session it did not open")
    func budgetIsScoped() async throws {
        let (core, _harness, store) = try await makeCore(profile: "sequential")
        let owner = ISCSIXPCService(core: core, targets: store)
        let stranger = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)

        let (_, error) = await budget(stranger, session: handle)
        #expect(error != nil, "reading someone else's target policy must be refused")
    }
}
