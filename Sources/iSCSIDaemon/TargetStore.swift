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

    public func save(_ record: TargetRecord) throws {
        var records = all()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try persist(records)
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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        let encoder = JSONEncoder()
        // Sorted and pretty so the file diffs cleanly and can be read by a human
        // who is trying to work out what the app thinks it is connected to.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)

        // Atomic: a truncated targets.json is indistinguishable from a corrupt
        // one, and would cost the user their whole configuration for a crash
        // that happened to land mid-write.
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        cache = records
    }
}
