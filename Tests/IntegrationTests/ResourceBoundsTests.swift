//
//  ResourceBoundsTests.swift
//
//  Tests that assert a property of the *process* rather than of the output.
//
//  This category exists because the two worst bugs found in this codebase were
//  both invisible to every other kind of test. The PDU deframer retained every
//  byte a connection ever received and grew a daemon to 37 GB; its lines ran
//  constantly and every PDU it produced was correct. `KeychainStore` wrote to a
//  keychain a system-domain daemon cannot reach, and returned without error.
//  Neither was an unexecuted branch or a wrong value — both were resources that
//  went one way and never came back.
//
//  `FramerMemoryTests` is the same idea one layer down. These cover the places
//  in the session and cache layers where the same shape could appear: things
//  that hold bytes, in a loop, for the lifetime of a connection.
//
//  Thresholds are set with wide headroom over the measured steady state, so a
//  failure means a real change in behaviour rather than allocator noise. Each
//  measurement warms up first, because the one-time cost of establishing a
//  working set is not what is being asked about.
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

    /// `PrefetchChunkCache` is handed a byte budget and evicts the coldest
    /// ready chunk to stay inside it — but `evictLocked` deliberately never
    /// evicts a *pending* chunk, on the grounds that those represent traffic
    /// already on the wire. That exception is the shape worth pinning: if
    /// pending chunks could accumulate faster than they resolve, the budget
    /// would stop being a bound at all.
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

        // Stream the whole 512 MiB range. Sixty-four times the cache's budget
        // passes through it; nothing may stick.
        var offset: UInt64 = 0
        while offset + UInt64(chunk) <= capacity {
            _ = try cache.read(offset: offset, length: chunk)
            offset += UInt64(chunk)
        }
        let grew = footprint() &- before

        #expect(grew < UInt64(maxCached) * 4,
                "512 MiB streamed through an 8 MiB cache grew the process by \(mib(grew)) MiB")
    }

    /// Writes patch cached chunks rather than invalidating them, which is what
    /// keeps a guest's write-then-read-back a hit. The patching path allocates
    /// too, so it gets the same question asked of it.
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

    /// Every command allocates: a task record, a read buffer sized to the
    /// expected transfer, and entries in the connection's pending maps. All of
    /// them are supposed to be released on completion. A thousand round trips
    /// is enough that a per-operation leak of even a few KiB would show.
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

    /// A dropped connection abandons whatever was in flight. The failure path
    /// has to release those buffers too — a connection that leaks its pending
    /// state on every drop would bleed across an unstable link, which is
    /// exactly when it can least afford to.
    @Test func abandonedCommandsAreReleasedOnDrop() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 8192)

        // Two cycles first, so the working set is established before measuring.
        var baseline: UInt64 = 0
        for round in 0 ..< 12 {
            var config = MockTargetConfig()
            config.faults.stallCommands = true
            let harness = TargetHarness.start(config: config, disk: disk)
            let session = ISCSISession(login: standardLogin(), policy: testPolicy(),
                                       transportFactory: { harness.transport })
            try await session.activate()
            let device = ISCSIBlockDevice(session: session, lun: 0, maxTransferBytes: 64 << 10)

            // Issue reads that will never be answered, then tear the session down.
            let reader = Task { try await device.read(offset: 0, length: 64 << 10) }
            try? await Task.sleep(for: .milliseconds(20))
            reader.cancel()
            try? await session.logout()
            harness.serveTask.cancel()

            if round == 1 { baseline = footprint() }
        }
        let grew = footprint() &- baseline

        #expect(grew < 32 << 20,
                "ten sessions dropped with I/O in flight grew the process by \(mib(grew)) MiB")
    }

    // MARK: - A large write costs a window, not a request

    /// The chunks of one write are issued together rather than one round trip
    /// at a time, and each one holds a copy of its slice until it completes.
    /// What bounds that today is the CmdSN window, which is incidental — no
    /// code says so and nothing asserts it. If the bound were ever the request
    /// size instead, a large file copy would cost memory equal to the file.
    @Test func aLargeWriteCostsAWindowNotTheWholeRequest() async throws {
        let disk = RAMDisk(blockSize: 512, capacityBlocks: 300_000)
        let harness = TargetHarness.start(disk: disk)
        defer { harness.serveTask.cancel() }
        let session = ISCSISession(login: standardLogin(), policy: testPolicy(),
                                   transportFactory: { harness.transport })
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: 0, maxTransferBytes: 256 << 10)

        // Warm up with the *same* write. Everything downstream that grows with
        // bytes written — the RAM disk behind MockTarget, the MemoryPipe, the
        // payload itself — is charged before the baseline, so what is left is
        // the initiator's own per-request overhead, which is the question.
        let payload = Data(repeating: 0x5A, count: 64 << 20)   // 64 MiB, 256 chunks
        try await device.write(offset: 0, data: payload)
        let before = footprint()

        try await device.write(offset: 0, data: payload)
        let grew = footprint() &- before

        // Measured both ways when this was written: 7 MiB with the fan-out
        // bounded to `maxChunksInFlight`, 34 MiB without. 16 MiB sits with
        // roughly the same headroom on each side, so this fails on a real
        // change rather than on allocator noise.
        #expect(grew < 16 << 20,
                "a 64 MiB write grew the process by \(mib(grew)) MiB beyond its payload")
    }
}
