//
//  HandleScopingTests.swift
//
//  DaemonCore's handle namespace is one flat map of "s1", "s2", … shared by
//  every client. Without per-connection ownership, any connected process could
//  log out, read from, or write to a session it never opened by guessing a
//  two-character string.
//
//  The code-signing requirement keeps strangers out, so this is a correctness
//  bug rather than a way in — but the app and the FSKit extension are both
//  connected at the same time in normal operation, and the extension's session
//  is the one carrying the user's filesystem.
//

import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

@Suite("Per-connection session ownership")
struct HandleScopingTests {

    /// Two services over one core is exactly the shipping arrangement: the
    /// listener delegate builds a fresh ISCSIXPCService per connection, and the
    /// app and the extension each get their own.
    /// Same harness shape as DaemonCoreTests: a MemoryPipe per connection with
    /// a MockTarget on the far end, all sharing one RAMDisk.
    private static let targetIQN = "iqn.2026-08.test.example:disk0"

    /// The daemon now resolves credentials from its own saved records and
    /// refuses portals it has none for, so every service in these tests needs a
    /// store that knows about the mock target. A temp file, not the default
    /// `/Library/Application Support` path.
    private func makeCore() async throws -> (DaemonCore, HarnessBox, TargetStore) {
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
        try await store.save(TargetRecord(id: UUID().uuidString, displayName: "Mock",
                                          host: "mock", port: 3260,
                                          targetIQN: Self.targetIQN, lun: 0))
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

    @Test("a session opened on one connection cannot be logged out from another")
    func logoutIsScoped() async throws {
        let (core, _harness, store) = try await makeCore()
        let owner = ISCSIXPCService(core: core, targets: store)
        let stranger = ISCSIXPCService(core: core, targets: store)

        let handle = try await login(owner)

        let denied: Error? = await withCheckedContinuation { continuation in
            stranger.logout(session: handle) { continuation.resume(returning: $0) }
        }
        let error = try #require(denied as NSError?)
        #expect(error.domain == ISCSIError.domain)

        // And the session is genuinely still alive, not merely reported as an
        // error while being torn down anyway.
        #expect(await core.sessionHandles().contains(handle))
    }

    @Test("a stranger cannot read from a session it did not open")
    func readIsScoped() async throws {
        let (core, _harness, store) = try await makeCore()
        let owner = ISCSIXPCService(core: core, targets: store)
        let stranger = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)

        let result: (Data?, Error?) = await withCheckedContinuation { continuation in
            stranger.read(session: handle, offset: 0, length: 512) {
                continuation.resume(returning: ($0, $1))
            }
        }
        #expect(result.0 == nil)
        #expect(result.1 != nil, "reading someone else's LUN must be refused")
    }

    /// The whole-LUN overwrite. This is the one that made the missing check
    /// worth fixing rather than noting.
    @Test("a stranger cannot write to a session it did not open")
    func writeIsScoped() async throws {
        let (core, _harness, store) = try await makeCore()
        let owner = ISCSIXPCService(core: core, targets: store)
        let stranger = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)

        let denied: Error? = await withCheckedContinuation { continuation in
            stranger.write(session: handle, offset: 0,
                           data: Data(repeating: 0xFF, count: 512)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(denied != nil)
    }

    @Test("the owner can still use its own session")
    func ownerIsUnaffected() async throws {
        let (core, _harness, store) = try await makeCore()
        let owner = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)

        let result: (Data?, Error?) = await withCheckedContinuation { continuation in
            owner.read(session: handle, offset: 0, length: 512) {
                continuation.resume(returning: ($0, $1))
            }
        }
        #expect(result.1 == nil)
        #expect(result.0?.count == 512)
    }

    /// Ownership is released on logout, so a handle cannot be reused after the
    /// session behind it is gone — including by the connection that owned it.
    @Test("ownership does not survive logout")
    func ownershipEndsWithTheSession() async throws {
        let (core, _harness, store) = try await makeCore()
        let owner = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)

        _ = await withCheckedContinuation { continuation in
            owner.logout(session: handle) { continuation.resume(returning: $0) }
        }
        let second: Error? = await withCheckedContinuation { continuation in
            owner.logout(session: handle) { continuation.resume(returning: $0) }
        }
        #expect(second != nil)
    }

    /// Listing stays unscoped on purpose. The Sessions pane should show every
    /// session on the machine — including the extension's, which is the one
    /// actually carrying the volume — and reading a list grants no control.
    @Test("listing sessions is deliberately not scoped")
    func listingShowsEverySession() async throws {
        let (core, _harness, store) = try await makeCore()
        let owner = ISCSIXPCService(core: core, targets: store)
        let observer = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)

        let data: Data? = await withCheckedContinuation { continuation in
            observer.listSessionsDetailed { data, _ in continuation.resume(returning: data) }
        }
        let sessions = try JSONDecoder().decode(
            [SessionInfo].self, from: try #require(data))
        #expect(sessions.contains { $0.handle == handle })
    }
}

/// The design conflict that produced a leak in the field, pinned so it cannot
/// come back: handles are owned by the connection that created them, and the
/// app's client opens a connection per call. A login/logout pair from that
/// client therefore cannot work, and `testConnection` exists because of it.
@Suite("Probing without holding a session")
struct TestConnectionTests {

    private static let probeIQN = "iqn.2026-08.test.example:disk0"

    private func makeCore() -> (DaemonCore, HarnessBox) {
        let disk = RAMDisk()
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.test:initiator") { _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: MockTargetConfig(), disk: disk,
                                    transport: targetSide)
            harnesses.add(Task { await target.run() })
            return initiatorSide
        }
        return (core, harnesses)
    }

    /// A store in a temp directory holding one target, because login and
    /// testConnection now resolve credentials from the daemon's own records and
    /// refuse a portal they have never been told about. Also keeps the tests off
    /// `/Library/Application Support`, which the default initialiser would use.
    private func makeStore(containing record: TargetRecord?) async throws -> (TargetStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        let store = TargetStore(url: url)
        if let record { try await store.save(record) }
        return (store, url.deletingLastPathComponent())
    }

    private func probeRecord() -> TargetRecord {
        TargetRecord(id: UUID().uuidString, displayName: "Probe", host: "mock",
                     port: 3260, targetIQN: Self.probeIQN, lun: 0)
    }

    @Test("testConnection reports geometry and leaves no session behind")
    func probeLeavesNothing() async throws {
        let (core, _harness) = makeCore()
        let (store, dir) = try await makeStore(containing: probeRecord())
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ISCSIXPCService(core: core, targets: store)

        let data: Data? = await withCheckedContinuation { continuation in
            service.testConnection(host: "mock", port: 3260,
                                   targetIQN: Self.probeIQN,
                                   lun: 0) { data, _ in
                continuation.resume(returning: data)
            }
        }
        let info = try JSONDecoder().decode(LUNInfo.self, from: try #require(data))
        #expect(info.blockSize != nil)
        #expect((info.blockCount ?? 0) > 0)

        // The whole point. A probe that leaves a session behind costs the target
        // a connection for every attach, and every failed attempt.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.sessionHandles().isEmpty,
                "testConnection must not leave a session open")
    }

    @Test("a probe against a target that does not exist leaves nothing either")
    func failedProbeLeavesNothing() async throws {
        let (core, _harness) = makeCore()
        var missing = probeRecord()
        missing.targetIQN = "iqn.nope:missing"
        let (store, dir) = try await makeStore(containing: missing)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ISCSIXPCService(core: core, targets: store)

        let error: Error? = await withCheckedContinuation { continuation in
            service.testConnection(host: "mock", port: 3260, targetIQN: "iqn.nope:missing",
                                   lun: 0) { _, error in
                continuation.resume(returning: error)
            }
        }
        #expect(error != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.sessionHandles().isEmpty)
    }

    // MARK: - The authorization the probe and login now share

    @Test("a portal with no saved target is refused before any connection is made")
    func unconfiguredPortalIsRefused() async throws {
        let (core, _harness) = makeCore()
        // A store that knows about one target, asked about a different portal —
        // the shape of `mount iscsi://somewhere-else/...` from a local user.
        let (store, dir) = try await makeStore(containing: probeRecord())
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ISCSIXPCService(core: core, targets: store)

        let error: Error? = await withCheckedContinuation { continuation in
            service.login(host: "attacker.example", port: 3260,
                          targetIQN: Self.probeIQN, lun: 0) { _, error in
                continuation.resume(returning: error)
            }
        }
        #expect(error != nil, "login to an unconfigured portal must fail")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.sessionHandles().isEmpty,
                "and must not have opened a session on the way to failing")
    }

    @Test("a configured target whose CHAP secret is missing fails instead of logging in unauthenticated")
    func missingSecretFailsClosed() async throws {
        let (core, _harness) = makeCore()
        // A CHAP username with no keychain item behind it. This used to resolve
        // to nil credentials, which is not "no preference" but an instruction to
        // offer AuthMethod=None — so the session came up unauthenticated and
        // everything above it reported success.
        var authenticated = probeRecord()
        authenticated.chapUser = "backup"
        let (store, dir) = try await makeStore(containing: authenticated)
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ISCSIXPCService(core: core, targets: store)

        let error: Error? = await withCheckedContinuation { continuation in
            service.login(host: "mock", port: 3260,
                          targetIQN: Self.probeIQN, lun: 0) { _, error in
                continuation.resume(returning: error)
            }
        }
        #expect(error != nil, "a missing secret must fail the login, not downgrade it")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.sessionHandles().isEmpty)
    }
}
