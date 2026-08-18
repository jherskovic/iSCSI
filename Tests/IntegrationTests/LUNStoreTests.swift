//
//  LUNStoreTests.swift
//
//  First tests ever to run against the volume's data path. Until this code was
//  split out of `iSCSIFSExtension.swift` it lived in an Xcode target, so
//  `swift test` could not reach a line of it — 1,155 lines of shipping code
//  sitting at 0% while the package reported 88%.
//
//  `BackingStore` is the local-file implementation of `LUNStore`. It is not the
//  path a user's bytes take, but it is the same contract `DaemonStore` has to
//  satisfy, and it is the one the FSKit plumbing is regression-tested against
//  when a problem needs isolating from the network. Its edge behaviour — short
//  reads at the end of the device, offsets past the end, partial writes — is
//  exactly where a filesystem finds out whether a block device means what it
//  says.
//

import Foundation
import Testing
@testable import iSCSIVolume

@Suite("LUN store contract")
struct LUNStoreTests {

    private func makeStore() throws -> (BackingStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".img")
        return (try BackingStore(path: url.path), url)
    }

    private func read(_ store: LUNStore, at offset: UInt64, length: Int) throws -> Data {
        var out = Data(count: length)
        let got: Int = try out.withUnsafeMutableBytes { raw in
            try store.read(into: raw, at: offset, length: length)
        }
        return out.prefix(got)
    }

    @Test func aFreshStoreReportsItsGeometry() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.byteCount > 0)
        #expect(store.blockSize == 4096, "the local store models a 4Kn LUN on purpose")
        #expect(!store.summary.isEmpty)
    }

    @Test func writtenBytesReadBack() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data((0 ..< 8192).map { UInt8($0 & 0xFF) })

        #expect(try store.write(payload, at: 4096) == payload.count)
        #expect(try read(store, at: 4096, length: payload.count) == payload)
    }

    /// A fresh region reads as zeroes rather than as whatever the file system
    /// left there. A block device that returns uninitialised memory hands the
    /// filesystem above it someone else's data.
    @Test func unwrittenRegionsReadAsZero() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try read(store, at: 1 << 20, length: 4096)
        #expect(data == Data(count: 4096))
    }

    /// The end of the device is where a filesystem probes for capacity, so the
    /// answers there matter more than their frequency suggests: a read that
    /// straddles the end must be clamped rather than refused or over-served.
    @Test func readsAreClampedAtTheEndOfTheDevice() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let straddling = try read(store, at: store.byteCount - 512, length: 4096)
        #expect(straddling.count == 512, "a straddling read returns only what exists")

        let past = try read(store, at: store.byteCount, length: 4096)
        #expect(past.isEmpty, "a read entirely past the end returns nothing, not an error")
    }

    @Test func writesSurviveAFlush() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data(repeating: 0xA5, count: 4096)

        _ = try store.write(payload, at: 8192)
        try store.flush()
        #expect(try read(store, at: 8192, length: 4096) == payload)
    }

    /// Reopening the same path must see the same bytes and report the same
    /// size — the store is the device's persistence, and a mount that came back
    /// with a different geometry would be a different disk to everything above.
    @Test func aReopenedStoreSeesTheSameDevice() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data(repeating: 0x3C, count: 4096)
        _ = try store.write(payload, at: 16384)
        try store.flush()
        let size = store.byteCount

        let reopened = try BackingStore(path: url.path)
        #expect(reopened.byteCount == size)
        #expect(try read(reopened, at: 16384, length: 4096) == payload)
    }

    /// Overlapping writes to the same region must land in submission order.
    /// The kernel rewrites the same block back-to-back — GPT headers, APFS
    /// superblocks, journal heads — and trusts device-order semantics;
    /// `docs/architecture.md` records what happens when that is violated.
    @Test func overlappingWritesLandInOrder() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        for generation in UInt8(1) ... UInt8(16) {
            _ = try store.write(Data(repeating: generation, count: 4096), at: 4096)
        }
        #expect(try read(store, at: 4096, length: 4096) == Data(repeating: 16, count: 4096))
    }
}
