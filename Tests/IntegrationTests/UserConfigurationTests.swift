//
//  UserConfigurationTests.swift
//
//  S-01: an account reaches its own targets and secrets and nobody else's, and
//  the machine-wide list of earlier releases reaches exactly one account with
//  nothing lost, wherever the daemon happens to die on the way.
//
//  The services here are built with an explicit account. What decides that
//  account in production, `NSXPCConnection.effectiveUserIdentifier`, needs a
//  real connection, so it is checked on the VM (docs/test-playbook.md).
//

import Foundation
import Security
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit

/// The account most tests speak for, without caring which it is.
let testOwner: uid_t = 501

extension ISCSIXPCService {
    /// For tests about anything but accounts: `testOwner`, with no legacy file
    /// to adopt and `targets` supplied by the test.
    convenience init(core: DaemonCore, targets: TargetStore) {
        let root = ConfigurationRoot(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        self.init(core: core, account: root.account(testOwner),
                  adoption: LegacyConfigurationAdoption(root: root), targets: targets)
    }
}

@Suite("Per-account configuration", .serialized)
struct UserConfigurationTests {
    private let alice: uid_t = 501
    private let bob: uid_t = 502

    // MARK: Helpers

    private func withFake(_ body: (FakeKeychain) async throws -> Void) async rethrows {
        let fake = FakeKeychain()
        let previous = KeychainStore.backend
        KeychainStore.backend = fake
        defer { KeychainStore.backend = previous }
        try await body(fake)
    }

    private func makeRoot() throws -> ConfigurationRoot {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ConfigurationRoot(url: url)
    }

    private func core() -> DaemonCore {
        DaemonCore(initiatorName: "iqn.test:initiator") { _, _, _ in
            throw TransportError.connectFailed("no target in this test")
        }
    }

    private func service(_ uid: uid_t, _ root: ConfigurationRoot,
                         _ adoption: LegacyConfigurationAdoption? = nil) -> ISCSIXPCService {
        ISCSIXPCService(core: core(), account: root.account(uid),
                        adoption: adoption ?? LegacyConfigurationAdoption(root: root))
    }

    private func record(_ id: String, host: String = "192.0.2.1",
                        iqn: String = "iqn.2026-08.test:disk0", chapUser: String? = nil) -> TargetRecord {
        TargetRecord(id: id, displayName: id, host: host, targetIQN: iqn, chapUser: chapUser)
    }

    /// A Mac as an earlier release left it.
    private func seedLegacy(_ root: ConfigurationRoot, _ records: [TargetRecord],
                            secrets: [String: String] = [:], fake: FakeKeychain) throws {
        try JSONEncoder().encode(records).write(to: root.legacyTargets)
        for (account, secret) in secrets {
            #expect(fake.store(account: account, service: KeychainStore.legacyService,
                               label: "old", secret: Data(secret.utf8)) == errSecSuccess)
        }
    }

    private func list(_ service: ISCSIXPCService) async throws -> [TargetRecord] {
        let data: Data? = await withCheckedContinuation { done in
            service.listTargets { data, _ in done.resume(returning: data) }
        }
        return try JSONDecoder().decode([TargetRecord].self, from: try #require(data))
    }

    private func save(_ record: TargetRecord, _ service: ISCSIXPCService) async throws {
        let encoded = try JSONEncoder().encode(record)
        let error: Error? = await withCheckedContinuation { done in
            service.saveTarget(encoded) { _, error in done.resume(returning: error) }
        }
        #expect(error == nil)
    }

    private func reply(_ call: (@escaping (Error?) -> Void) -> Void) async -> Error? {
        await withCheckedContinuation { done in call { done.resume(returning: $0) } }
    }

    private func hasSecret(_ id: String, _ service: ISCSIXPCService) async -> Bool {
        await withCheckedContinuation { done in
            service.hasCHAPSecret(targetID: id) { done.resume(returning: $0) }
        }
    }

    private func loginError(_ record: TargetRecord, _ service: ISCSIXPCService) async -> String? {
        await withCheckedContinuation { done in
            service.login(host: record.host, port: NSNumber(value: record.port),
                          targetIQN: record.targetIQN, lun: NSNumber(value: record.lun)) { _, error in
                done.resume(returning: error?.localizedDescription)
            }
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Isolation

    @Test func anAccountsTargetsLiveUnderItsUid() throws {
        let root = ConfigurationRoot.system
        #expect(root.account(501).targetsURL.path
                == "/Library/Application Support/me.herko.iSCSIInitiator/users/501/targets.json")
    }

    @Test func aTargetSavedByOneAccountIsInvisibleToAnother() async throws {
        let root = try makeRoot()
        try await save(record("a"), service(alice, root))
        #expect(try await list(service(alice, root)).map(\.id) == ["a"])
        #expect(try await list(service(bob, root)).isEmpty)
    }

    @Test func twoAccountsCanSaveTheSameTarget() async throws {
        let root = try makeRoot()
        try await save(record("a"), service(alice, root))
        try await save(record("b"), service(bob, root))
        #expect(try await list(service(alice, root)).map(\.id) == ["a"])
        #expect(try await list(service(bob, root)).map(\.id) == ["b"])
    }

    /// The daemon's whole login authorization: a portal nobody configured is
    /// refused. "Nobody" now means nobody in this account.
    @Test func loginRefusesATargetOnlyAnotherAccountConfigured() async throws {
        let root = try makeRoot()
        let target = record("a")
        try await save(target, service(alice, root))
        let refused = try #require(await loginError(target, service(bob, root)))
        #expect(refused.contains("No saved target matches"), "got: \(refused)")
    }

    /// The attack that moving only the target list would have left open.
    /// Clients choose ids, so Bob saves a record with Alice's id pointing at
    /// his own portal and asks the daemon to log in with it.
    @Test func anotherAccountsIdDoesNotReachItsSecret() async throws {
        try await withFake { _ in
            let root = try makeRoot()
            let victim = record("shared-id", chapUser: "alice")
            try await save(victim, service(alice, root))
            #expect(await reply { service(alice, root).setCHAPSecret(
                targetID: "shared-id", secret: "alices-secret-long", reply: $0) } == nil)

            let attacker = service(bob, root)
            let forged = record("shared-id", host: "198.51.100.66", chapUser: "alice")
            try await save(forged, attacker)

            #expect(await hasSecret("shared-id", attacker) == false)
            let refused = try #require(await loginError(forged, attacker))
            #expect(refused.contains("no CHAP secret is saved"), "got: \(refused)")
            #expect(await hasSecret("shared-id", service(alice, root)))
        }
    }

    @Test func oneAccountCannotReplaceOrDeleteAnothersSecret() async throws {
        try await withFake { _ in
            let root = try makeRoot()
            #expect(await reply { service(alice, root).setCHAPSecret(
                targetID: "id", secret: "alices-secret-long", reply: $0) } == nil)

            let other = service(bob, root)
            #expect(await reply { other.setCHAPSecret(
                targetID: "id", secret: "bobs-secret-is-long", reply: $0) } == nil)
            #expect(await reply { other.deleteCHAPSecret(targetID: "id", reply: $0) } == nil)
            #expect(await reply { other.deleteTarget(id: "id", reply: $0) } == nil)

            #expect(KeychainStore.chapSecret(for: "id", owner: alice) == "alices-secret-long")
        }
    }

    // MARK: Adoption

    @Test func theFirstAccountAdoptsTargetsAndBothSecrets() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            try seedLegacy(root, [record("a", chapUser: "u"), record("b", iqn: "iqn.2026-08.test:two")],
                           secrets: ["a": "initiator-secret", "mutual:a": "mutual-secret"], fake: fake)

            #expect(try await list(service(alice, root)).map(\.id) == ["a", "b"])

            #expect(KeychainStore.chapSecret(for: "a", owner: alice) == "initiator-secret")
            #expect(KeychainStore.chapSecret(for: "a", owner: alice, kind: .mutual) == "mutual-secret")
            #expect(fake.fetch(account: "a", service: KeychainStore.legacyService).secret == nil)
            #expect(fake.fetch(account: "mutual:a", service: KeychainStore.legacyService).secret == nil)
            #expect(!exists(root.legacyTargets))
            #expect(!exists(root.legacyClaim))
        }
    }

    @Test func aSecondAccountAdoptsNothing() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            try seedLegacy(root, [record("a")], secrets: ["a": "initiator-secret"], fake: fake)

            _ = try await list(service(alice, root))
            #expect(try await list(service(bob, root)).isEmpty)
            #expect(KeychainStore.chapSecret(for: "a", owner: bob) == nil)
        }
    }

    /// Root and the service accounts have no business owning a user's targets,
    /// and `sudo iscsictl` must not be able to take them.
    @Test(arguments: [0, 88, 500, 4_294_967_294] as [uid_t])
    func onlyPeopleAdopt(uid: uid_t) async throws {
        try await withFake { fake in
            let root = try makeRoot()
            try seedLegacy(root, [record("a")], fake: fake)
            #expect(try await list(service(uid, root)).isEmpty)
            #expect(exists(root.legacyTargets))
            #expect(!exists(root.legacyClaim))
        }
    }

    /// `setCodeSigningRequirement` is checked per message, so a connection
    /// being accepted proves nothing about its peer. An unsigned process in any
    /// account gets this far, and it must not be able to take the list.
    @Test func acceptingAConnectionAdoptsNothing() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            try seedLegacy(root, [record("a")], fake: fake)

            _ = service(bob, root)

            #expect(exists(root.legacyTargets))
            #expect(!exists(root.legacyClaim))
            #expect(try await list(service(alice, root)).map(\.id) == ["a"])
        }
    }

    /// A secret call with no listing before it still gets adopted data.
    @Test func aSecretLookupTriggersAdoptionToo() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            try seedLegacy(root, [record("a")], secrets: ["a": "initiator-secret"], fake: fake)
            #expect(await hasSecret("a", service(alice, root)))
        }
    }

    @Test func aRefusedSecretLeavesEverythingToRetryAndNobodyElseCanClaimIt() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            let adoption = LegacyConfigurationAdoption(root: root)
            try seedLegacy(root, [record("a")], secrets: ["a": "initiator-secret"], fake: fake)

            fake.nextStoreStatus = errSecInteractionNotAllowed
            adoption.adoptIfNeeded(by: alice)
            #expect(exists(root.legacyTargets))
            #expect(!exists(root.account(alice).targetsURL))
            #expect(fake.fetch(account: "a", service: KeychainStore.legacyService).secret != nil,
                    "the old secret goes only once the new one is safe")

            adoption.adoptIfNeeded(by: bob)
            #expect(exists(root.legacyTargets))
            #expect(!exists(root.account(bob).targetsURL))

            adoption.adoptIfNeeded(by: alice)
            #expect(!exists(root.legacyTargets))
            #expect(KeychainStore.chapSecret(for: "a", owner: alice) == "initiator-secret")
        }
    }

    /// The old item is the only copy until the new one is proven. A store that
    /// claims success and keeps nothing must not cost the user the secret.
    @Test func aCopyThatDoesNotReadBackLeavesTheOldSecretInPlace() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            let adoption = LegacyConfigurationAdoption(root: root)
            try seedLegacy(root, [record("a")], secrets: ["a": "initiator-secret"], fake: fake)

            fake.dropNextStore = true
            adoption.adoptIfNeeded(by: alice)

            #expect(fake.fetch(account: "a", service: KeychainStore.legacyService).secret
                    == Data("initiator-secret".utf8))
            #expect(exists(root.legacyTargets))

            adoption.adoptIfNeeded(by: alice)
            #expect(KeychainStore.chapSecret(for: "a", owner: alice) == "initiator-secret")
            #expect(!exists(root.legacyTargets))
        }
    }

    /// A daemon killed after writing the account's file and before removing the
    /// old one. The record is in both places and looks like a twin of itself:
    /// treating it as one would delete the secret just adopted.
    @Test func resumingAfterTheWriteKeepsTheAdoptedSecret() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            let adoption = LegacyConfigurationAdoption(root: root)
            try seedLegacy(root, [record("a")], fake: fake)
            #expect(symlink(String(alice), root.legacyClaim.path) == 0)
            try TargetStore.write([record("a")], to: root.account(alice).targetsURL)
            try KeychainStore.store("initiator-secret", for: "a", owner: alice)

            adoption.adoptIfNeeded(by: alice)

            #expect(!exists(root.legacyTargets))
            #expect(KeychainStore.chapSecret(for: "a", owner: alice) == "initiator-secret")
            #expect(try await list(service(alice, root)).map(\.id) == ["a"])
        }
    }

    /// Adoption failed, so the account worked from an empty list for a while.
    @Test func targetsSavedBeforeAdoptionFinishedAreKept() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            let adoption = LegacyConfigurationAdoption(root: root)
            try seedLegacy(root, [record("old", iqn: "iqn.2026-08.test:old")],
                           secrets: ["old": "initiator-secret"], fake: fake)

            fake.nextStoreStatus = errSecInteractionNotAllowed
            adoption.adoptIfNeeded(by: alice)
            try TargetStore.write([record("new", iqn: "iqn.2026-08.test:new")],
                                  to: root.account(alice).targetsURL)

            adoption.adoptIfNeeded(by: alice)
            #expect(try await list(service(alice, root)).map(\.id).sorted() == ["new", "old"])
        }
    }

    /// The same, with the account having re-added an old target: its own record
    /// stands, and the superseded secret does not stay behind under a dead id.
    @Test func aTargetReAddedBeforeAdoptionFinishedWins() async throws {
        try await withFake { fake in
            let root = try makeRoot()
            let adoption = LegacyConfigurationAdoption(root: root)
            try seedLegacy(root, [record("old")], secrets: ["old": "stale-secret"], fake: fake)

            fake.nextStoreStatus = errSecInteractionNotAllowed
            adoption.adoptIfNeeded(by: alice)
            try TargetStore.write([record("new")], to: root.account(alice).targetsURL)
            try KeychainStore.store("fresh-secret", for: "new", owner: alice)

            adoption.adoptIfNeeded(by: alice)

            #expect(try await list(service(alice, root)).map(\.id) == ["new"])
            #expect(KeychainStore.chapSecret(for: "new", owner: alice) == "fresh-secret")
            #expect(KeychainStore.chapSecret(for: "old", owner: alice) == nil)
            #expect(fake.count == 1)
        }
    }

    @Test func aCorruptLegacyFileIsSetAsideAndReleasesTheClaim() async throws {
        try await withFake { _ in
            let root = try makeRoot()
            try Data("not json".utf8).write(to: root.legacyTargets)

            #expect(try await list(service(alice, root)).isEmpty)

            #expect(!exists(root.legacyTargets))
            #expect(exists(root.legacyTargets.appendingPathExtension("corrupt")))
            #expect(!exists(root.legacyClaim))
        }
    }

    /// Nothing left to adopt, as on every Mac after the first run.
    @Test func noLegacyFileMeansNothingHappens() async throws {
        let root = try makeRoot()
        #expect(try await list(service(alice, root)).isEmpty)
        #expect(!exists(root.legacyClaim))
    }

    // MARK: Removal

    @Test func removingDataLeavesOtherAccountsAlone() async throws {
        try await withFake { _ in
            let root = try makeRoot()
            for (uid, id) in [(alice, "a"), (bob, "b")] {
                try await save(record(id), service(uid, root))
                #expect(await reply { service(uid, root).setCHAPSecret(
                    targetID: id, secret: "a-secret-long-enough", reply: $0) } == nil)
            }

            #expect(await reply { service(alice, root).removeAllData(reply: $0) } == nil)

            #expect(!exists(root.account(alice).directory))
            #expect(KeychainStore.chapSecret(for: "a", owner: alice) == nil)
            #expect(try await list(service(bob, root)).map(\.id) == ["b"])
            #expect(KeychainStore.chapSecret(for: "b", owner: bob) == "a-secret-long-enough")
            #expect(root.account(alice).otherAccountsWithTargets() == 1)
        }
    }

    /// The last one out leaves the Mac as clean as uninstall always did.
    @Test func theLastAccountRemovesTheWholeDirectory() async throws {
        try await withFake { _ in
            let root = try makeRoot()
            try await save(record("a"), service(alice, root))

            #expect(await reply { service(alice, root).removeAllData(reply: $0) } == nil)

            #expect(!exists(root.url))
        }
    }

    /// An account that deleted its targets has nothing Uninstall left behind.
    @Test func anEmptyListIsNotCountedAsSavedTargets() async throws {
        let root = try makeRoot()
        try TargetStore.write([], to: root.account(bob).targetsURL)
        #expect(root.account(alice).otherAccountsWithTargets() == 0)
    }
}
