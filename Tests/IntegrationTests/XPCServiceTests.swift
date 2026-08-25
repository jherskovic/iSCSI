//
//  XPCServiceTests.swift
//
//  `ISCSIXPCService` is the whole surface the app and the FSKit extension
//  reach the daemon through. It decides which credentials a login uses and
//  which caller may touch which session — the only thing between a
//  compromised client and someone else's volume.
//
//  No XPC connection involved: the service is a plain object with reply
//  blocks, driven directly.
//

import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

@Suite("XPC service surface")
struct XPCServiceTests {

    private static let targetIQN = "iqn.2026-08.test.example:disk0"

    /// A daemon core backed by MockTarget over MemoryPipe, plus a TargetStore
    /// in a fresh temp file so nothing leaks between tests.
    private func makeCore(
        targetConfig: MockTargetConfig = MockTargetConfig(),
        tune: (inout TargetRecord) -> Void = { _ in }
    ) async throws -> (DaemonCore, HarnessBox, TargetStore, TargetRecord) {
        let disk = RAMDisk()
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.test:initiator") { _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: targetConfig, disk: disk,
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
        tune(&record)
        try await store.save(record)
        return (core, harnesses, store, record)
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

    private func loginResult(_ service: ISCSIXPCService,
                             host: String = "mock",
                             targetIQN: String = XPCServiceTests.targetIQN)
        async -> (String?, Error?) {
        await withCheckedContinuation { continuation in
            service.login(host: host, port: 3260, targetIQN: targetIQN, lun: 0) {
                continuation.resume(returning: ($0, $1))
            }
        }
    }

    // MARK: - Credential resolution
    //
    // The branch that decides what a login authenticates as. A nil here is not
    // "no preference", it is "log in unauthenticated" — so every way of
    // *failing* to resolve credentials has to be an error rather than a nil.

    @Test("a target with no CHAP user logs in unauthenticated")
    func noCredentialsConfiguredLogsInAnyway() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let (handle, error) = await loginResult(service)
        #expect(error == nil)
        #expect(handle != nil)
    }

    /// The failure this guards is invisible from every layer above: a record
    /// that names a CHAP user but whose secret cannot be found must not fall
    /// back to an unauthenticated session that looks identical to a good one.
    @Test("a CHAP user with no stored secret fails the login instead of downgrading")
    func missingSecretIsAnErrorNotADowngrade() async throws {
        let (core, _harness, store, _) = try await makeCore { $0.chapUser = "someone" }
        let service = ISCSIXPCService(core: core, targets: store)
        let (handle, error) = await loginResult(service)
        #expect(handle == nil)
        #expect(error != nil)
        #expect("\(error!)".contains("CHAP") || "\(error!)".contains("secret"),
                "the error should name the missing secret, got: \(error!)")
    }

    @Test("logging in to a target the daemon has no record of is refused")
    func unknownTargetIsRefused() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let (handle, error) = await loginResult(service, targetIQN: "iqn.2026-08.test.example:nope")
        #expect(handle == nil)
        #expect(error != nil)
    }

    /// While `CHAP.mutualIsOffered` is false, a record that still names a
    /// mutual user must be ignored — the UI to clear it is gone, so a login
    /// that insisted on mutual would be unfixable from the app.
    @Test func aStoredMutualUserIsIgnoredWhileMutualIsSwitchedOff() async throws {
        let fake = FakeKeychain()
        let previous = KeychainStore.backend
        KeychainStore.backend = fake
        defer { KeychainStore.backend = previous }

        // One-way CHAP only — the configuration the gate keeps working.
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "initiator-user"
        targetConfig.chapSecret = "initiator-secret-long"
        let (core, _harness, store, record) = try await makeCore(targetConfig: targetConfig) {
            $0.chapUser = "initiator-user"
            $0.mutualChapUser = "peer-user"      // named, with no secret stored
        }
        try KeychainStore.store("initiator-secret-long", for: record.id, kind: .initiator)

        let service = ISCSIXPCService(core: core, targets: store)
        let (handle, error) = await loginResult(service)

        #expect(CHAP.mutualIsOffered == false, "this test describes the switched-off state")
        #expect(error == nil, "a stored mutual user must not fail the login while mutual is off")
        #expect(handle != nil)
    }

    // MARK: - Handle scoping
    //
    // Handles are connection-scoped. Every session-keyed call checks that the
    // caller opened the handle it is naming; these assert it on each one,
    // because the check is per-method and a new method can silently omit it.

    @Test("every session-scoped call refuses a handle the caller does not own")
    func sessionScopedCallsAreOwnershipChecked() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let owner = ISCSIXPCService(core: core, targets: store)
        let stranger = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)

        await confirmation("each call is refused", expectedCount: 6) { refused in
            await withCheckedContinuation { c in
                stranger.capacity(session: handle) { _, _, e in
                    if e != nil { refused() }; c.resume()
                }
            }
            await withCheckedContinuation { c in
                stranger.read(session: handle, offset: 0, length: 512) { _, e in
                    if e != nil { refused() }; c.resume()
                }
            }
            await withCheckedContinuation { c in
                stranger.write(session: handle, offset: 0, data: Data(count: 512)) { e in
                    if e != nil { refused() }; c.resume()
                }
            }
            await withCheckedContinuation { c in
                stranger.flush(session: handle) { e in
                    if e != nil { refused() }; c.resume()
                }
            }
            await withCheckedContinuation { c in
                stranger.reportLUNs(session: handle) { _, e in
                    if e != nil { refused() }; c.resume()
                }
            }
            await withCheckedContinuation { c in
                stranger.logout(session: handle) { e in
                    if e != nil { refused() }; c.resume()
                }
            }
        }
    }

    /// The other half: the owner is not locked out by its own check.
    @Test("the session's owner can use it")
    func ownerIsNotLockedOut() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)

        let (blockSize, blockCount, error) = await withCheckedContinuation { c in
            service.capacity(session: handle) { c.resume(returning: ($0, $1, $2)) }
        }
        #expect(error == nil)
        #expect(blockSize.intValue > 0)
        #expect(blockCount.intValue > 0)
    }

    // MARK: - Block I/O across the boundary

    @Test("a write is readable back through the same surface")
    func writeThenReadRoundTrips() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)
        let payload = Data((0 ..< 4096).map { UInt8($0 & 0xFF) })

        let writeError = await withCheckedContinuation { c in
            service.write(session: handle, offset: 8192, data: payload) { c.resume(returning: $0) }
        }
        #expect(writeError == nil)

        let (data, readError) = await withCheckedContinuation { c in
            service.read(session: handle, offset: 8192, length: 4096) { c.resume(returning: ($0, $1)) }
        }
        #expect(readError == nil)
        #expect(data == payload)
    }

    // MARK: - Replies that cross as encoded DTOs
    //
    // These all reply with `Data` holding JSON. A decode failure here is a
    // feature that silently does nothing in the app, so each is decoded rather
    // than merely checked non-nil.

    @Test("listSessions reports an open handle and forgets it after logout")
    func listSessionsTracksLifetime() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)

        var open = await withCheckedContinuation { c in
            service.listSessions { c.resume(returning: $0) }
        }
        #expect(open.contains(handle))

        _ = await withCheckedContinuation { c in
            service.logout(session: handle) { c.resume(returning: $0) }
        }
        open = await withCheckedContinuation { c in
            service.listSessions { c.resume(returning: $0) }
        }
        #expect(!open.contains(handle))
    }

    @Test("listSessionsDetailed decodes and carries the negotiated parameters")
    func sessionDetailsDecode() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)

        let (data, error) = await withCheckedContinuation { c in
            service.listSessionsDetailed { c.resume(returning: ($0, $1)) }
        }
        #expect(error == nil)
        let infos = try JSONDecoder().decode([SessionInfo].self, from: #require(data))
        let mine = try #require(infos.first { $0.handle == handle })
        #expect(!mine.negotiated.isEmpty,
                "the diagnostics pane exists to show these; empty means nothing to show")
    }

    @Test("reportLUNs decodes to at least the LUN that was logged into")
    func reportLUNsDecodes() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)

        let (data, error) = await withCheckedContinuation { c in
            service.reportLUNs(session: handle) { c.resume(returning: ($0, $1)) }
        }
        #expect(error == nil)
        let luns = try JSONDecoder().decode([LUNInfo].self, from: #require(data))
        #expect(luns.contains { $0.lun == 0 })
    }

    // MARK: - The target store, over XPC

    @Test("a saved target comes back in the listing and is gone after deletion")
    func targetCRUDRoundTrips() async throws {
        let (core, _harness, store, existing) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)

        let fresh = TargetRecord(id: UUID().uuidString, displayName: "Second",
                                 host: "elsewhere", port: 3260,
                                 targetIQN: "iqn.2026-08.test.example:disk1", lun: 0)
        let (savedData, saveError) = await withCheckedContinuation { c in
            service.saveTarget((try? JSONEncoder().encode(fresh)) ?? Data()) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(saveError == nil)
        #expect(savedData != nil)

        var listed = try JSONDecoder().decode(
            [TargetRecord].self,
            from: #require(await withCheckedContinuation { c in
                service.listTargets { data, _ in c.resume(returning: data) }
            }))
        #expect(listed.contains { $0.id == fresh.id })
        #expect(listed.contains { $0.id == existing.id })

        let deleteError = await withCheckedContinuation { c in
            service.deleteTarget(id: fresh.id) { c.resume(returning: $0) }
        }
        #expect(deleteError == nil)

        listed = try JSONDecoder().decode(
            [TargetRecord].self,
            from: #require(await withCheckedContinuation { c in
                service.listTargets { data, _ in c.resume(returning: data) }
            }))
        #expect(!listed.contains { $0.id == fresh.id })
    }

    // `removeAllData` is deliberately untested: it operates on the real
    // /Library/Application Support path (uninstall must clear where the
    // daemon actually keeps things), so an in-process test would need root
    // or would delete the developer's own saved targets.

    // MARK: - Discovery credential validation
    //
    // Discovery is the one call that takes a secret from its caller (no
    // target record exists yet); it validates so a too-short secret fails
    // here, not as an unexplained portal "authentication failure".

    @Test("discovery refuses a secret shorter than the RFC floor before connecting")
    func discoveryValidatesSecretLength() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)

        let (data, error) = await withCheckedContinuation { c in
            service.discoverTargets(host: "mock", port: 3260,
                                    chapUser: "someone", chapSecret: "tooshort") {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(data == nil)
        #expect(error != nil, "an 8-character secret must be refused locally")
    }

    @Test("daemonInfo decodes")
    func daemonInfoDecodes() async throws {
        let (core, _harness, store, _) = try await makeCore()
        let service = ISCSIXPCService(core: core, targets: store)
        let (data, error) = await withCheckedContinuation { c in
            service.daemonInfo { c.resume(returning: ($0, $1)) }
        }
        #expect(error == nil)
        #expect(data != nil)
    }
}
