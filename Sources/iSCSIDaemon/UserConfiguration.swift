//
//  UserConfiguration.swift
//  Whose targets and secrets a connection reaches.
//
//  Configuration is per account (S-01 in docs/security-review-2026-11.md). The
//  app, the FSKit extension, the mounts and attach-at-login all run as the
//  user, so a machine-wide list bought nothing, and it let any account on a Mac
//  edit every target and spend its saved secret.
//
//  The daemon still holds it, under a root-owned directory rather than the
//  user's home, for two reasons. Login resolves against it, because the
//  extension forwards nothing but a mount URL. And root must never read or
//  write a path its caller controls.
//

import Foundation
import iSCSIKit

/// The directory everything the daemon keeps lives under.
public struct ConfigurationRoot: Sendable {
    public static let system = ConfigurationRoot(url: URL(fileURLWithPath:
        "/Library/Application Support/me.herko.iSCSIInitiator"))

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    var users: URL { url.appendingPathComponent("users", isDirectory: true) }

    /// Where every target lived before configuration was per account.
    var legacyTargets: URL { url.appendingPathComponent("targets.json") }

    /// Which account is adopting `legacyTargets`: a symlink whose destination
    /// is the uid, because `symlink(2)` creates name and content in one step.
    var legacyClaim: URL { url.appendingPathComponent("legacy-owner") }

    public func account(_ uid: uid_t) -> UserConfiguration {
        UserConfiguration(uid: uid, root: self)
    }
}

/// One account's slice of the daemon's configuration.
public struct UserConfiguration: Sendable {
    public let uid: uid_t
    public let root: ConfigurationRoot

    public init(uid: uid_t, root: ConfigurationRoot) {
        self.uid = uid
        self.root = root
    }

    public var directory: URL {
        root.users.appendingPathComponent(String(uid), isDirectory: true)
    }

    public var targetsURL: URL {
        directory.appendingPathComponent("targets.json")
    }

    /// Accounts other than this one with at least one saved target. A count:
    /// Uninstall needs to say that something was kept, not whose it was.
    public func otherAccountsWithTargets() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.users.path)) ?? []
        return names.filter { name in
            guard name != String(uid) else { return false }
            let file = root.users.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("targets.json")
            return (try? TargetStore.decode(contentsOf: file))?.isEmpty == false
        }.count
    }

    /// Delete this account's directory, then the parents if that left them
    /// empty. `rmdir` for those: another account's data must stop the removal,
    /// so its refusal is the expected outcome on a shared Mac, not an error.
    public func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        rmdir(root.users.path)
        rmdir(root.url.path)
    }
}

/// Hands the machine-wide configuration of earlier releases to one account:
/// the first ordinary account to use the daemon, with its CHAP secrets. On a
/// shared Mac the other accounts start empty, which is what closes S-01 for
/// existing targets rather than only for new ones.
///
/// **Run from the service, never when a connection is accepted.**
/// `setCodeSigningRequirement` is enforced per message, so at accept time the
/// peer is unverified, and any process in any account could claim the list by
/// connecting.
///
/// Every step is safe to repeat, because a daemon can die anywhere in here, and
/// the only irreversible one comes last. In order: claim, copy each secret and
/// delete the old item, write the account's file, delete the old file. A
/// failure stops there and the next call by the same account resumes; the
/// claim keeps any other account from picking up a list whose secrets have
/// already moved.
public final class LegacyConfigurationAdoption: @unchecked Sendable {
    private let root: ConfigurationRoot

    /// Blocks rather than rejects: the app and the extension connect together
    /// at login, and the second must wait to see the adopted list.
    private let lock = NSLock()

    public init(root: ConfigurationRoot) {
        self.root = root
    }

    /// macOS gives people uids from 501. Excludes root, so `sudo iscsictl`
    /// cannot take the list, the `_` service accounts, and `nobody` (-2).
    static func mayAdopt(_ uid: uid_t) -> Bool {
        (501..<0x8000_0000).contains(uid)
    }

    public func adoptIfNeeded(by uid: uid_t) {
        guard Self.mayAdopt(uid) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: root.legacyTargets.path) else { return }
        do {
            guard try claim(for: uid) else { return }
            try adopt(by: uid)
        } catch {
            DaemonLog.error("adopting the saved targets for uid \(uid): \(error). "
                            + "Kept; trying again on this account's next request.")
        }
    }

    /// True when `uid` holds the claim, whether it just took it or a run that
    /// stopped partway already had.
    private func claim(for uid: uid_t) throws -> Bool {
        let path = root.legacyClaim.path
        if symlink(String(uid), path) == 0 { return true }
        guard errno == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try FileManager.default.destinationOfSymbolicLink(atPath: path) == String(uid)
    }

    private func adopt(by uid: uid_t) throws {
        let account = root.account(uid)
        let legacy: [TargetRecord]
        do {
            legacy = try TargetStore.decode(contentsOf: root.legacyTargets)
        } catch is DecodingError {
            // As `TargetStore.load` treats a corrupt file: set aside, not lost.
            let quarantined = root.legacyTargets.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantined)
            try FileManager.default.moveItem(at: root.legacyTargets, to: quarantined)
            try? FileManager.default.removeItem(at: root.legacyClaim)
            DaemonLog.error("the saved targets were unreadable; moved to "
                            + "\(quarantined.lastPathComponent), nothing to adopt")
            return
        }

        // Secrets before records, so that no record is ever live in the
        // account's file while its secret is still out of reach.
        for record in legacy {
            try KeychainStore.adoptLegacySecrets(for: record.id, owner: uid)
        }

        // A failed run leaves the account using an empty list, so it may have
        // saved targets since. Throws on a corrupt file rather than overwriting
        // it: the store sets that aside on first use and the next call resumes.
        let existing = FileManager.default.fileExists(atPath: account.targetsURL.path)
            ? try TargetStore.decode(contentsOf: account.targetsURL) : []
        let incoming = legacy.filter { old in
            !existing.contains { TargetStore.isSameTarget($0, old) }
        }
        try TargetStore.write(existing + incoming, to: account.targetsURL)

        // A legacy record the account has re-added under another id. The same
        // id is not a twin: that is this run repeating a write it already made,
        // and its secret is the one just adopted.
        for old in legacy where existing.contains(where: {
            $0.id != old.id && TargetStore.isSameTarget($0, old)
        }) {
            try? KeychainStore.deleteAllSecrets(for: old.id, owner: uid)
        }

        try FileManager.default.removeItem(at: root.legacyTargets)
        try? FileManager.default.removeItem(at: root.legacyClaim)
        DaemonLog.lifecycle("uid \(uid) adopted \(incoming.count) saved target(s) "
                            + "from the machine-wide list")
    }
}
