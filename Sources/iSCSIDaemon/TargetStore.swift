//
//  TargetStore.swift
//  Where configured targets live.
//
//  Daemon-side rather than app-side: a boot-time auto-attach must read this
//  before anyone logs in, and an app's container is not readable then.
//
//  Secrets are NOT here. `TargetRecord` carries a CHAP *username*; the secret
//  lives in the keychain under the record's id. The file is still 0600 in a
//  0700 directory — record ids have served as credential selectors before,
//  and "this data is harmless" is a claim about code elsewhere.
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

    /// Insert or update. Returns the record as stored — its id may differ:
    /// identity is (host, port, targetIQN, lun), not the id. Twins would share
    /// a `MountpointTag` (derived from those values) and so a mount point.
    /// When a twin exists the **existing** id wins, keeping the keychain item
    /// and mount point stable.
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

    /// The configured target at this portal, if any. Login resolves
    /// credentials through here rather than from the caller, so the daemon
    /// only authenticates to portals the user configured. Same identity
    /// tuple as `save`.
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

    /// A corrupt file returns an empty list rather than refusing to start the
    /// daemon; the broken file is moved aside for inspection, not deleted.
    private func load() -> [TargetRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let records = try JSONDecoder().decode([TargetRecord].self, from: data)

            // Retire any `workloadProfile` left by the removed workload
            // picker: nothing can clear one now, and a stale value pins that
            // volume's readahead depth. Rewritten to disk, or the next daemon
            // start would pin it again.
            let stale = records.filter { $0.workloadProfile != nil }
            guard stale.isEmpty else {
                let cleaned = records.map { record -> TargetRecord in
                    var r = record
                    r.workloadProfile = nil
                    return r
                }
                // Best-effort: if the rewrite fails the daemon still runs with
                // the cleared values, and tries again next load.
                try? persist(cleaned)
                DaemonLog.lifecycle("cleared a stale workload profile from \(stale.count) "
                              + "target(s); readahead depth is chosen automatically")
                return cleaned
            }
            return records
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
        // 0700/0600: nothing unprivileged has any business reading this —
        // every legitimate reader is this daemon or the authenticated XPC
        // channel.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)

        let encoder = JSONEncoder()
        // Sorted and pretty so the file diffs cleanly and reads by eye.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)

        // Atomic: a truncated file would cost the whole configuration.
        try data.write(to: url, options: .atomic)
        // The atomic write lands a fresh inode with umask permissions; the
        // 0700 directory is what closes that pre-chmod window.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cache = records
    }
}
