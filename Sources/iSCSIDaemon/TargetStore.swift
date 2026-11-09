//
//  TargetStore.swift
//  Where configured targets live.
//
//  One store per account, at `UserConfiguration.targetsURL`, which says why the
//  daemon holds them and not the app.
//
//  Secrets are NOT here. `TargetRecord` carries a CHAP *username*; the secret
//  lives in the keychain under the record's id. The file is still 0600 in a
//  0700 directory — record ids have served as credential selectors before,
//  and "this data is harmless" is a claim about code elsewhere.
//

import Foundation
import iSCSIKit

public actor TargetStore {
    private let url: URL
    private var cache: [TargetRecord]?
    /// What the file was when `cache` was read or written. The file is not
    /// only this actor's: legacy adoption writes an account's file directly
    /// (`write(_:to:)`), and when an adoption that failed once is resumed,
    /// this store has already cached the list from before it. Without the
    /// check, the next save wrote that stale list over the adopted targets
    /// and orphaned their secrets.
    private var cacheStamp: FileStamp?

    public init(url: URL) {
        self.url = url
    }

    public func all() -> [TargetRecord] {
        let stamp = FileStamp(url)
        if let cache, stamp == cacheStamp { return cache }
        let loaded = load()
        cache = loaded
        cacheStamp = FileStamp(url)
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

        if let index = records.firstIndex(where: { $0.id != record.id && Self.isSameTarget($0, record) }) {
            incoming.id = records[index].id
            records[index] = incoming
            // Any *other* twins are collapsed too, so a file that already went
            // wrong is repaired the next time it is written rather than kept.
            records.removeAll { $0.id != incoming.id && Self.isSameTarget($0, incoming) }
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

    /// The configured target for this name at this portal, whatever LUN its
    /// record names. For listing a target's units — the step that tells the
    /// user what the LUN should be, so it cannot be keyed on it.
    public func record(host: String, port: UInt16, targetIQN: String) -> TargetRecord? {
        all().first {
            $0.host.caseInsensitiveCompare(host) == .orderedSame
                && $0.port == port
                && $0.targetIQN == targetIQN
        }
    }

    static func isSameTarget(_ a: TargetRecord, _ b: TargetRecord) -> Bool {
        a.host.caseInsensitiveCompare(b.host) == .orderedSame
            && a.port == b.port
            && a.targetIQN == b.targetIQN
            && a.lun == b.lun
    }

    /// Legacy ID-based removal intentionally repairs all records sharing an ID.
    public func remove(id: String, beforeDelete: @Sendable () throws -> Void) throws {
        let records = all()
        try beforeDelete()
        try persist(records.filter { $0.id != id })
    }

    /// Compare and delete in one actor turn, including credential cleanup.
    public func delete(expected: TargetRecord, beforeDelete: @Sendable () throws -> Void = {}) throws {
        let records = all()
        let matchingIDs = records.filter { $0.id == expected.id }
        guard matchingIDs.count <= 1 else { throw TargetRemovalError.duplicateID }
        guard let current = matchingIDs.first else {
            throw TargetRemovalError.changed
        }
        guard current == expected else { throw TargetRemovalError.changed }
        try beforeDelete()
        try persist(records.filter { $0.id != expected.id })
    }

    /// Account erasure must invalidate the shared cache in the same actor turn.
    public func removeConfiguration(_ removeFiles: @Sendable () throws -> Void) throws {
        try removeFiles()
        cache = []
        cacheStamp = FileStamp(url)
    }

    public func validate(_ expected: TargetRecord) throws {
        guard all().contains(expected) else { throw TargetRemovalError.changed }
    }

    // MARK: - Disk

    /// A corrupt file returns an empty list rather than refusing to start the
    /// daemon; the broken file is moved aside for inspection, not deleted.
    private func load() -> [TargetRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            // A `workloadProfile` key left by an old release is ignored here
            // and dropped by the next write: the property is gone.
            return try Self.decode(contentsOf: url)
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
        try Self.write(records, to: url)
        cache = records
        cacheStamp = FileStamp(url)
    }

    static func decode(contentsOf url: URL) throws -> [TargetRecord] {
        try JSONDecoder().decode([TargetRecord].self, from: Data(contentsOf: url))
    }

    /// `persist` with no store open, for adoption, which runs before one is.
    static func write(_ records: [TargetRecord], to url: URL) throws {
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
    }
}

/// Enough of a file's identity to notice that someone else replaced it: an
/// atomic write is a new inode. nil fields mean the file is absent.
struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let modified: timespec
    let size: off_t

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        modified = info.st_mtimespec
        size = info.st_size
    }

    static func == (a: FileStamp, b: FileStamp) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size
            && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
    }
}

public enum TargetRemovalError: Error, LocalizedError, Equatable {
    case inUse, beingRemoved, changed, duplicateID
    public var errorDescription: String? {
        switch self {
        case .inUse: "Target is in use; cannot remove it. Wait for active sessions to close and retry."
        case .beingRemoved: "Target is being removed; cannot log in. Retry after removal completes."
        case .changed: "Target configuration changed. Refresh and retry."
        case .duplicateID: "Multiple saved records share this target ID. Remove the target in the app to resolve the duplicate ID."
        }
    }
}
