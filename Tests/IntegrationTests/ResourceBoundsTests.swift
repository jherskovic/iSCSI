//
//  ResourceBoundsTests.swift
//
//  Tests that assert a property of the *process* rather than of the output:
//  the worst bugs here were resources flowing one way with every output
//  correct (the deframer's 37 GB retention, KeychainStore's silent no-op).
//  Thresholds carry wide headroom over the measured steady state, and each
//  measurement warms up first, so a failure means behaviour changed.
//

import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

@Suite("Resource bounds", .timeLimit(.minutes(2)))
struct ResourceBoundsTests {

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private func mib(_ bytes: UInt64) -> UInt64 { bytes / (1 << 20) }

    // MARK: - The cache honours its cap

    /// `evictLocked` never evicts a *pending* chunk (traffic already on the
    /// wire); if pending chunks accumulated faster than they resolve, the
    /// byte budget would stop being a bound at all.
    @Test func cacheStaysInsideItsByteBudget() throws {
        let chunk = 256 << 10
        let maxCached = 8 << 20                 // 8 MiB budget
        let capacity: UInt64 = 512 << 20        // a 512 MiB "LUN"
        let cache = PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: capacity,
            maxCachedBytes: maxCached,
            policy: ReadaheadPolicy(budgetBytes: 4 << 20, maxSlots: 32,
                                    minStreamBytes: 1 << 20, chunkBytes: chunk),
            timeout: 5,
            fetchSync: { _, length in Data(repeating: 0xAB, count: length) },
            fetchAsync: { _, length, done in done(Data(repeating: 0xAB, count: length)) }
        )

        // Warm up: establish the working set before measuring.
        for i in 0 ..< 64 {
            _ = try cache.read(offset: UInt64(i) * UInt64(chunk), length: chunk)
        }
        let before = footprint()

        // Stream 64× the cache's budget through it; nothing may stick.
        var offset: UInt64 = 0
        while offset + UInt64(chunk) <= capacity {
            _ = try cache.read(offset: offset, length: chunk)
            offset += UInt64(chunk)
        }
        let grew = footprint() &- before

        #expect(grew < UInt64(maxCached) * 4,
                "512 MiB streamed through an 8 MiB cache grew the process by \(mib(grew)) MiB")
    }

    /// Writes patch cached chunks rather than invalidating them; the patching
    /// path allocates too, so it gets the same question.
    @Test func writeThroughPatchingDoesNotAccumulate() throws {
        let chunk = 256 << 10
        let capacity: UInt64 = 64 << 20
        let cache = PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: capacity,
            maxCachedBytes: 8 << 20,
            policy: ReadaheadPolicy(budgetBytes: 4 << 20, maxSlots: 32,
                                    minStreamBytes: 1 << 20, chunkBytes: chunk),
            timeout: 5,
            fetchSync: { _, length in Data(repeating: 0xAB, count: length) },
            fetchAsync: { _, length, done in done(Data(repeating: 0xAB, count: length)) }
        )
        let payload = Data(repeating: 0xCD, count: 64 << 10)

        for i in 0 ..< 32 {
            _ = try cache.read(offset: UInt64(i) * UInt64(chunk), length: chunk)
        }
        let before = footprint()

        // 4096 write cycles over the same region — the journal pattern.
        for i in 0 ..< 4096 {
            let offset = UInt64((i % 256) * (64 << 10))
            cache.willWrite(offset: offset, length: payload.count)
            cache.didWrite(payload, at: offset)
        }
        let grew = footprint() &- before

        #expect(grew < 32 << 20,
                "4096 write-through cycles grew the process by \(mib(grew)) MiB")
    }

    // MARK: - The session does not accumulate per operation

    /// Every command allocates a task record, read buffer, and pending-map
    /// entries; a thousand round trips would expose a per-operation leak.
    @Test func completedCommandsLeaveNothingBehind() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 8192)
        let harness = TargetHarness.start(disk: disk)
        defer { harness.serveTask.cancel() }
        let session = ISCSISession(login: standardLogin(), policy: testPolicy(),
                                   transportFactory: { harness.transport })
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: 0, maxTransferBytes: 64 << 10)

        for _ in 0 ..< 100 { _ = try await device.read(offset: 0, length: 4096) }
        let before = footprint()

        for i in 0 ..< 1000 {
            let offset = UInt64((i % 64) * 4096)
            _ = try await device.read(offset: offset, length: 4096)
            try await device.write(offset: offset, data: Data(repeating: 0xEE, count: 4096))
        }
        let grew = footprint() &- before

        #expect(grew < 32 << 20,
                "2000 completed commands grew the process by \(mib(grew)) MiB")
    }

    // No leak-on-drop test here: the leak would be ~64 KiB per cycle, inside
    // the noise of a shared test process, and detecting it honestly needs a
    // dedicated process. Don't re-add it as a footprint assertion.

    // A large write's fan-out bound is asserted in
    // `WriteConcurrencyTests.aLargeWriteKeepsOnlyAWindowInFlight` by counting
    // commands against a stalled target — exact, unlike process footprint
    // measured after three hundred other tests.
}
