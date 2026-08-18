//
//  DaemonStoreTests.swift
//
//  `DaemonStore` is the volume's real data path: every byte a user reads or
//  writes on a mounted LUN goes through it. It had never been tested, because
//  its initialiser opened its own `NSXPCConnection` to a privileged mach
//  service — so reaching it required a running daemon, a target, and a mount.
//
//  With the daemon injectable, the parts worth pinning become reachable: the
//  read-modify-write path that turns a 512-byte write against a 4Kn LUN into a
//  read, a patch and a whole-block write; the chunk cache being patched by
//  writes rather than invalidated by them, which is what keeps a guest's
//  journal a cache hit instead of a refetch; and `ioLock` holding submission
//  order, because the kernel rewrites the same block back-to-back and trusts
//  device-order semantics.
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

    init(byteCount: Int) { bytes = Data(count: byteCount) }

    var log: [(kind: String, offset: UInt64, length: Int)] {
        lock.lock(); defer { lock.unlock() }
        return operations
    }

    func read(session: String, offset: NSNumber, length: NSNumber,
              reply: @escaping (Data?, Error?) -> Void) {
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
    func reportLUNs(session: String, reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func listSessionsDetailed(reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func removeAllData(reply: @escaping (Error?) -> Void) { reply(nil) }
    func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                         chapSecret: String?, reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
    func testConnection(host: String, port: NSNumber, targetIQN: String, lun: NSNumber,
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

    /// Overlapping writes must reach the device in submission order. The kernel
    /// rewrites GPT headers, APFS superblocks and journal heads back-to-back and
    /// trusts device-order semantics; docs/architecture.md records that
    /// violating this produces nondeterministic corruption which per-operation
    /// tracing shows nothing wrong with.
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
}
