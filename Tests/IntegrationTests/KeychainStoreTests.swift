//
//  KeychainStoreTests.swift
//
//  Every release up to 0.4.3 discarded every CHAP secret a user entered, and
//  nothing caught it. The calls returned, the logic was right, the error path
//  was exercised — the secret simply went to a keychain a system-domain daemon
//  cannot reach. `setCHAPSecret` is `try?` over `store`, so the real status
//  never surfaced, and the user saw "saved but could not be read back", which
//  describes a symptom two steps downstream of the cause.
//
//  The first suite below is the one that would have caught it, and it needs no
//  keychain, no daemon and no root: it asserts the *shape* of the query. The
//  second tests the logic against a fake, which is what the backend seam is for.
//

import Foundation
import Security
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit

/// A keychain that is just a dictionary.
final class FakeKeychain: KeychainStore.Backend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// Forced result for the next `store`, for the refused-write path.
    var nextStoreStatus: OSStatus?

    func store(account: String, service: String, label: String, secret: Data) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if let forced = nextStoreStatus {
            nextStoreStatus = nil
            return forced
        }
        items["\(service)/\(account)"] = secret
        return errSecSuccess
    }

    func fetch(account: String, service: String) -> (status: OSStatus, secret: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard let data = items["\(service)/\(account)"] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func remove(account: String, service: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        return items.removeValue(forKey: "\(service)/\(account)") == nil
            ? errSecItemNotFound : errSecSuccess
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }
}

@Suite("Keychain query shape")
struct KeychainQueryTests {

    /// The assertion that would have caught the bug that shipped in every
    /// release. `kSecUseDataProtectionKeychain` routes the request to `secd`, a
    /// per-user agent that a system-domain LaunchDaemon has no path to; every
    /// call returned -25291 and nothing was ever stored.
    @Test func noQueryAsksForTheDataProtectionKeychain() {
        let base = KeychainStore.SystemKeychain.baseQuery(account: "a", service: "s")
        let write = KeychainStore.SystemKeychain.writeQuery(account: "a", service: "s",
                                                            label: "l", keychain: nil)
        let search = KeychainStore.SystemKeychain.searchQuery(account: "a", service: "s",
                                                              keychain: nil)
        for (name, query) in [("base", base), ("write", write), ("search", search)] {
            #expect(query[kSecUseDataProtectionKeychain as String] == nil,
                    "the \(name) query asks for a keychain iscsid cannot reach")
        }
    }

    /// Searching and adding name the keychain with different keys. Using the
    /// wrong one is not an error — it silently addresses the default keychain,
    /// which for a root daemon is root's login keychain, locked at boot.
    @Test func writeAndSearchNameTheKeychainTheirOwnWay() throws {
        let keychain = try #require(KeychainStore.systemKeychain(),
                                    "the System keychain should be openable for reading")
        let write = KeychainStore.SystemKeychain.writeQuery(account: "a", service: "s",
                                                            label: "l", keychain: keychain)
        let search = KeychainStore.SystemKeychain.searchQuery(account: "a", service: "s",
                                                              keychain: keychain)
        #expect(write[kSecUseKeychain as String] != nil, "an add names one keychain to write into")
        #expect(write[kSecMatchSearchList as String] == nil)
        #expect(search[kSecMatchSearchList as String] != nil, "a search takes a list")
        #expect(search[kSecUseKeychain as String] == nil)
    }

    /// `kSecAttrAccessible` is a data-protection-keychain attribute. Setting it
    /// on a file-keychain item means nothing, and its presence would suggest the
    /// data-protection path had crept back in.
    @Test func theWriteQueryDoesNotCarryAccessibility() {
        let write = KeychainStore.SystemKeychain.writeQuery(account: "a", service: "s",
                                                            label: "l", keychain: nil)
        #expect(write[kSecAttrAccessible as String] == nil)
        #expect(write[kSecClass as String] as! CFString == kSecClassGenericPassword)
        #expect(write[kSecAttrLabel as String] as? String == "l")
    }

    /// The two halves of a mutual pair are separate accounts under one service,
    /// and the initiator's is the bare id so items written before mutual CHAP
    /// existed still resolve.
    @Test func theTwoKindsUseDistinctAccountsAndKeepTheOldLayout() {
        #expect(KeychainStore.Kind.initiator.account(for: "abc") == "abc")
        #expect(KeychainStore.Kind.mutual.account(for: "abc") == "mutual:abc")
    }
}

@Suite("Keychain store behaviour", .serialized)
struct KeychainStoreTests {

    /// Swaps the backend for the duration of one test and puts it back.
    private func withFake(_ body: (FakeKeychain) throws -> Void) rethrows {
        let fake = FakeKeychain()
        let previous = KeychainStore.backend
        KeychainStore.backend = fake
        defer { KeychainStore.backend = previous }
        try body(fake)
    }

    @Test func aStoredSecretReadsBack() throws {
        try withFake { _ in
            try KeychainStore.store("hunter2-and-then-some", for: "target-1")
            #expect(KeychainStore.chapSecret(for: "target-1") == "hunter2-and-then-some")
        }
    }

    @Test func theTwoHalvesOfAPairDoNotOverwriteEachOther() throws {
        try withFake { _ in
            try KeychainStore.store("initiator-secret", for: "target-1", kind: .initiator)
            try KeychainStore.store("peer-secret", for: "target-1", kind: .mutual)
            #expect(KeychainStore.chapSecret(for: "target-1", kind: .initiator) == "initiator-secret")
            #expect(KeychainStore.chapSecret(for: "target-1", kind: .mutual) == "peer-secret")
        }
    }

    @Test func differentTargetsMayShareAUsernameWithoutSharingASecret() throws {
        try withFake { _ in
            try KeychainStore.store("secret-for-one", for: "target-1")
            try KeychainStore.store("secret-for-two", for: "target-2")
            #expect(KeychainStore.chapSecret(for: "target-1") == "secret-for-one")
            #expect(KeychainStore.chapSecret(for: "target-2") == "secret-for-two")
        }
    }

    @Test func deletingATargetRemovesBothHalves() throws {
        try withFake { fake in
            try KeychainStore.store("initiator-secret", for: "target-1", kind: .initiator)
            try KeychainStore.store("peer-secret", for: "target-1", kind: .mutual)
            KeychainStore.deleteAllSecrets(for: "target-1")
            #expect(fake.count == 0)
            #expect(KeychainStore.chapSecret(for: "target-1", kind: .initiator) == nil)
            #expect(KeychainStore.chapSecret(for: "target-1", kind: .mutual) == nil)
        }
    }

    @Test func anAbsentSecretIsNilRatherThanAnError() throws {
        try withFake { _ in
            #expect(KeychainStore.chapSecret(for: "never-stored") == nil)
        }
    }

    /// The distinction the shipped bug erased. A refused write must throw with
    /// the status that refused it, not be swallowed and rediscovered later as
    /// "saved but could not be read back".
    @Test func arefusedWriteThrowsWithItsStatus() throws {
        try withFake { fake in
            fake.nextStoreStatus = errSecAuthFailed
            #expect(throws: KeychainStore.StoreFailure.self) {
                try KeychainStore.store("a-secret-long-enough", for: "target-1")
            }
        }
    }

    /// -25291 is what a system-domain daemon got from the data-protection
    /// keychain for every release up to 0.4.3, and it means something different
    /// from a refusal: there is nowhere to write at all.
    @Test func anUnavailableKeychainIsItsOwnFailure() throws {
        try withFake { fake in
            fake.nextStoreStatus = errSecNotAvailable
            do {
                try KeychainStore.store("a-secret-long-enough", for: "target-1")
                Issue.record("expected the store to fail")
            } catch let failure as KeychainStore.StoreFailure {
                guard case .noSystemKeychain = failure else {
                    Issue.record("expected .noSystemKeychain, got \(failure)")
                    return
                }
            }
        }
    }
}
