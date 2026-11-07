import Foundation
import Testing
@testable import iSCSIDaemon
import iSCSIKit
import MockTarget

private actor RemovalGate {
    var entered = false
    var released = false
    func hold() async throws {
        entered = true
        while !released { try await Task.sleep(for: .milliseconds(1)) }
    }
    func waitForEntry() async throws {
        while !entered { try await Task.sleep(for: .milliseconds(1)) }
    }
    func release() { released = true }
}

@Suite(.timeLimit(.minutes(1)))
struct TargetRemovalTests {
    let record = TargetRecord(id: "id", displayName: "NAS", host: "nas", port: 3260,
                              targetIQN: "iqn.2026-08.test.example:disk0", lun: 0)

    @Test func activeSessionBlocksRemovalUntilLogout() async throws {
        let (core, cleanup) = DaemonCoreTests().makeDaemon()
        defer { cleanup() }
        let handle = try await core.login(host: record.host, port: record.port,
                                          targetIQN: record.targetIQN, lun: record.lun)
        await #expect(throws: TargetRemovalError.inUse) {
            try await core.withTargetRemoval(record: record) { Issue.record("Must not delete") }
        }
        try await core.logout(handle)
        try await core.withTargetRemoval(record: record) {}
    }

    @Test func pendingLoginBlocksRemovalAndFailedLoginReleasesReservation() async throws {
        let gate = RemovalGate()
        let core = DaemonCore(initiatorName: "iqn.test:host", unitClaimWait: .milliseconds(200)) { _, _, _ in
            try await gate.hold()
            throw TransportError.connectFailed("test failure")
        }
        let login = Task {
            try await core.login(host: record.host, port: record.port,
                                 targetIQN: record.targetIQN, lun: record.lun)
        }
        try await gate.waitForEntry()
        await #expect(throws: TargetRemovalError.inUse) {
            try await core.withTargetRemoval(record: record) { Issue.record("Must not delete") }
        }
        await gate.release()
        _ = await login.result
        try await core.withTargetRemoval(record: record) {}
    }

    @Test func removalBlocksConcurrentLoginAndRemoval() async throws {
        let gate = RemovalGate()
        let (core, cleanup) = DaemonCoreTests().makeDaemon()
        defer { cleanup() }
        let removal = Task { try await core.withTargetRemoval(record: record) { try await gate.hold() } }
        try await gate.waitForEntry()
        await #expect(throws: TargetRemovalError.beingRemoved) {
            try await core.login(host: record.host, port: record.port,
                                 targetIQN: record.targetIQN, lun: record.lun)
        }
        await #expect(throws: TargetRemovalError.inUse) {
            try await core.withTargetRemoval(record: record) { Issue.record("Must not delete twice") }
        }
        await gate.release()
        try await removal.value
        try await core.withTargetRemoval(record: record) {}
    }

    @Test func changedRecordIsPreservedBeforeCredentialCleanup() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TargetStore(url: url.appendingPathComponent("targets.json"))
        try await store.save(record)
        var changed = record
        changed.displayName = "Edited"
        try await store.save(changed)
        await #expect(throws: TargetRemovalError.changed) {
            try await store.delete(expected: record) { Issue.record("Must not delete credentials") }
        }
        #expect(await store.all() == [changed])
        try await store.delete(expected: changed)
        #expect(await store.all().isEmpty)
    }

    @Test func duplicateNamespacesCanBeDeletedOneAtATime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("targets.json")
        var twin = record
        twin.id = "duplicate"
        try TargetStore.write([record, twin], to: file)
        let store = TargetStore(url: file)
        try await store.delete(expected: record)
        #expect(await store.all() == [twin])
        try await store.delete(expected: twin)
        #expect(await store.all().isEmpty)
    }

    @Test func deletedConfigurationCannotBeUsedByDelayedLogin() async throws {
        let (core, cleanup) = DaemonCoreTests().makeDaemon()
        defer { cleanup() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TargetStore(url: url.appendingPathComponent("targets.json"))
        try await store.save(record)
        try await core.withTargetRemoval(record: record) { try await store.delete(expected: record) }
        await #expect(throws: TargetRemovalError.changed) {
            try await core.login(host: record.host, port: record.port,
                                 targetIQN: record.targetIQN, lun: record.lun,
                                 validateConfiguration: { try await store.validate(record) })
        }
        #expect(await core.sessionHandles().isEmpty)
    }
    @Test func failedDeletionReleasesReservation() async throws {
        let (core, cleanup) = DaemonCoreTests().makeDaemon()
        defer { cleanup() }
        await #expect(throws: TargetRemovalError.changed) {
            try await core.withTargetRemoval(record: record) { throw TargetRemovalError.changed }
        }
        let handle = try await core.login(host: record.host, port: record.port,
                                         targetIQN: record.targetIQN, lun: record.lun)
        try await core.logout(handle)
    }

    @Test func checkedXPCDeletionRejectsBusyAndChangedRecords() async throws {
        let (core, cleanup) = DaemonCoreTests().makeDaemon()
        defer { cleanup() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TargetStore(url: url.appendingPathComponent("targets.json"))
        try await store.save(record)
        let service = ISCSIXPCService(core: core, targets: store)
        let data = try JSONEncoder().encode(record)
        let handle = try await core.login(host: record.host, port: record.port,
                                         targetIQN: record.targetIQN, lun: record.lun)
        let busy: Error? = await withCheckedContinuation { continuation in
            service.deleteTargetIfUnchanged(data) { continuation.resume(returning: $0) }
        }
        #expect(busy != nil)
        #expect(await store.all() == [record])
        try await core.logout(handle)
        var changed = record
        changed.host = "other-nas"
        try await store.save(changed)
        let stale: Error? = await withCheckedContinuation { continuation in
            service.deleteTargetIfUnchanged(data) { continuation.resume(returning: $0) }
        }
        #expect(stale != nil)
        #expect(await store.all() == [changed])
    }

    @Test func accountErasureClearsSharedCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TargetStore(url: url.appendingPathComponent("targets.json"))
        try await store.save(record)
        try await store.removeConfiguration { try FileManager.default.removeItem(at: url) }
        #expect(await store.all().isEmpty)
        await #expect(throws: TargetRemovalError.changed) { try await store.validate(record) }
    }

    @Test func duplicateIDAcrossNamespacesPreservesBothRecordsAndCredentials() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("targets.json")
        var other = record
        other.targetIQN = "nqn.test:other"
        let records = [record, other]
        try TargetStore.write(records, to: file)
        let store = TargetStore(url: file)
        for expected in records {
            await #expect(throws: TargetRemovalError.duplicateID) {
                try await store.delete(expected: expected) { Issue.record("Must not delete credentials") }
            }
        }
        #expect(await store.all() == records)
        #expect(try TargetStore.decode(contentsOf: file) == records)
    }

    @Test func removalWaitsForSlowLogout() async throws {
        var config = MockTargetConfig()
        config.faults.responseDelay = .milliseconds(200)
        let (core, cleanup) = DaemonCoreTests().makeDaemon(config: config, unitClaimWait: .seconds(2))
        defer { cleanup() }
        let handle = try await core.login(host: record.host, port: record.port,
                                         targetIQN: record.targetIQN, lun: record.lun)
        let logout = Task { try await core.logout(handle) }
        // logout removes the registry entry before awaiting the delayed reply.
        while !(await core.sessionHandles()).isEmpty { await Task.yield() }
        try await core.withTargetRemoval(record: record) {}
        try await logout.value
    }

    @Test func removalTimesOutWhileSessionRemainsActive() async throws {
        let wait: Duration = .milliseconds(200)
        let (core, cleanup) = DaemonCoreTests().makeDaemon(unitClaimWait: wait)
        defer { cleanup() }
        let handle = try await core.login(host: record.host, port: record.port,
                                         targetIQN: record.targetIQN, lun: record.lun)
        let started = ContinuousClock.now
        await #expect(throws: TargetRemovalError.inUse) {
            try await core.withTargetRemoval(record: record) { Issue.record("Must not remove active target") }
        }
        #expect(ContinuousClock.now - started >= wait)
        try await core.logout(handle)
        try await core.withTargetRemoval(record: record) {}
    }

    @Test func legacyXPCDeletionRepairsDuplicateIDs() async throws {
        let (core, cleanup) = DaemonCoreTests().makeDaemon()
        defer { cleanup() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("targets.json")
        var other = record
        other.targetIQN = "nqn.test:other"
        var unrelated = record
        unrelated.id = "keep"
        unrelated.targetIQN = "nqn.test:keep"
        try TargetStore.write([record, other, unrelated], to: file)
        let store = TargetStore(url: file)
        let service = ISCSIXPCService(core: core, targets: store)
        let error: Error? = await withCheckedContinuation { continuation in
            service.deleteTarget(id: record.id) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(await store.all() == [unrelated])
    }

    @Test func removalErrorsDescribeTheirOperation() {
        #expect(TargetRemovalError.inUse.localizedDescription.contains("Target"))
        #expect(!TargetRemovalError.inUse.localizedDescription.contains("namespace"))
        #expect(TargetRemovalError.beingRemoved.localizedDescription.contains("cannot log in"))
        #expect(TargetRemovalError.duplicateID.localizedDescription.contains("in the app"))
    }

}
