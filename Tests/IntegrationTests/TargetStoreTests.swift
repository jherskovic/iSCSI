//
//  TargetStoreTests.swift
//
//  The store holds the user's entire configuration; most of these tests are
//  about not losing it.
//

import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit

@Suite("Target persistence")
struct TargetStoreTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iscsi-targets-\(UUID().uuidString)")
            .appendingPathComponent("targets.json")
    }

    private func sample(_ id: String = "t1") -> TargetRecord {
        TargetRecord(id: id, displayName: "NAS", host: "192.168.0.101",
                     targetIQN: "iqn.2026-08.me.herko:disk0", lun: 0,
                     chapUser: "initiator", autoAttach: true)
    }

    /// The file lists every target's id, portal, IQN and CHAP username —
    /// enough to select credentials — so it must be readable only by root.
    @Test("the targets file and its directory are readable only by root")
    func permissionsAreRestrictive() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TargetStore(url: url)
        try await store.save(sample())

        let fm = FileManager.default
        let fileMode = try #require(
            fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        let dirMode = try #require(
            fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions]
                as? NSNumber)

        #expect(fileMode.intValue & 0o077 == 0,
                "targets.json is group/other-accessible: \(String(fileMode.intValue, radix: 8))")
        #expect(dirMode.intValue & 0o077 == 0,
                "the directory is group/other-accessible: \(String(dirMode.intValue, radix: 8))")
    }

    @Test("a portal can be resolved back to its record, which is how login finds credentials")
    func portalLookup() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TargetStore(url: url)
        let saved = try await store.save(sample())

        let found = await store.record(host: saved.host, port: saved.port,
                                       targetIQN: saved.targetIQN, lun: saved.lun)
        #expect(found?.id == saved.id)

        // Case-insensitive on the host, matching `save`'s notion of identity.
        let mixedCase = await store.record(host: saved.host.uppercased(), port: saved.port,
                                           targetIQN: saved.targetIQN, lun: saved.lun)
        #expect(mixedCase?.id == saved.id)

        // An unconfigured portal resolves to nothing; that is what makes
        // `login` refuse it.
        let absent = await store.record(host: "attacker.example", port: saved.port,
                                        targetIQN: saved.targetIQN, lun: saved.lun)
        #expect(absent == nil)
    }

    @Test("saving and reading back round-trips")
    func roundTrips() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TargetStore(url: url)
        try await store.save(sample())
        #expect(await store.all() == [sample()])

        // A fresh instance, so this reads the file rather than the cache.
        #expect(await TargetStore(url: url).all() == [sample()])
    }

    @Test("saving an existing id replaces rather than duplicates")
    func saveIsUpsert() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TargetStore(url: url)
        try await store.save(sample())
        var edited = sample()
        edited.displayName = "Renamed"
        try await store.save(edited)

        let all = await store.all()
        #expect(all.count == 1)
        #expect(all.first?.displayName == "Renamed")
    }

    @Test("deleting removes only the named target")
    func deleteIsTargeted() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Genuinely different targets — records differing only by id are the
        // duplicates the store collapses.
        let store = TargetStore(url: url)
        var a = sample("a"); a.host = "nas-one.local"
        var b = sample("b"); b.host = "nas-two.local"
        try await store.save(a)
        try await store.save(b)
        try await store.delete(id: "a")
        #expect(await store.all().map(\.id) == ["b"])
    }

    /// A malformed JSON file must not become a total outage: come up empty
    /// and keep the broken file for inspection.
    @Test("a corrupt file is set aside rather than crashing or being destroyed")
    func corruptFileIsQuarantined() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: url)

        #expect(await TargetStore(url: url).all().isEmpty)

        let quarantined = url.appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: quarantined.path),
                "the unreadable file must be kept, not silently discarded")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// The workload picker is gone, so nothing can show or clear this field —
    /// a stale value would silently pin the volume's readahead depth forever.
    @Test("a stale workload profile is cleared when the store loads")
    func staleWorkloadProfileIsCleared() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let golden = """
            [{"autoAttach":true,"displayName":"NAS","host":"192.168.0.101",
              "id":"t1","lun":0,"port":3260,
              "targetIQN":"iqn.2026-08.me.herko:disk0",
              "workloadProfile":"sequential"}]
            """
        try Data(golden.utf8).write(to: url)

        let store = TargetStore(url: url)
        #expect(await store.all().first?.workloadProfile == nil)

        // Gone from disk too, or the next daemon start pins the volume again.
        let onDisk = try JSONDecoder().decode(
            [TargetRecord].self, from: try Data(contentsOf: url))
        #expect(onDisk.first?.workloadProfile == nil)
        #expect(onDisk.first?.id == "t1", "clearing the field must not disturb the record")
    }

    /// Discover mints a fresh UUID per add, so the same portal added twice
    /// would make two records deriving the same MountpointTag — a shared
    /// mount point where detaching either tears down the other's volume.
    @Test("the same target added twice collapses to one record")
    func duplicateTargetsCollapse() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TargetStore(url: url)

        let first = sample("first-id")
        try await store.save(first)

        // Same host/port/IQN/LUN, different id — a second Discover run.
        var twin = sample("second-id")
        twin.displayName = "Renamed by the second add"
        let stored = try await store.save(twin)

        let all = await store.all()
        #expect(all.count == 1, "two records for one LUN would share a mount point")
        // The original id survives; the keychain item and mount point stay valid.
        #expect(stored.id == "first-id")
        #expect(all.first?.id == "first-id")
        #expect(all.first?.displayName == "Renamed by the second add")
    }

    @Test("targets differing only by LUN are not duplicates")
    func differentLUNsCoexist() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = TargetStore(url: url)

        var lun0 = sample("a"); lun0.lun = 0
        var lun1 = sample("b"); lun1.lun = 1
        try await store.save(lun0)
        try await store.save(lun1)
        #expect(await store.all().count == 2)
    }

    /// A file that already went wrong heals on the next save.
    @Test("an already-duplicated file is repaired on the next save")
    func existingDuplicatesAreRepaired() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // As a pre-fix installation's file would look.
        let both = [sample("one"), sample("two"), sample("three")]
        try JSONEncoder().encode(both).write(to: url)

        let store = TargetStore(url: url)
        #expect(await store.all().count == 3)
        try await store.save(sample("one"))
        #expect(await store.all().count == 1)
    }

    @Test("a missing file is not an error")
    func missingFileIsEmpty() async {
        #expect(await TargetStore(url: temporaryURL()).all().isEmpty)
    }

    /// The secret must never be in this file: a leaked copy may disclose
    /// topology, never credentials.
    @Test("no secret is ever written to disk")
    func secretsNeverPersist() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await TargetStore(url: url).save(sample())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("initiator"), "the CHAP *username* is configuration")
        // TargetRecord has no secret field at all; this asserts nobody adds one.
        #expect(!text.lowercased().contains("secret"))
        #expect(!text.lowercased().contains("password"))
    }
}

/// Wire compatibility. The app and the daemon are separate binaries and can be
/// different builds for the duration of an update, so a field rename that looks
/// harmless in one process is a decode failure in the other.
@Suite("XPC DTO wire format")
struct XPCModelWireTests {

    @Test("TargetRecord decodes from a committed golden payload")
    func targetRecordGolden() throws {
        let golden = """
            {"autoAttach":true,"chapUser":"initiator","displayName":"NAS",
             "host":"192.168.0.101","id":"t1","lun":0,"port":3260,
             "targetIQN":"iqn.2026-08.me.herko:disk0"}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.id == "t1")
        #expect(record.port == 3260)
        #expect(record.autoAttach)
        #expect(record.mutualChapUser == nil, "an absent optional must stay decodable")
    }

    /// Installed targets.json files predate the flush setting; absent must
    /// mean write-through, not a decode failure or some other policy.
    @Test("a pre-flush-setting record decodes as write-through")
    func flushSettingAbsentIsWriteThrough() throws {
        let golden = """
            {"autoAttach":true,"chapUser":"initiator","displayName":"NAS",
             "host":"192.168.0.101","id":"t1","lun":0,"port":3260,
             "targetIQN":"iqn.2026-08.me.herko:disk0"}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.flushIntervalSeconds == nil)
        #expect(FlushPolicy(intervalSeconds: record.flushIntervalSeconds) == .writeThrough)
    }

    @Test("the flush setting round-trips and maps to the right policy")
    func flushSettingRoundTrips() throws {
        var record = TargetRecord(id: "t1", displayName: "NAS", host: "192.168.0.101",
                                  targetIQN: "iqn.2026-08.me.herko:disk0")
        record.flushIntervalSeconds = 30
        var decoded = try JSONDecoder().decode(
            TargetRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.flushIntervalSeconds == 30)
        #expect(FlushPolicy(intervalSeconds: 30) == .interval(seconds: 30))

        // 0 is "never flush": the user declared the cache non-volatile.
        record.flushIntervalSeconds = 0
        decoded = try JSONDecoder().decode(
            TargetRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.flushIntervalSeconds == 0)
        #expect(FlushPolicy(intervalSeconds: 0) == .never)

        // Hand-editable file: a nonsense negative falls back to the safe default.
        #expect(FlushPolicy(intervalSeconds: -5) == .writeThrough)
    }

    /// Absent must pin nothing (the depth controller steers): an installed
    /// target must not change I/O behaviour merely by being upgraded.
    @Test("a record without a workload profile decodes as mixed")
    func workloadProfileAbsentIsMixed() throws {
        let golden = """
            {"autoAttach":true,"chapUser":"initiator","displayName":"NAS",
             "host":"192.168.0.101","id":"t1","lun":0,"port":3260,
             "targetIQN":"iqn.2026-08.me.herko:disk0"}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.workloadProfile == nil)
        // nil is not a profile: nothing pinned, the controller steers.
        #expect(WorkloadProfile(rawValue: record.workloadProfile ?? "") == nil)
    }

    @Test("each workload profile round-trips and maps to its readahead budget")
    func workloadProfileRoundTrips() throws {
        var record = TargetRecord(id: "t1", displayName: "NAS", host: "192.168.0.101",
                                  targetIQN: "iqn.2026-08.me.herko:disk0")

        record.workloadProfile = "random"
        var decoded = try JSONDecoder().decode(
            TargetRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.workloadProfile == "random")
        #expect(WorkloadProfile(rawValue: "random") == .randomAccess)
        #expect(WorkloadProfile.randomAccess.readaheadBudgetBytes == 512 << 10)

        record.workloadProfile = "sequential"
        decoded = try JSONDecoder().decode(
            TargetRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.workloadProfile == "sequential")
        #expect(WorkloadProfile(rawValue: "sequential") == .sequential)
        #expect(WorkloadProfile.sequential.readaheadBudgetBytes == 4 << 20)

        record.workloadProfile = "mixed"
        decoded = try JSONDecoder().decode(
            TargetRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.workloadProfile == "mixed")
        #expect(WorkloadProfile(rawValue: "mixed") == .mixed)
    }

    /// A typo in the hand-editable file must not silently pin a depth.
    @Test("an unrecognised workload profile pins nothing")
    func workloadProfileUnknownPinsNothing() {
        #expect(WorkloadProfile.pinnedBudgetBytes(stored: "turbo") == nil)
        #expect(WorkloadProfile.pinnedBudgetBytes(stored: "") == nil)
        #expect(WorkloadProfile.pinnedBudgetBytes(stored: nil) == nil)
        #expect(WorkloadProfile.pinnedBudgetBytes(stored: "sequential") == 4 << 20)
    }

    @Test("DaemonInfo decodes from a committed golden payload")
    func daemonInfoGolden() throws {
        let golden = """
            {"authorizationRelaxed":false,"build":"4","pid":1234,"version":"0.1.3"}
            """
        let info = try JSONDecoder().decode(DaemonInfo.self, from: Data(golden.utf8))
        #expect(info.version == "0.1.3")
        #expect(info.pid == 1234)
        #expect(!info.authorizationRelaxed)
    }

    @Test("SessionInfo round-trips with its negotiated parameters")
    func sessionInfoRoundTrips() throws {
        var params = OperationalParameters()
        params.firstBurstLength = 1_048_576
        params.headerDigest = true

        let info = SessionInfo(handle: "s1", targetIQN: "iqn.x", lun: 0,
                               blockSize: 512, blockCount: 1024,
                               writeCacheEnabled: true, writeThrough: true,
                               recoveryCount: 2, negotiated: params.displayPairs)
        let decoded = try JSONDecoder().decode(
            SessionInfo.self, from: JSONEncoder().encode(info))

        #expect(decoded == info)
        #expect(decoded.negotiated["FirstBurstLength"] == "1048576")
        #expect(decoded.negotiated["HeaderDigest"] == "CRC32C")
        #expect(decoded.byteCount == 512 * 1024)
    }

    /// A parameter missing from this dictionary is invisible to every bug
    /// report; the ones that explain performance questions must be present.
    @Test("the parameters that explain performance questions are all displayed")
    func displayPairsCoverTheUsefulOnes() {
        let pairs = OperationalParameters().displayPairs
        for key in ["MaxBurstLength", "FirstBurstLength", "ImmediateData",
                    "InitialR2T", "MaxOutstandingR2T", "HeaderDigest",
                    "DataDigest", "ErrorRecoveryLevel"] {
            #expect(pairs[key] != nil, "\(key) is missing from the diagnostics pane")
        }
    }
}
