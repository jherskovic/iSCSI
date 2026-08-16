//
//  FlushPolicyTests.swift
//
//  The durability trade behind docs/open-questions.md item 5: FUA on every
//  write is the default, and the two relaxed modes — periodic SYNCHRONIZE
//  CACHE, or none at all — must still flush on detach, because a detach that
//  abandons acknowledged writes in a volatile cache is silent data loss.
//
//  RAMDisk models the volatile cache honestly: `crash()` is a target power
//  cut, and `blocksLostToCrash` is what it cost.
//

import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIDaemon
@testable import iSCSIKit

@Suite("Integration: flush policy", .timeLimit(.minutes(1)))
struct FlushPolicyTests {

    func makeDaemon(disk: RAMDisk) -> (DaemonCore, @Sendable () -> Void) {
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.2026-08.com.example:daemon") { _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: MockTargetConfig(), disk: disk, transport: targetSide)
            let task = Task { await target.run() }
            harnesses.add(task)
            return initiatorSide
        }
        return (core, { harnesses.cancelAll() })
    }

    private let iqn = "iqn.2026-08.test.example:disk0"
    private let payload = Data(repeating: 0xAB, count: 4096)

    @Test("the default policy writes through: every write carries FUA")
    func defaultIsWriteThrough() async throws {
        let disk = RAMDisk()
        let (core, cleanup) = makeDaemon(disk: disk)
        defer { cleanup() }

        let handle = try await core.login(host: "nas", port: 3260, targetIQN: iqn, lun: 0)
        try await core.write(handle, offset: 0, data: payload)

        #expect(await disk.fuaWrites > 0)
        #expect(await disk.cachedWrites == 0)

        // Nothing in the volatile cache, so a target power cut costs nothing.
        await disk.crash()
        #expect(await disk.blocksLostToCrash == 0)
        try await core.logout(handle)
    }

    @Test("interval mode drops FUA and the timer commits the cache")
    func intervalModeFlushesOnTheTimer() async throws {
        let disk = RAMDisk()
        let (core, cleanup) = makeDaemon(disk: disk)
        defer { cleanup() }

        let handle = try await core.login(host: "nas", port: 3260, targetIQN: iqn, lun: 0,
                                          flushPolicy: .interval(seconds: 1))
        try await core.write(handle, offset: 0, data: payload)

        #expect(await disk.fuaWrites == 0)
        #expect(await disk.cachedWrites > 0)

        // The timer, not the write, is what commits the cache.
        let flushesBefore = await disk.flushCount
        try await Task.sleep(for: .seconds(2))
        #expect(await disk.flushCount > flushesBefore)
        await disk.crash()
        #expect(await disk.blocksLostToCrash == 0)

        // Idle sessions don't keep flushing: with nothing written since the
        // last SYNCHRONIZE CACHE, the tick is skipped.
        let flushesAfterCommit = await disk.flushCount
        try await Task.sleep(for: .seconds(2))
        #expect(await disk.flushCount == flushesAfterCommit)

        try await core.logout(handle)
    }

    @Test("detach flushes whatever the interval timer has not reached yet")
    func intervalModeFlushesOnLogout() async throws {
        let disk = RAMDisk()
        let (core, cleanup) = makeDaemon(disk: disk)
        defer { cleanup() }

        // An interval long enough that the timer cannot fire during the test:
        // the logout is the only thing that can save the cached write.
        let handle = try await core.login(host: "nas", port: 3260, targetIQN: iqn, lun: 0,
                                          flushPolicy: .interval(seconds: 3600))
        try await core.write(handle, offset: 0, data: payload)
        #expect(await disk.cachedWrites > 0)

        try await core.logout(handle)
        #expect(await disk.flushCount > 0)
        await disk.crash()
        #expect(await disk.blocksLostToCrash == 0)
    }

    @Test("never mode issues no periodic flush but still flushes on detach")
    func neverModeFlushesOnlyOnLogout() async throws {
        let disk = RAMDisk()
        let (core, cleanup) = makeDaemon(disk: disk)
        defer { cleanup() }

        let handle = try await core.login(host: "nas", port: 3260, targetIQN: iqn, lun: 0,
                                          flushPolicy: .never)
        try await core.write(handle, offset: 0, data: payload)
        #expect(await disk.fuaWrites == 0)

        try await Task.sleep(for: .seconds(1.5))
        #expect(await disk.flushCount == 0)

        try await core.logout(handle)
        #expect(await disk.flushCount == 1)
        await disk.crash()
        #expect(await disk.blocksLostToCrash == 0)
    }

    /// The setting is stored on the TargetRecord and the daemon resolves the
    /// record itself at login, so this is the wiring that makes the UI's
    /// choice real: a record with a policy must produce a session with it.
    @Test("a record's stored policy reaches the wire through the XPC service")
    func recordPolicyIsHonoredThroughXPC() async throws {
        let disk = RAMDisk()
        let (core, cleanup) = makeDaemon(disk: disk)
        defer { cleanup() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TargetStore(url: url)
        try await store.save(TargetRecord(id: "t1", displayName: "Mock",
                                          host: "mock", port: 3260,
                                          targetIQN: iqn, lun: 0,
                                          flushIntervalSeconds: 0))

        let service = ISCSIXPCService(core: core, targets: store)
        let handle: String = try await withCheckedThrowingContinuation { continuation in
            service.login(host: "mock", port: 3260, targetIQN: iqn, lun: 0) { handle, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: handle!) }
            }
        }
        try await core.write(handle, offset: 0, data: payload)

        // 0 means never: no FUA on the write, and without the record's policy
        // reaching login this would have been a write-through session.
        #expect(await disk.fuaWrites == 0)
        #expect(await disk.cachedWrites > 0)
        try await core.logout(handle)
    }

    @Test("write-through sessions do not grow a flush on logout")
    func writeThroughLogoutDoesNotFlush() async throws {
        let disk = RAMDisk()
        let (core, cleanup) = makeDaemon(disk: disk)
        defer { cleanup() }

        let handle = try await core.login(host: "nas", port: 3260, targetIQN: iqn, lun: 0,
                                          flushPolicy: .writeThrough)
        try await core.write(handle, offset: 0, data: payload)
        try await core.logout(handle)
        // FUA already made every write durable; a logout flush would be a
        // needless round trip against a possibly-dead target.
        #expect(await disk.flushCount == 0)
    }
}
