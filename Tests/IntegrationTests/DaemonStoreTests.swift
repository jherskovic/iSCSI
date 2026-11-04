//
//  DaemonStoreTests.swift
//
//  `DaemonStore` is the volume's real data path: every byte a user reads or
//  writes on a mounted LUN goes through it. Pinned here: read-modify-write
//  for sub-block writes on a 4Kn LUN, the chunk cache being patched by
//  writes rather than invalidated, and `ioLock` holding submission order.
//

import Foundation
import Testing
@testable import iSCSIKit
@testable import iSCSIVolume

/// A daemon that keeps the LUN in memory. Only the five calls the mounted data
/// path makes do anything; the rest exist because `ISCSIDaemonProtocol` is
/// `@objc`, so every requirement has to be present.
final class FakeDaemon: NSObject, ISCSIDaemonProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    /// Every read and write in order, for asserting on what actually reached
    /// the "device" rather than on what the caller believed it asked for.
    private(set) var operations: [(kind: String, offset: UInt64, length: Int)] = []
    var flushes = 0
    /// When set, the next write fails — the error path drops the cache overlap.
    var failNextWrite = false
    /// What `localCacheBytes` answers.
    var localCache = 0
    /// false: `localCacheBytes` never replies, like an older daemon that
    /// lacks the selector.
    var answersLocalCache = true
    /// Runs at the start of every write, before it is applied or answered —
    /// for interleaving reads into a write that is on the wire.
    var onWrite: (() -> Void)?
    /// Runs at the start of every read, before it is answered — for holding
    /// reads inside the daemon to see how many can be there at once.
    var onRead: (() -> Void)?

    init(byteCount: Int) { bytes = Data(count: byteCount) }

    var log: [(kind: String, offset: UInt64, length: Int)] {
        lock.lock(); defer { lock.unlock() }
        return operations
    }

    func read(session: String, offset: NSNumber, length: NSNumber,
              reply: @escaping (Data?, Error?) -> Void) {
        onRead?()
        lock.lock()
        let start = offset.uint64Value
        let end = min(start + length.uint64Value, UInt64(bytes.count))
        let slice = start >= UInt64(bytes.count)
            ? Data() : bytes[Int(start) ..< Int(end)]
        operations.append(("read", start, Int(end - start)))
        lock.unlock()
        reply(Data(slice), nil)
    }

    func write(session: String, offset: NSNumber, data: Data,
               reply: @escaping (Error?) -> Void) {
        onWrite?()
        lock.lock()
        if failNextWrite {
            failNextWrite = false
            lock.unlock()
            reply(POSIXError(.EIO))
            return
        }
        let start = Int(offset.uint64Value)
        if start + data.count <= bytes.count {
            bytes.replaceSubrange(start ..< (start + data.count), with: data)
        }
        operations.append(("write", offset.uint64Value, data.count))
        lock.unlock()
        reply(nil)
    }

    func flush(session: String, reply: @escaping (Error?) -> Void) {
        lock.lock(); flushes += 1; lock.unlock()
        reply(nil)
    }

    func logout(session: String, reply: @escaping (Error?) -> Void) { reply(nil) }

    func readaheadBudget(session: String, reply: @escaping (NSNumber, Error?) -> Void) {
        reply(0, nil)
    }

    func localCacheBytes(session: String, reply: @escaping (NSNumber, Error?) -> Void) {
        guard answersLocalCache else { return }
        reply(NSNumber(value: localCache), nil)
    }

    /// Contents of the LUN, for comparing against what was written.
    func contents(at offset: Int, length: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        return Data(bytes[offset ..< min(offset + length, bytes.count)])
    }

    // MARK: - Unused requirements

    func login(host: String, port: NSNumber, targetIQN: String, lun: NSNumber,
               reply: @escaping (String?, Error?) -> Void) { reply(nil, nil) }
    func discover(host: String, port: NSNumber, reply: @escaping ([String]?, Error?) -> Void) { reply(nil, nil) }
    func capacity(session: String, reply: @escaping (NSNumber, NSNumber, Error?) -> Void) { reply(0, 0, nil) }
    func listSessions(reply: @escaping ([String]) -> Void) { reply([]) }
    func daemonInfo(reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func refreshFSKitEnablement(reply: @escaping (Error?) -> Void) { reply(nil) }
    func listTargets(reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func saveTarget(_ record: Data, reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func deleteTarget(id: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func setCHAPSecret(targetID: String, secret: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func deleteCHAPSecret(targetID: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func hasCHAPSecret(targetID: String, reply: @escaping (Bool) -> Void) { reply(false) }
    func setMutualCHAPSecret(targetID: String, secret: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func deleteMutualCHAPSecret(targetID: String, reply: @escaping (Error?) -> Void) { reply(nil) }
    func hasMutualCHAPSecret(targetID: String, reply: @escaping (Bool) -> Void) { reply(false) }
    func discoverSubsystems(host: String, port: NSNumber, interfaceName: String?,
                            interfaceFallback: Bool, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, nil)
    }

    func reportLUNs(session: String, reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func listSessionsDetailed(reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func removeAllData(reply: @escaping (Error?) -> Void) { reply(nil) }
    func otherAccountsWithData(reply: @escaping (NSNumber) -> Void) { reply(0) }
    func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                         chapSecret: String?, interfaceName: String?, interfaceFallback: Bool,
                         reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func testConnection(host: String, port: NSNumber, targetIQN: String, lun: NSNumber,
                        reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func listUnits(host: String, port: NSNumber, targetIQN: String,
                   chapUser: String?, chapSecret: String?,
                   interfaceName: String?, interfaceFallback: Bool,
                   reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
}

@Suite("Volume data path")
struct DaemonStoreTests {

    private static let blockSize: UInt64 = 4096
    private static let capacity = 8 << 20        // 8 MiB

    private func makeStore() -> (DaemonStore, FakeDaemon) {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        let store = DaemonStore(daemon: daemon, session: "s1",
                                blockSize: Self.blockSize,
                                byteCount: UInt64(Self.capacity))
        return (store, daemon)
    }

    private func read(_ store: DaemonStore, at offset: UInt64, length: Int) throws -> Data {
        var out = Data(count: length)
        let got: Int = try out.withUnsafeMutableBytes { raw in
            try store.read(into: raw, at: offset, length: length)
        }
        return out.prefix(got)
    }

    @Test func awholeBlockWriteReadsBack() throws {
        let (store, daemon) = makeStore()
        let payload = Data((0 ..< 4096).map { UInt8($0 & 0xFF) })

        _ = try store.write(payload, at: 8192)
        #expect(daemon.contents(at: 8192, length: 4096) == payload)
        #expect(try read(store, at: 8192, length: 4096) == payload)
    }

    /// The case the whole aligner exists for. DiskImages reads and writes the
    /// backing file at 512-byte granularity, and the LUN is 4Kn, so a partial
    /// write has to become read-modify-write — and the bytes *around* the
    /// written range must survive it untouched.
    @Test func aPartialWriteBecomesReadModifyWriteAndPreservesItsNeighbours() throws {
        let (store, daemon) = makeStore()
        let original = Data((0 ..< 4096).map { UInt8(($0 &* 7) & 0xFF) })
        _ = try store.write(original, at: 4096)

        // 512 bytes into the middle of that block.
        let patch = Data(repeating: 0xEE, count: 512)
        _ = try store.write(patch, at: 4096 + 1024)

        let after = daemon.contents(at: 4096, length: 4096)
        #expect(after[1024 ..< 1536] == patch, "the written range must land")
        #expect(after[0 ..< 1024] == original[0 ..< 1024], "bytes before it must survive")
        #expect(after[1536 ..< 4096] == original[1536 ..< 4096], "and bytes after it")

        // The device only ever saw whole blocks, whatever the caller asked for.
        for op in daemon.log where op.kind == "write" {
            #expect(op.offset % Self.blockSize == 0, "unaligned write reached the device")
            #expect(op.length % Int(Self.blockSize) == 0, "partial-block write reached the device")
        }
    }

    /// Writes patch the cached chunks rather than dropping them. A guest's
    /// journal is written and re-read thousands of times per boot; invalidating
    /// on write would turn each of those into a 256 KiB refetch.
    @Test func aWriteIsVisibleToTheNextReadWithoutRefetching() throws {
        let (store, daemon) = makeStore()
        _ = try read(store, at: 0, length: 4096)          // populate the cache
        let readsBefore = daemon.log.filter { $0.kind == "read" }.count

        let payload = Data(repeating: 0x5A, count: 4096)
        _ = try store.write(payload, at: 0)
        #expect(try read(store, at: 0, length: 4096) == payload,
                "the read after a write must see the written bytes")

        let readsAfter = daemon.log.filter { $0.kind == "read" }.count
        #expect(readsAfter == readsBefore,
                "the read-back refetched from the device instead of using the patched chunk")
    }

    /// When a write fails, which blocks reached the medium is unknowable, so
    /// the overlapping cache must be dropped rather than patched. Serving
    /// patched bytes for a write that never landed would hand the filesystem
    /// data the device does not have.
    @Test func aFailedWriteDoesNotLeavePatchedBytesInTheCache() throws {
        let (store, daemon) = makeStore()
        let original = Data(repeating: 0x11, count: 4096)
        _ = try store.write(original, at: 0)
        _ = try read(store, at: 0, length: 4096)          // cache it

        daemon.failNextWrite = true
        #expect(throws: (any Error).self) {
            _ = try store.write(Data(repeating: 0x99, count: 4096), at: 0)
        }

        #expect(try read(store, at: 0, length: 4096) == original,
                "the cache served bytes from a write that failed")
    }

    /// Overlapping writes must reach the device in submission order: the
    /// kernel rewrites the same block back-to-back and trusts device order
    /// (violations are nondeterministic corruption — docs/architecture.md).
    @Test func overlappingWritesReachTheDeviceInOrder() throws {
        let (store, _daemon) = makeStore()
        for generation in UInt8(1) ... UInt8(24) {
            _ = try store.write(Data(repeating: generation, count: 4096), at: 4096)
        }
        #expect(try read(store, at: 4096, length: 4096) == Data(repeating: 24, count: 4096))
    }

    @Test func flushReachesTheDaemon() throws {
        let (store, daemon) = makeStore()
        try store.flush()
        #expect(daemon.flushes == 1)
    }

    @Test func readsPastTheEndOfTheDeviceReturnNothing() throws {
        let (store, _daemon) = makeStore()
        #expect(try read(store, at: UInt64(Self.capacity), length: 4096).isEmpty)
    }

    /// A write at least as slow as the threshold is counted, and the longest
    /// is kept, so the summary says whether any write came near the 10 s a
    /// guest's disk timeout allows (docs/open-questions.md item 17). Wide
    /// margins: a fake-daemon write takes microseconds, and CI runs this on a
    /// saturated three-core runner.
    /// A slow read is counted where it was slow. Here the daemon is: the
    /// store's timing, its daemon round trip and the handler's report all see
    /// it. A read held up before the store (handler only) is counted only by
    /// the handler, which is how a stall above the store shows itself.
    @Test func aSlowReadIsCountedWhereItWasSlow() throws {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        let store = DaemonStore(daemon: daemon, session: "s1", blockSize: Self.blockSize,
                                byteCount: UInt64(Self.capacity), readaheadBudgetBytes: 0,
                                slowIOThreshold: 0.1)
        var buf = [UInt8](repeating: 0, count: 4096)
        _ = try buf.withUnsafeMutableBytes { try store.read(into: $0, at: 0, length: 4096) }
        #expect(store.slowReads == 0)

        daemon.onRead = { Thread.sleep(forTimeInterval: 0.25) }
        _ = try buf.withUnsafeMutableBytes { try store.read(into: $0, at: 1 << 20, length: 4096) }
        #expect(store.slowReads == 1)
        #expect(store.longestReadNanos >= 250_000_000)
        #expect(store.longestFetchNanos >= 250_000_000)

        // The handler's own report: only it saw this one.
        store.noteServedRead(offset: 0, length: 4096, queuedNanos: 150_000_000, totalNanos: 300_000_000)
        #expect(store.slowServedReads == 1)
        #expect(store.slowReads == 1)
        #expect(store.longestServedReadNanos == 300_000_000)
        #expect(store.summary.contains("slowReads=1/1 "))
    }

    @Test func aSlowWriteIsCountedAndTheLongestKept() throws {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        let store = DaemonStore(daemon: daemon, session: "s1", blockSize: Self.blockSize,
                                byteCount: UInt64(Self.capacity), slowIOThreshold: 0.1)
        _ = try store.write(Data(repeating: 1, count: 4096), at: 0)
        #expect(store.slowWrites == 0)

        daemon.onWrite = { Thread.sleep(forTimeInterval: 0.25) }
        _ = try store.write(Data(repeating: 2, count: 4096), at: 4096)
        #expect(store.slowWrites == 1)
        #expect(store.longestWriteNanos >= 250_000_000)
        #expect(store.summary.contains("slowWrites=1 "))
        #expect(daemon.contents(at: 4096, length: 4096) == Data(repeating: 2, count: 4096))
    }

    /// Issue #4 measured QD16 no faster than QD1 through a mount. This pins
    /// that the store and the cache under it are not why: eight readers on
    /// eight different chunks are all held inside the daemon until the eighth
    /// arrives. A store that serialised them would let one in at a time, each
    /// would give up waiting, and the peaks would read 1.
    ///
    /// Threads, not `concurrentPerform`: that runs as many iterations at once
    /// as there are cores, and CI has three.
    @Test func readsOnDifferentChunksAreInsideTheDaemonAtOnce() throws {
        let (store, daemon) = makeStore()
        let readers = 8
        let gate = Rendezvous(parties: readers)
        daemon.onRead = { gate.arriveAndWait(timeout: 5) }

        let box = StoreBox(store)
        let finished = DispatchGroup()
        for i in 0 ..< readers {
            finished.enter()
            Thread {
                var out = Data(count: 4096)
                _ = try? out.withUnsafeMutableBytes { raw in
                    // 256 KiB apart: one chunk each, so no reader can be
                    // answered by another's fetch.
                    try box.store.read(into: raw, at: UInt64(i) << 18, length: 4096)
                }
                finished.leave()
            }.start()
        }
        #expect(finished.wait(timeout: .now() + 30) == .success)
        #expect(!gate.timedOut, "a reader waited alone: the store let reads in one at a time")
        #expect(store.readsInFlight.peak == readers)
        #expect(store.fetchesInFlight.peak == readers)
        #expect(store.readsInFlight.current == 0)
        #expect(store.summary.contains("inflight=\(readers)/\(readers) "))
    }
}

/// Holds every caller until `parties` have arrived, or until each one's
/// timeout; records whether anyone gave up.
private final class Rendezvous: @unchecked Sendable {
    private let parties: Int
    private let lock = NSLock()
    private var arrived = 0
    private var gaveUp = false
    private let open = DispatchSemaphore(value: 0)

    init(parties: Int) { self.parties = parties }

    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return gaveUp }

    func arriveAndWait(timeout seconds: Double) {
        lock.lock()
        arrived += 1
        let last = arrived == parties
        lock.unlock()
        if last {
            for _ in 0 ..< parties { open.signal() }
        }
        if open.wait(timeout: .now() + seconds) == .timedOut {
            lock.lock(); gaveUp = true; lock.unlock()
        }
    }
}

/// `DaemonStore` is not `Sendable`; the test hands it to its threads anyway,
/// which is what FSKit does.
private struct StoreBox: @unchecked Sendable {
    let store: DaemonStore
    init(_ store: DaemonStore) { self.store = store }
}
