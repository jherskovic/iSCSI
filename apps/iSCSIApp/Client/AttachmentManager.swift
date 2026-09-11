//
//  AttachmentManager.swift
//  Turning a configured target into a volume in Finder, and back.
//
//  Lives in the app, not the daemon: the whole path is unprivileged and
//  user-context — `mount -F` resolves the module through the *user's*
//  fskit_agent, and a root daemon's lookup goes to fskitd, which holds no
//  third-party modules (docs/backend-a-fskit-notes.md).
//
//  Two layers, and the order matters in both directions:
//
//      iscsi://portal/target/lun  --mount -F-->  ~/Library/Caches/.../<tag>/lun0.img
//      lun0.img  --hdiutil attach-->  /dev/diskN  --DiskArbitration-->  /Volumes/…
//

import AppKit
import Foundation
import iSCSIKit

struct Attachment: Identifiable, Equatable, Sendable {
    var id: String { tag }
    let tag: String
    let targetID: String
    /// Where the FSKit volume is mounted; the LUN appears inside as lun0.img.
    let hiddenPath: String
    /// /dev/diskN of the attached raw image, when the image layer is up.
    var device: String?
    /// Where the user's data actually appears. Empty when the LUN is blank or
    /// carries a filesystem macOS will not mount.
    var volumePaths: [String]

    var isFullyAttached: Bool { device != nil && !volumePaths.isEmpty }
}

enum AttachmentError: LocalizedError {
    case fskitMountFailed(String, duplicates: [String])
    case noImageServed(String)
    case imageAttachFailed(String)
    case blankLUN(device: String)

    var errorDescription: String? {
        switch self {
        case .fskitMountFailed(let detail, let duplicates):
            if duplicates.isEmpty {
                return "Could not serve the LUN as a file: \(detail)"
            }
            // Reached only when the automatic repair did not help; say that.
            return "Could not serve the LUN as a file, even after removing "
                 + "\(duplicates.count) stale copy(s) of the filesystem extension. "
                 + "Details: \(detail)"
        case .noImageServed(let path):
            return "The filesystem extension mounted but produced no LUN file at \(path)."
        case .imageAttachFailed(let detail):
            return "Could not attach the LUN as a disk: \(detail)"
        case .blankLUN(let device):
            return "The LUN attached as \(device) but has not been formatted yet."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fskitMountFailed(_, let duplicates):
            if duplicates.isEmpty {
                return "Check that the background service is running and the filesystem "
                     + "extension is enabled, on the Setup screen."
            }
            // The extra copies are already gone; a relaunch settles whatever
            // still holds the old registration.
            return "The extra copies were removed. Quit and reopen the app, then "
                 + "try again. If a disk image of an older version is still "
                 + "mounted in Finder, eject it first — that is usually where "
                 + "the extra copies come from."
        case .noImageServed:
            return "The connection to the target may have dropped. Try again."
        case .imageAttachFailed:
            return nil
        case .blankLUN:
            return "Use Disk Utility to erase and format it, then attach again."
        }
    }
}

@MainActor
final class AttachmentManager: ObservableObject {
    @Published private(set) var attachments: [Attachment] = []

    /// Bumped by every `attachments` mutation. `reconcile` now suspends between
    /// snapshotting what is mounted and publishing the result (the blocking
    /// `hdiutil info` probe runs off the main actor), and the main actor is free
    /// during that suspension. A `detach` — a Detach tap, or a Finder eject via
    /// `volumeDisappeared` — or an `attach` that lands in that window would be
    /// clobbered when `reconcile` resumes and overwrites the whole list,
    /// resurrecting a volume the user just removed or dropping one just added.
    /// So `reconcile` captures this on entry and skips its publish if anyone
    /// mutated the list while it was probing; a later foreground/refresh
    /// reconciles again from the settled state.
    private var attachmentsGeneration = 0

    private var unmountObserver: NSObjectProtocol?

    init() {
        // A Finder eject takes down the APFS volume and disk image but leaves
        // the FSKit mount — and the iSCSI session behind it — running until
        // noticed. NSWorkspace rather than DiskArbitration: "did a volume go
        // away" is exactly what the workspace notification answers.
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }
            MainActor.assumeIsolated { self?.volumeDisappeared(at: url.path) }
        }
    }

    /// A volume we put there has gone. Take down what is left underneath it.
    private func volumeDisappeared(at path: String) {
        guard let orphan = attachments.first(where: { $0.volumePaths.contains(path) })
        else { return }
        Task {
            // detach() tolerates layers already gone, so one path handles both
            // Finder ejects and the Detach button.
            try? await detach(tag: orphan.tag)
        }
    }

    static func hiddenDirectory(tag: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/me.herko.iSCSIInitiator")
            .appendingPathComponent(tag)
    }

    func attach(_ target: TargetRecordView) async throws -> Attachment {
        let portal = MountpointTag.portal(host: target.host, port: target.port)
        let tag = MountpointTag.derive(portal: portal, targetIQN: target.targetIQN,
                                       lun: target.lun)
        let hidden = Self.hiddenDirectory(tag: tag)
        let hiddenPath = hidden.path
        let imagePath = hidden.appendingPathComponent("lun0.img").path
        // `-t iSCSI` is the FSKit module's short name, not a protocol; the
        // scheme only names the protocol for anyone reading the mount table,
        // and the daemon decides from the target name.
        let scheme = IQN.isNQN(target.targetIQN) ? "nvme" : "iscsi"
        let url = "\(scheme)://\(portal)/\(target.targetIQN)/\(target.lun)"
        let targetID = target.id

        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

        // Everything below shells out — `mount -F`, `hdiutil attach` — and each
        // call blocks until the target answers, which is *never* while it is
        // unreachable (measured 2026-09-11: `mount -F`'s login and `hdiutil
        // detach` both hang indefinitely under a wedged NAS). On `@MainActor`
        // that is a beach-balled app, so the blocking sequence runs on a
        // detached task over `Sendable` inputs and only the result crosses back.
        let probe: (device: String?, volumes: [String]) = try await Task.detached {
            // Idempotent: attaching something already attached should report the
            // existing volume, not stack a second mount on the same path.
            if !Self.isMounted(hiddenPath) {
                let result = try Self.run("/sbin/mount",
                                          ["-F", "-t", "iSCSI", url, hiddenPath])
                if result.status != 0 {
                    // "File system named iSCSI not found" is as often "installed
                    // more than once" as "not installed". Prune, retry once, and
                    // only explain if that still fails.
                    let pruned = FSKitRegistrationAudit.pruneDuplicates()
                    var retried: ProcessResult?
                    if !pruned.isEmpty {
                        retried = try? Self.run("/sbin/mount",
                                                ["-F", "-t", "iSCSI", url, hiddenPath])
                    }
                    if retried?.status != 0 {
                        throw AttachmentError.fskitMountFailed(
                            (retried ?? result).combined, duplicates: pruned)
                    }
                }
            }

            guard FileManager.default.fileExists(atPath: imagePath) else {
                throw AttachmentError.noImageServed(imagePath)
            }

            if let existing = Self.attachedDevice(forImage: imagePath) {
                return (existing, Self.mountPoints(ofDevice: existing))
            }
            // -noverify: a raw LUN has no checksum, and verification would
            // read the whole device over the network first.
            let common = ["attach", "-imagekey", "diskimage-class=CRawDiskImage",
                          "-noverify", "-plist", imagePath]
            var result = try Self.run("/usr/bin/hdiutil", common)
            if result.status != 0 {
                // "No mountable file systems" is a *new* LUN, not a broken
                // attach; re-attach -nomount so Disk Utility has a device.
                let bare = try Self.run("/usr/bin/hdiutil", common + ["-nomount"])
                guard bare.status == 0 else {
                    throw AttachmentError.imageAttachFailed(result.combined)
                }
                result = bare
            }
            return Self.parseAttachPlist(result.stdout)
        }.value

        // Recorded before anything else can go wrong: throwing after the
        // layers are up leaves them mounted but invisible — not listed, not
        // detachable.
        let attachment = Attachment(tag: tag, targetID: targetID, hiddenPath: hiddenPath,
                                    device: probe.device, volumePaths: probe.volumes)
        attachments.removeAll { $0.tag == tag }
        attachments.append(attachment)
        attachmentsGeneration &+= 1
        return attachment
    }

    /// Innermost first: the filesystem, then the raw device, then the FSKit
    /// volume that was serving the file underneath it. Detaching the outer
    /// layer while the inner one is live is how a volume gets ripped out from
    /// under a writer.
    func detach(tag: String) async throws {
        let hidden = Self.hiddenDirectory(tag: tag)
        let hiddenPath = hidden.path
        let imagePath = hidden.appendingPathComponent("lun0.img").path

        // The teardown blocks: `diskutil unmountDisk` flushes and `hdiutil
        // detach` waits on the device, and both hang indefinitely while the
        // target is unreachable (measured 2026-09-11). This is the path that
        // actually beach-balls the app — a Detach tap, or a Finder eject routed
        // through `volumeDisappeared`, on a wedged mount — so it runs on a
        // detached task and only the list mutation happens back on the actor.
        await Task.detached {
            // Ask hdiutil which device is backed by *this* image: disk numbers
            // are reused, and detaching a stale one ejects somebody else's disk.
            if let device = Self.attachedDevice(forImage: imagePath) {
                _ = try? Self.run("/usr/sbin/diskutil", ["unmountDisk", device])
                let detached = try? Self.run("/usr/bin/hdiutil", ["detach", device])
                if detached?.status != 0 {
                    _ = try? Self.run("/usr/bin/hdiutil", ["detach", device, "-force"])
                }
            }
            if Self.isMounted(hiddenPath) {
                let unmounted = try? Self.run("/sbin/umount", [hiddenPath])
                if unmounted?.status != 0 {
                    _ = try? Self.run("/sbin/umount", ["-f", hiddenPath])
                }
            }
            // The directory is a mount point, never storage; it should be empty
            // by the time it is removed.
            try? FileManager.default.removeItem(atPath: hiddenPath)
        }.value

        attachments.removeAll { $0.tag == tag }
        attachmentsGeneration &+= 1
    }

    /// Rebuild the list from what is actually mounted.
    ///
    /// Runs at launch and whenever the app returns to the foreground, because
    /// the user can eject in Finder and nothing tells us.
    func reconcile(targets: [TargetRecordView]) async {
        // Two phases, split by what can block. Resolving tags and asking
        // `getmntinfo(MNT_NOWAIT)` whether our mount points exist touches no
        // filesystem, so it stays on the main actor. Probing each attachment
        // shells out to `hdiutil info`, which blocks for as long as a wedged
        // disk image takes to answer — which is *forever* while its NVMe/TCP
        // or iSCSI target is unreachable. Running that inline on `@MainActor`
        // beach-balled the whole app for the 15 minutes a dead NAS took to be
        // noticed on 2026-09-11. So the blocking half runs off the main actor
        // and only the result is published back on it. `Candidate` and
        // `Attachment` are `Sendable`, so nothing non-Sendable crosses.
        //
        // Bump-and-capture the generation around the suspension so a `detach`
        // or `attach` that lands while `hdiutil info` runs is not overwritten
        // by our stale snapshot (see `attachmentsGeneration`).
        attachmentsGeneration &+= 1
        let generation = attachmentsGeneration
        struct Candidate: Sendable {
            let tag: String, targetID: String, hiddenPath: String, imagePath: String
        }
        let candidates: [Candidate] = targets.compactMap { target in
            let portal = MountpointTag.portal(host: target.host, port: target.port)
            let tag = MountpointTag.derive(portal: portal, targetIQN: target.targetIQN,
                                           lun: target.lun)
            let hidden = Self.hiddenDirectory(tag: tag)
            guard Self.isMounted(hidden.path) else { return nil }
            return Candidate(tag: tag, targetID: target.id, hiddenPath: hidden.path,
                             imagePath: hidden.appendingPathComponent("lun0.img").path)
        }
        let found = await Task.detached { () -> [Attachment] in
            candidates.map { candidate in
                let device = Self.attachedDevice(forImage: candidate.imagePath)
                return Attachment(
                    tag: candidate.tag, targetID: candidate.targetID,
                    hiddenPath: candidate.hiddenPath, device: device,
                    volumePaths: device.map { Self.mountPoints(ofDevice: $0) } ?? [])
            }
        }.value
        // Someone mutated the list while we were probing (a detach, an attach,
        // or a newer reconcile). Their state is fresher than ours; leave it.
        guard generation == attachmentsGeneration else { return }
        attachments = found
    }

    // MARK: - Asking the system

    nonisolated private static func isMounted(_ path: String) -> Bool {
        // getmntinfo: no subprocess, no locale, no substring false matches.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return false }
        for index in 0..<Int(count) {
            let entry = buffer[index]
            let mounted = withUnsafeBytes(of: entry.f_mntonname) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if mounted == path { return true }
        }
        return false
    }

    /// Which /dev/diskN is serving a given image, according to hdiutil.
    nonisolated private static func attachedDevice(forImage path: String) -> String? {
        guard let result = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
              result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: result.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }

        for image in images where image["image-path"] as? String == path {
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            // The whole-disk entry, not a partition: detaching needs the parent.
            for entity in entities {
                if let dev = entity["dev-entry"] as? String,
                   dev.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil {
                    return dev
                }
            }
        }
        return nil
    }

    /// Where a device's filesystems are mounted. Asks hdiutil, not
    /// `mount | grep`: APFS mounts a *synthesized* container under a different
    /// disk number, so device-number matching reports healthy volumes as
    /// unmounted.
    nonisolated private static func mountPoints(ofDevice device: String) -> [String] {
        guard let result = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
              result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: result.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }

        var points: [String] = []
        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            guard entities.contains(where: { ($0["dev-entry"] as? String) == device })
            else { continue }
            for entity in entities {
                if let point = entity["mount-point"] as? String, !point.isEmpty {
                    points.append(point)
                }
            }
        }
        return points
    }

    /// Parse `hdiutil attach -plist`.
    nonisolated private static func parseAttachPlist(_ data: Data) -> (device: String?, volumes: [String]) {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return (nil, []) }

        var device: String?
        var volumes: [String] = []
        for entity in entities {
            if let dev = entity["dev-entry"] as? String, device == nil,
               dev.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil {
                device = dev
            }
            if let point = entity["mount-point"] as? String, !point.isEmpty {
                volumes.append(point)
            }
        }
        return (device, volumes)
    }

    struct ProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var combined: String {
            let out = String(data: stdout, encoding: .utf8) ?? ""
            let err = String(data: stderr, encoding: .utf8) ?? ""
            return [err, out].filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: hdiutil's -plist output can fill the pipe
        // buffer, and an undrained child blocks forever.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }
}

/// What `AttachmentManager` needs to know about a target. A protocol-shaped view
/// rather than `TargetRecord` itself so this file does not depend on the XPC
/// models, and so tests can drive it with a stub.
protocol TargetRecordView {
    var id: String { get }
    var host: String { get }
    var port: UInt16 { get }
    var targetIQN: String { get }
    var lun: UInt64 { get }
}

extension TargetRecord: TargetRecordView {}
