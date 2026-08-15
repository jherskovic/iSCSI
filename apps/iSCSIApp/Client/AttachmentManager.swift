//
//  AttachmentManager.swift
//  Turning a configured target into a volume in Finder, and back.
//
//  Ported from scripts/iscsi-attach.sh and iscsi-detach.sh, which were the only
//  working end-to-end path this project had. The semantics are preserved
//  deliberately, including the mountpoint tag, so mounts made by the bash era
//  are still recognised by this code.
//
//  It lives in the app rather than the daemon because the whole path turned out
//  to be unprivileged and user-context: `mount -F` resolves the module through
//  the *user's* fskit_agent — a root daemon's lookup goes to fskitd, which holds
//  no third-party modules — and neither the mount nor `hdiutil attach` needs
//  root. Measured; see the R2 section of docs/backend-a-fskit-notes.md.
//
//  Two layers, and the order matters in both directions:
//
//      iscsi://portal/target/lun  --mount -F-->  ~/Library/Caches/.../<tag>/lun0.img
//      lun0.img  --hdiutil attach-->  /dev/diskN  --DiskArbitration-->  /Volumes/…
//

import Foundation
import iSCSIKit

struct Attachment: Identifiable, Equatable, Sendable {
    var id: String { tag }
    /// sha256(portal|target|lun) truncated — see `MountpointTag`.
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
    case fskitMountFailed(String)
    case noImageServed(String)
    case imageAttachFailed(String)
    case blankLUN(device: String)

    var errorDescription: String? {
        switch self {
        case .fskitMountFailed(let detail):
            return "Could not serve the LUN as a file: \(detail)"
        case .noImageServed(let path):
            return "The filesystem extension mounted but produced no LUN file at \(path)."
        case .imageAttachFailed(let detail):
            return "Could not attach the LUN as a disk: \(detail)"
        case .blankLUN(let device):
            return "The LUN attached as \(device) but carries no filesystem macOS can mount."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fskitMountFailed:
            return "Check that the background service is running and the filesystem "
                 + "extension is enabled, on the Setup screen."
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

    static func hiddenDirectory(tag: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/me.herko.iSCSIInitiator")
            .appendingPathComponent(tag)
    }

    // MARK: - Attach

    func attach(_ target: TargetRecordView) async throws -> Attachment {
        let portal = MountpointTag.portal(host: target.host, port: target.port)
        let tag = MountpointTag.derive(portal: portal, targetIQN: target.targetIQN,
                                       lun: target.lun)
        let hidden = Self.hiddenDirectory(tag: tag)

        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

        // Idempotent: attaching something already attached should report the
        // existing volume, not fail or stack a second mount on the same path.
        if !Self.isMounted(hidden.path) {
            let url = "iscsi://\(portal)/\(target.targetIQN)/\(target.lun)"
            let result = try Self.run("/sbin/mount",
                                      ["-F", "-t", "iSCSI", url, hidden.path])
            guard result.status == 0 else {
                throw AttachmentError.fskitMountFailed(result.combined)
            }
        }

        let image = hidden.appendingPathComponent("lun0.img")
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw AttachmentError.noImageServed(image.path)
        }

        var attachment = Attachment(tag: tag, targetID: target.id,
                                    hiddenPath: hidden.path, device: nil, volumePaths: [])

        if let existing = Self.attachedDevice(forImage: image.path) {
            attachment.device = existing
            attachment.volumePaths = Self.mountPoints(ofDevice: existing)
        } else {
            // -noverify: there is no checksum on a raw LUN, and verification
            // would read the whole device across the network before anything
            // could be mounted.
            let result = try Self.run("/usr/bin/hdiutil",
                                      ["attach", "-imagekey", "diskimage-class=CRawDiskImage",
                                       "-noverify", "-plist", image.path])
            guard result.status == 0 else {
                throw AttachmentError.imageAttachFailed(result.combined)
            }
            let (device, volumes) = Self.parseAttachPlist(result.stdout)
            attachment.device = device
            attachment.volumePaths = volumes
        }

        // A blank LUN attaches fine and mounts nothing. That is a real state a
        // user reaches by adding a brand-new LUN, and it needs to say so rather
        // than look like a failure or, worse, like success.
        if attachment.volumePaths.isEmpty, let device = attachment.device {
            throw AttachmentError.blankLUN(device: device)
        }

        attachments.removeAll { $0.tag == tag }
        attachments.append(attachment)
        return attachment
    }

    // MARK: - Detach

    /// Innermost first: the filesystem, then the raw device, then the FSKit
    /// volume that was serving the file underneath it. Detaching the outer
    /// layer while the inner one is live is how a volume gets ripped out from
    /// under a writer.
    func detach(tag: String) async throws {
        let hidden = Self.hiddenDirectory(tag: tag)
        let image = hidden.appendingPathComponent("lun0.img")

        // Ask hdiutil which device is backed by *this* image rather than
        // remembering one: a disk number can be reused, and detaching a stale
        // number would eject somebody else's disk.
        if let device = Self.attachedDevice(forImage: image.path) {
            _ = try? Self.run("/usr/sbin/diskutil", ["unmountDisk", device])
            let detached = try? Self.run("/usr/bin/hdiutil", ["detach", device])
            if detached?.status != 0 {
                _ = try? Self.run("/usr/bin/hdiutil", ["detach", device, "-force"])
            }
        }

        if Self.isMounted(hidden.path) {
            let unmounted = try? Self.run("/sbin/umount", [hidden.path])
            if unmounted?.status != 0 {
                _ = try? Self.run("/sbin/umount", ["-f", hidden.path])
            }
        }

        // rmdir, never rm -rf. The directory is a mount point, never storage —
        // so if anything is left in it, something is wrong, and deleting it
        // silently would destroy the evidence along with whatever it was.
        try? FileManager.default.removeItem(at: hidden)

        attachments.removeAll { $0.tag == tag }
    }

    /// Rebuild the list from what is actually mounted.
    ///
    /// Runs at launch and whenever the app returns to the foreground, because
    /// the user can eject in Finder and nothing tells us. The plan had the
    /// daemon reconciling this across restarts; app-side it is simply the same
    /// every-launch check the setup machine already does.
    func reconcile(targets: [TargetRecordView]) {
        var found: [Attachment] = []
        for target in targets {
            let portal = MountpointTag.portal(host: target.host, port: target.port)
            let tag = MountpointTag.derive(portal: portal, targetIQN: target.targetIQN,
                                           lun: target.lun)
            let hidden = Self.hiddenDirectory(tag: tag)
            guard Self.isMounted(hidden.path) else { continue }

            let image = hidden.appendingPathComponent("lun0.img").path
            let device = Self.attachedDevice(forImage: image)
            found.append(Attachment(
                tag: tag, targetID: target.id, hiddenPath: hidden.path,
                device: device,
                volumePaths: device.map { Self.mountPoints(ofDevice: $0) } ?? []))
        }
        attachments = found
    }

    // MARK: - Asking the system

    private static func isMounted(_ path: String) -> Bool {
        // getmntinfo rather than parsing `mount` output: no subprocess, no
        // locale, and no false match on a path that merely contains another.
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
    private static func attachedDevice(forImage path: String) -> String? {
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

    /// Where a device's filesystems are mounted.
    ///
    /// Asks hdiutil, not `mount | grep <device>`. APFS mounts a *synthesized*
    /// container with a different disk number — disk8 becomes disk9s1 — so
    /// matching on the device number reports "not mounted" for a perfectly
    /// healthy volume. The bash version learned this the hard way and the
    /// comment survives at iscsi-attach.sh:77.
    private static func mountPoints(ofDevice device: String) -> [String] {
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
    ///
    /// The bash version used `awk 'NR==1'` on human-readable output, which is
    /// whitespace- and locale-dependent and silently wrong the moment hdiutil
    /// reorders a column.
    private static func parseAttachPlist(_ data: Data) -> (device: String?, volumes: [String]) {
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
    private static func run(_ path: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: a child that fills the pipe buffer blocks
        // forever if nobody drains it, and hdiutil -plist output is large
        // enough to matter.
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
