//
//  TargetStore.swift
//  Where configured targets live.
//
//  Nothing persisted anything before this: no UserDefaults, no plist, no
//  archiver anywhere in the project. Every session was built from arguments
//  typed at a command line.
//
//  Daemon-side rather than app-side, for one reason that will matter later: a
//  boot-time auto-attach has to know what to attach before anyone logs in, and
//  an app's container is not readable then. That the app is currently the only
//  writer does not change where the file has to live.
//
//  Secrets are NOT here. `TargetRecord` carries a CHAP *username*; the secret
//  lives in the keychain under the record's id. A targets file that leaks — in a
//  backup, a support bundle, a screenshot of Finder — discloses topology, which
//  is unpleasant, rather than credentials, which is a breach.
//
//  That argument is still true and it is still not a reason to leave the file
//  readable. It was written when the file was 0644, and it held only because the
//  record id was inert; login then started using a client-supplied string as the
//  keychain account name, which quietly turned this file into a list of valid
//  credential selectors. The lesson is that "this data is harmless" is a claim
//  about code elsewhere, and code elsewhere changes. It is 0600 in a 0700
//  directory now, and the argument above is a nice-to-have rather than the
//  thing standing between a local user and a secret.
//

import Foundation
import iSCSIKit

public actor TargetStore {
    /// `/Library/Application Support/...` rather than `~/Library`: root-owned,
    /// readable before login, and the same file for every user of the machine —
    /// which matches the fact that the iSCSI session is a machine-level resource,
    /// not a per-user one.
    public static let defaultURL = URL(fileURLWithPath:
        "/Library/Application Support/me.herko.iSCSIInitiator/targets.json")

    private let url: URL
    private var cache: [TargetRecord]?

    public init(url: URL = TargetStore.defaultURL) {
        self.url = url
    }

    public func all() -> [TargetRecord] {
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    /// Insert or update. Returns the record as stored, whose id may differ from
    /// the one passed in — see below.
    ///
    /// Identity is (host, port, targetIQN, lun), not the id. Two records with
    /// the same four values are the same target however they were created, and
    /// allowing both is actively harmful: `MountpointTag` is derived from
    /// exactly those values, so twins share a mount point. Attaching the second
    /// would silently land on the first's mount, and detaching either would tear
    /// down the other's volume.
    ///
    /// It happened: adding a target from Discover mints a fresh UUID, so
    /// discovering the same portal twice produced two records for one LUN.
    ///
    /// When a twin exists, the **existing** id wins and its fields are updated.
    /// That keeps the keychain item and the mount point stable, where taking the
    /// newcomer's id would orphan a stored secret and strand a live mount.
    @discardableResult
    public func save(_ record: TargetRecord) throws -> TargetRecord {
        var records = all()
        var incoming = record

        if let index = records.firstIndex(where: { $0.id != record.id && isSameTarget($0, record) }) {
            incoming.id = records[index].id
            records[index] = incoming
            // Any *other* twins are collapsed too, so a file that already went
            // wrong is repaired the next time it is written rather than kept.
            records.removeAll { $0.id != incoming.id && isSameTarget($0, incoming) }
        } else if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = incoming
        } else {
            records.append(incoming)
        }
        try persist(records)
        return incoming
    }

    /// The configured target at this portal, if there is one.
    ///
    /// Login resolves credentials through here rather than taking them from the
    /// caller, so the set of portals the daemon will authenticate to is exactly
    /// the set the user configured. Uses the same (host, port, IQN, LUN)
    /// identity as `save`, which is what makes "the record the user edited" and
    /// "the record a mount URL names" the same record.
    public func record(host: String, port: UInt16, targetIQN: String, lun: UInt64) -> TargetRecord? {
        all().first {
            $0.host.caseInsensitiveCompare(host) == .orderedSame
                && $0.port == port
                && $0.targetIQN == targetIQN
                && $0.lun == lun
        }
    }

    private func isSameTarget(_ a: TargetRecord, _ b: TargetRecord) -> Bool {
        a.host.caseInsensitiveCompare(b.host) == .orderedSame
            && a.port == b.port
            && a.targetIQN == b.targetIQN
            && a.lun == b.lun
    }

    public func delete(id: String) throws {
        try persist(all().filter { $0.id != id })
    }

    // MARK: - Disk

    /// A corrupt or unreadable file returns an empty list rather than throwing.
    ///
    /// The alternative is a daemon that refuses to start because one JSON file
    /// is malformed, which turns a cosmetic problem into a total outage. The
    /// broken file is moved aside rather than deleted, so it can still be
    /// inspected — losing a user's target list silently would be worse than
    /// either.
    private func load() -> [TargetRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([TargetRecord].self, from: data)
        } catch {
            let quarantined = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantined)
            try? FileManager.default.moveItem(at: url, to: quarantined)
            DaemonLog.error("targets.json was unreadable (\(error)); moved to "
                            + "\(quarantined.lastPathComponent) and starting empty")
            return []
        }
    }

    private func persist(_ records: [TargetRecord]) throws {
        // 0700/0600, not 0755/0644. The header above argues that a leak
        // discloses topology rather than credentials, and that was true only
        // while the record id was not itself a credential selector. It was: the
        // daemon used to look a CHAP secret up by a string the client supplied,
        // so a world-readable list of ids was a list of keychain account names.
        // Login no longer works that way, but nothing unprivileged has any
        // business reading this either — every legitimate reader is this daemon
        // or goes through `listTargets` on the authenticated XPC channel.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)

        let encoder = JSONEncoder()
        // Sorted and pretty so the file diffs cleanly and can be read by a human
        // who is trying to work out what the app thinks it is connected to.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)

        // Atomic: a truncated targets.json is indistinguishable from a corrupt
        // one, and would cost the user their whole configuration for a crash
        // that happened to land mid-write.
        try data.write(to: url, options: .atomic)
        // An atomic write lands a fresh inode with umask-derived permissions, so
        // there is a moment before this chmod when the file is world-readable.
        // The 0700 on the directory above is what actually closes that window:
        // an unprivileged process cannot traverse into it to open the file at
        // all, whatever mode the file itself is wearing at the time.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cache = records
    }
}
