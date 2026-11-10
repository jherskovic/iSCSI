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
//      iscsi://host[:port]/target/lun  --mount -F-->  ~/Library/Caches/.../<tag>/lun0.img
//      lun0.img  --hdiutil attach-->  /dev/diskN  --DiskArbitration-->  /Volumes/…
//
//  With the `ImageAttachEngine` preference on macOS 27 the middle step is
//  DiskImages2 instead (`attachWithDiskImages2`), which reads lun0.img
//  concurrently; `hdiutil` is the default and the fallback.
//
//  Each volume is then remounted `noatime` (`NoATimeRemount`): on a LUN, an
//  access-time update is a write to the target.
//

import AppKit
import Foundation
import iSCSIKit
import os

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
    /// The FSKit mount's source URL, kept for an orphan: with no record
    /// behind it, this is the only thing that says what it is.
    var mountSource: String? = nil
    /// Whether the disk's first MiB is all zeros (`PartitionTableProbe.isBlank`),
    /// as read when this app attached it; nil when not read. Only a blank
    /// disk is called "not formatted": one that holds anything else and did
    /// not mount may be data macOS cannot read — ext4, ZFS, a locked volume —
    /// and must never be met with advice to erase it.
    var isBlank: Bool? = nil
    /// Encrypted APFS volumes on the disk that are locked, by name: why a
    /// disk that is neither blank nor unreadable mounted nothing. Asked only
    /// when nothing mounted (`LockedAPFSVolumes`).
    var lockedVolumes: [String] = []

    var isFullyAttached: Bool { device != nil && !volumePaths.isEmpty }
    /// Mounted by this app, but no record derives its mount point any more:
    /// the target was edited while attached, or removed. `reconcile` finds
    /// these so they can still be detached.
    var isOrphan: Bool { targetID.isEmpty }

    /// What a detach found still up afterwards.
    struct Layers: Sendable {
        let device: String?
        let volumePaths: [String]
        let fskitMountPoint: String?

        var description: String {
            var parts: [String] = []
            if !volumePaths.isEmpty { parts.append(volumePaths.joined(separator: ", ")) }
            if let device { parts.append(device) }
            if fskitMountPoint != nil { parts.append("the volume serving the LUN") }
            return ListFormatter.localizedString(byJoining: parts)
        }
    }
}

enum DetachError: LocalizedError, Equatable {
    /// A plain unmount or detach was refused — nearly always because
    /// something has a file open on the volume. Carries the tool's own words,
    /// which name the process when `diskutil` knows it.
    case inUse(String)
    /// Teardown ran and something is still up.
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .inUse(let detail):
            return "The volume is in use, so it was not ejected. \(detail)"
        case .incomplete(let left):
            return "Detaching did not finish: \(left) is still attached."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .inUse:
            return "Quit the apps using files on it — Finder windows and Terminal "
                 + "sessions inside it count — and detach again."
        case .incomplete:
            return "Detach again. If the storage device is unreachable, detaching "
                 + "waits for it to answer."
        }
    }
}

enum AttachmentError: LocalizedError {
    case invalidAddress(String)
    case fskitMountFailed(String, duplicates: [String])
    case noImageServed(String)
    case imageAttachFailed(String)
    /// The same unit is mounted elsewhere already. `ownAccount`: by this
    /// user, under a mount point the record no longer derives.
    case alreadyAttached(at: String, ownAccount: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let host):
            return "“\(host)” is not an address the target can be reached at."
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
        case .alreadyAttached(_, let ownAccount):
            return ownAccount
                ? "This disk is already attached, under the settings the target had before it was edited."
                : "Another account on this Mac has this disk attached."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidAddress:
            return "Edit the target: enter a host name, an IPv4 address or an IPv6 "
                 + "address, without brackets, and put the port in the Port field."
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
        case .alreadyAttached(_, let ownAccount):
            return ownAccount
                ? "Detach it under Other Attached Disks, then attach again."
                : "Attaching it from two accounts at once would corrupt it. Detach it in that account first."
        }
    }
}

/// What the attach decided and why, for `/usr/bin/log` — the block size most
/// of all, which nothing else on screen shows.
private let attachLog = Logger(subsystem: "me.herko.iSCSIInitiator.app", category: "attach")

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
            do {
                try await detach(tag: orphan.tag)
            } catch DetachError.inUse {
                // Forced only once Finder has taken every filesystem on the
                // device down: what refused is the image or the FSKit volume
                // beneath them, which nothing can have a file open on any more.
                // That is the wedged-image case (docs/resilience.md), where a
                // forced detach is the only thing that frees DiskArbitration —
                // and every disk client on the Mac with it.
                guard let left = attachments.first(where: { $0.tag == orphan.tag }),
                      left.volumePaths.isEmpty else { return }
                attachLog.notice("after a Finder eject of \(path, privacy: .public): forcing the layers beneath it")
                do { try await detach(tag: orphan.tag, force: true) } catch {
                    attachLog.error("after a Finder eject of \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                // Left listed, for the Detach button to try again.
                attachLog.error("after a Finder eject of \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }


    /// Where this user's FSKit mounts go, one directory per `MountpointTag`.
    nonisolated static var cacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/me.herko.iSCSIInitiator")
    }

    nonisolated static func hiddenDirectory(tag: String) -> URL {
        cacheRoot.appendingPathComponent(tag)
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
        guard let base = MountResourceURL.make(host: target.host, port: target.port,
                                               target: target.targetIQN, lun: target.lun)
        else { throw AttachmentError.invalidAddress(target.host) }
        // Decided before the FSKit mount, because the volume serves the two
        // engines differently (`VolumeIOOptions`) and its mount URL is the only
        // way it can learn which one is coming.
        let engine = ImageAttachEngine.choose(
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            override: UserDefaults.standard.string(forKey: ImageAttachEngine.preferenceKey))
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if engine == .diskImages2 { components?.queryItems = [ImageAttachEngine.mountQuery] }
        let url = components?.url?.absoluteString ?? base.absoluteString
        let targetID = target.id

        // Before anything is mounted: another mount of this unit — another
        // account's, or this account's own under an address the record has
        // since changed — would make this a second writer on one filesystem.
        // The daemon refuses that too (`DaemonCore.claimedUnits`), but only
        // here can it be said in words the user can act on.
        if let other = AutoAttachRun.otherMount(ofTarget: target.targetIQN, lun: target.lun,
                                                mounts: Self.mountTable(), except: hiddenPath) {
            throw AttachmentError.alreadyAttached(
                at: other.on, ownAccount: other.on.hasPrefix(Self.cacheRoot.path + "/"))
        }

        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

        // Everything below shells out — `mount -F`, `hdiutil attach` — and each
        // call blocks until the target answers, which is *never* while it is
        // unreachable (measured 2026-09-11: `mount -F`'s login and `hdiutil
        // detach` both hang indefinitely under a wedged NAS). On `@MainActor`
        // that is a beach-balled app, so the blocking sequence runs on a
        // detached task over `Sendable` inputs and only the result crosses back.
        let probe: (device: String?, volumes: [String], isBlank: Bool?, locked: [String]) = try await Task.detached {
            // Idempotent: attaching something already attached should report the
            // existing volume, not stack a second mount on the same path.
            let fskitWasMounted = Self.isMounted(hiddenPath)
            if !fskitWasMounted {
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

            switch ImageAttachPlan.decide(fskitWasMounted: fskitWasMounted,
                                          existingDevice: Self.attachedDevice(forImage: imagePath)) {
            case .reuse(let existing):
                let volumes = Self.mountPoints(ofDevice: existing)
                Self.disableAccessTimes(on: volumes)
                let after = Self.unlockSavedVolumes(device: existing, volumes: volumes)
                return (existing, after.volumes, nil, after.locked)
            case .replaceStale(let stale):
                // Left by a logout that took the FSKit mount down but not the
                // device; it serves nothing, so forcing it off loses nothing.
                attachLog.notice("detaching stale \(stale, privacy: .public), left over from an earlier FSKit mount of \(imagePath, privacy: .public)")
                _ = try? Self.run("/usr/bin/hdiutil", ["detach", stale, "-force"])
            case .attach:
                break
            }
            // A GPT written with 4096-byte blocks is invisible at DiskImages'
            // default of 512 (GitHub issue #2), and a blank 4Kn LUN should be
            // partitioned at 4096; see PartitionTableProbe. Every other disk
            // gets the default.
            let (blockSize, isBlank) = Self.attachBlockSize(image: imagePath, volume: hiddenPath)

            var attached: (device: String?, volumes: [String])?
            if engine == .diskImages2 {
                do {
                    attached = try Self.attachWithDiskImages2(image: imagePath, blockSize: blockSize)
                } catch {
                    // Never attach the same image twice: if the newer engine
                    // got as far as a device, that is the attach.
                    if let device = Self.attachedDevice(forImage: imagePath) {
                        attachLog.error("DiskImages2 attach reported \(String(describing: error), privacy: .public), but \(device, privacy: .public) serves the image; using it")
                        attached = (device, Self.waitForVolumes(of: device, image: imagePath))
                    } else {
                        attachLog.error("DiskImages2 attach failed, falling back to hdiutil: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            let result = try attached ?? Self.attachWithHdiutil(image: imagePath, blockSize: blockSize)
            Self.disableAccessTimes(on: result.volumes)
            let after = Self.unlockSavedVolumes(device: result.device, volumes: result.volumes)
            return (result.device, after.volumes, isBlank, after.locked)
        }.value

        // Recorded before anything else can go wrong: throwing after the
        // layers are up leaves them mounted but invisible — not listed, not
        // detachable.
        let attachment = Attachment(tag: tag, targetID: targetID, hiddenPath: hiddenPath,
                                    device: probe.device, volumePaths: probe.volumes,
                                    isBlank: probe.isBlank, lockedVolumes: probe.locked)
        attachments.removeAll { $0.tag == tag }
        attachments.append(attachment)
        attachmentsGeneration &+= 1
        return attachment
    }

    /// Innermost first: the filesystem, then the raw device, then the FSKit
    /// volume that was serving the file underneath it. Detaching the outer
    /// layer while the inner one is live is how a volume gets ripped out from
    /// under a writer.
    ///
    /// Throws unless every layer is verifiably gone, and the list then shows
    /// what is still there rather than what was asked for. This used to
    /// discard every result and always report success, so a volume something
    /// still had open vanished from the app while staying mounted — and target
    /// removal, uninstall and Sparkle, each of which waits on a detach, went
    /// ahead over it.
    ///
    /// - Parameter force: when a plain unmount or detach is refused, force
    ///   it. Forcing takes the volume from whatever has files open on it, so
    ///   only a second, explicit "Force Eject" passes true (`AppModel.detach`);
    ///   everything else stops at `DetachError.inUse`.
    func detach(tag: String, force: Bool = false) async throws {
        let hidden = Self.hiddenDirectory(tag: tag)
        let hiddenPath = hidden.path
        let imagePath = hidden.appendingPathComponent("lun0.img").path

        // The teardown blocks: `diskutil unmountDisk` flushes and `hdiutil
        // detach` waits on the device, and both hang indefinitely while the
        // target is unreachable (measured 2026-09-11). This is the path that
        // actually beach-balls the app — a Detach tap, or a Finder eject routed
        // through `volumeDisappeared`, on a wedged mount — so it runs on a
        // detached task and only the list mutation happens back on the actor.
        let (failure, left) = await Task.detached { () -> (DetachError?, Attachment.Layers?) in
            let failure = Self.tearDown(image: imagePath, mountPoint: hiddenPath, force: force)
            return (failure, Self.layers(image: imagePath, mountPoint: hiddenPath))
        }.value

        if let left {
            // Something is still up: keep it listed — and detachable — as it is.
            if let index = attachments.firstIndex(where: { $0.tag == tag }) {
                attachments[index].device = left.device
                attachments[index].volumePaths = left.volumePaths
            }
        } else {
            attachments.removeAll { $0.tag == tag }
        }
        attachmentsGeneration &+= 1

        if let failure { throw failure }
        if let left { throw DetachError.incomplete(left.description) }
    }

    /// The teardown itself, each step checked. A step that fails is re-asked
    /// before it counts: the layer may have gone anyway — a Finder eject
    /// racing ours — and that is success, not refusal.
    nonisolated private static func tearDown(image: String, mountPoint: String,
                                             force: Bool) -> DetachError? {
        // Ask hdiutil which device is backed by *this* image: disk numbers
        // are reused, and detaching a stale one ejects somebody else's disk.
        if let device = attachedDevice(forImage: image) {
            let unmounted = try? run("/usr/sbin/diskutil", ["unmountDisk", device])
            if unmounted?.status != 0, !force, attachedDevice(forImage: image) != nil {
                return .inUse(unmounted?.combined ?? "diskutil did not run")
            }
            let detached = try? run("/usr/bin/hdiutil", ["detach", device])
            if detached?.status != 0, attachedDevice(forImage: image) != nil {
                guard force else { return .inUse(detached?.combined ?? "hdiutil did not run") }
                _ = try? run("/usr/bin/hdiutil", ["detach", device, "-force"])
            }
        }
        if isMounted(mountPoint) {
            let unmounted = try? run("/sbin/umount", [mountPoint])
            if unmounted?.status != 0, isMounted(mountPoint) {
                guard force else { return .inUse(unmounted?.combined ?? "umount did not run") }
                _ = try? run("/sbin/umount", ["-f", mountPoint])
            }
        }
        // `rmdir`, never `removeItem`: that recurses, and through a mount
        // point still up it would be deleting inside the LUN. An empty
        // directory is all that should be left; anything else stays.
        if !isMounted(mountPoint) { rmdir(mountPoint) }
        return nil
    }

    /// What of an attachment is still up, or nil when nothing is.
    nonisolated private static func layers(image: String, mountPoint: String) -> Attachment.Layers? {
        let device = attachedDevice(forImage: image)
        let fskitMounted = isMounted(mountPoint)
        guard device != nil || fskitMounted else { return nil }
        return Attachment.Layers(device: device,
                                 volumePaths: device.map { mountPoints(ofDevice: $0) } ?? [],
                                 fskitMountPoint: fskitMounted ? mountPoint : nil)
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
            var source: String? = nil
        }
        var recordMountPoints: Set<String> = []
        var candidates: [Candidate] = targets.compactMap { target in
            let portal = MountpointTag.portal(host: target.host, port: target.port)
            let tag = MountpointTag.derive(portal: portal, targetIQN: target.targetIQN,
                                           lun: target.lun)
            let hidden = Self.hiddenDirectory(tag: tag)
            recordMountPoints.insert(hidden.path)
            guard Self.isMounted(hidden.path) else { return nil }
            return Candidate(tag: tag, targetID: target.id, hiddenPath: hidden.path,
                             imagePath: hidden.appendingPathComponent("lun0.img").path)
        }
        // Orphans: this app's FSKit mounts that no record derives any more —
        // the target was edited while attached (its tag hashes the address,
        // name and unit) or removed. Listed, so they can be detached; before,
        // they stayed mounted with nothing in the app that could reach them.
        let root = Self.cacheRoot.path + "/"
        for entry in Self.mountTable() where entry.on.hasPrefix(root)
            && !recordMountPoints.contains(entry.on)
            && !entry.on.dropFirst(root.count).contains("/")
            && AutoAttachRun.mountedUnit(entry.from) != nil {
            candidates.append(Candidate(
                tag: String(entry.on.dropFirst(root.count)), targetID: "",
                hiddenPath: entry.on, imagePath: entry.on + "/lun0.img", source: entry.from))
        }
        let probes = candidates
        let found = await Task.detached { () -> [Attachment] in
            probes.map { candidate in
                let device = Self.attachedDevice(forImage: candidate.imagePath)
                let volumes = device.map { Self.mountPoints(ofDevice: $0) } ?? []
                return Attachment(
                    tag: candidate.tag, targetID: candidate.targetID,
                    hiddenPath: candidate.hiddenPath, device: device,
                    volumePaths: volumes,
                    mountSource: candidate.source,
                    lockedVolumes: Self.lockedVolumes(device: device, ifNoneOf: volumes))
            }
        }.value
        // Someone mutated the list while we were probing (a detach, an attach,
        // or a newer reconcile). Their state is fresher than ours; leave it.
        guard generation == attachmentsGeneration else { return }
        attachments = found
    }

    // MARK: - Asking the system

    /// The `-blocksize` for this image, from its first MiB — one read,
    /// through FSKit to the target like the attach that follows — and the
    /// LUN's block size, which the FSKit volume reports as its own (statfs
    /// `f_bsize`, iSCSIFSExtension `volumeStatistics`). nil if either read
    /// fails, which leaves the attach exactly as it was. The same read says
    /// whether the disk is blank; nil when it could not be read.
    nonisolated private static func attachBlockSize(
        image: String, volume: String
    ) -> (blockSize: Int?, isBlank: Bool?) {
        guard let handle = FileHandle(forReadingAtPath: image) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: PartitionTableProbe.prefixLength) else {
            return (nil, nil)
        }
        var stats = statfs()
        let lunBlockSize = statfs(volume, &stats) == 0 ? Int(stats.f_bsize) : nil
        let chosen = PartitionTableProbe.attachBlockSize(prefix: prefix, lunBlockSize: lunBlockSize)
        let isBlank = PartitionTableProbe.isBlank(prefix)
        attachLog.log("""
            block size: read \(prefix.count, privacy: .public) bytes, \
            GPT at \(PartitionTableProbe.gptBlockSize(prefix: prefix).map(String.init) ?? "none", privacy: .public), \
            LUN \(lunBlockSize.map(String.init) ?? "unknown", privacy: .public), \
            blank \(isBlank, privacy: .public) → \
            \(chosen.map { "-blocksize \($0)" } ?? "default", privacy: .public)
            """)
        return (chosen, isBlank)
    }

    /// The DiskImages engine, as every release before macOS 27 did it.
    /// -noverify: a raw LUN has no checksum, and verification would read the
    /// whole device over the network first.
    nonisolated private static func attachWithHdiutil(
        image: String, blockSize: Int?
    ) throws -> (device: String?, volumes: [String]) {
        var common = ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-noverify", "-plist"]
        if let blockSize { common += ["-blocksize", String(blockSize)] }
        common.append(image)
        var result = try run("/usr/bin/hdiutil", common)
        if result.status != 0 {
            // "No mountable file systems" is a *new* LUN, not a broken
            // attach; re-attach -nomount so Disk Utility has a device.
            let bare = try run("/usr/bin/hdiutil", common + ["-nomount"])
            guard bare.status == 0 else {
                throw AttachmentError.imageAttachFailed(result.combined)
            }
            result = bare
        }
        return parseAttachPlist(result.stdout)
    }

    /// The DiskImages2 engine (`ImageAttachEngine`): concurrent reads, and on
    /// macOS 27 the FSKit volume grants write-through so its page cache never
    /// holds a write the target has not acknowledged.
    ///
    /// `diskutil image attach` for the default block size; DiskImages2's own
    /// attach for any other, since `diskutil` has no block-size option. Both
    /// with auto-mount, which mounts what `hdiutil attach` would — and leaves
    /// an EFI partition alone, where `diskutil mountDisk` mounts it (measured
    /// 2026-10-31) — and simply attaches an image with nothing mountable.
    /// Throws when nothing got attached; the caller then uses `hdiutil`.
    nonisolated private static func attachWithDiskImages2(
        image: String, blockSize: Int?
    ) throws -> (device: String?, volumes: [String]) {
        var reported: String?
        if let blockSize {
            reported = try DiskImages2Attach.attach(image: URL(fileURLWithPath: image),
                                                    blockSize: blockSize, autoMount: true)
        } else {
            let result = try run("/usr/sbin/diskutil",
                                 ["image", "attach", "--mountPolicy", "autoMount", "--plist", image])
            guard result.status == 0 else { throw AttachmentError.imageAttachFailed(result.combined) }
            reported = parseAttachPlist(result.stdout).device
        }
        // The device as `hdiutil info` sees it, which is what reuse and detach
        // ask too, so all three agree on which disk this image is. `diskutil`
        // and DiskImages2 name it without "/dev/".
        let fallback = reported.map { $0.hasPrefix("/dev/") ? $0 : "/dev/\($0)" }
        guard let device = attachedDevice(forImage: image) ?? fallback else {
            throw AttachmentError.imageAttachFailed("DiskImages2 attached nothing for \(image)")
        }
        attachLog.log("""
            attached \(device, privacy: .public) with DiskImages2\
            \(blockSize.map { " at \($0)-byte blocks" } ?? "", privacy: .public)
            """)
        return (device, waitForVolumes(of: device, image: image))
    }

    /// The device's mount points, giving auto-mount up to five seconds to
    /// finish. An image whose only entity is the whole disk has nothing to
    /// mount (a blank LUN) and returns at once.
    nonisolated private static func waitForVolumes(of device: String, image: String) -> [String] {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let points = mountPoints(ofDevice: device)
            if !points.isEmpty || !hasPartitions(image: image) { return points }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return mountPoints(ofDevice: device)
    }

    /// Whether `hdiutil info` lists anything under this image besides the
    /// whole disk.
    nonisolated private static func hasPartitions(image: String) -> Bool {
        guard let result = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
              result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(
                from: result.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]],
              let entry = images.first(where: { $0["image-path"] as? String == image }),
              let entities = entry["system-entities"] as? [[String: Any]]
        else { return false }
        return entities.count > 1
    }

    /// The locked encrypted volumes on `device`, when nothing of it mounted.
    /// `diskutil apfs list` reads container metadata already in memory, so it
    /// does not wait on the target; and it only runs when there is something
    /// to explain.
    nonisolated private static func lockedVolumes(device: String?, ifNoneOf volumes: [String]) -> [String] {
        guard let device, volumes.isEmpty else { return [] }
        let locked = lockedAPFSVolumes(onDevice: device).map(\.name)
        if !locked.isEmpty {
            attachLog.log("\(device, privacy: .public) holds locked encrypted volumes: \(locked.joined(separator: ", "), privacy: .public)")
        }
        return locked
    }

    nonisolated private static func lockedAPFSVolumes(onDevice device: String) -> [LockedAPFSVolumes.Volume] {
        guard let result = try? run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
              result.status == 0 else { return [] }
        return LockedAPFSVolumes.find(onDisk: device, apfsList: result.stdout)
    }

    /// An attach's last step when nothing of the disk mounted: unlock each
    /// locked encrypted volume whose password macOS saved in the keychain
    /// (`EncryptedVolumePassword`), then report what is mounted and what is
    /// still locked, with the same rule as `lockedVolumes`: locked volumes
    /// are only reported while nothing mounted.
    ///
    /// Best effort, and silent. No saved password, a denied keychain prompt,
    /// a wrong password or a volume that will not mount leaves that volume
    /// locked and is only logged; the attach itself has succeeded either way.
    nonisolated private static func unlockSavedVolumes(
        device: String?, volumes: [String]
    ) -> (volumes: [String], locked: [String]) {
        guard let device, volumes.isEmpty else { return (volumes, []) }
        let locked = lockedAPFSVolumes(onDevice: device)
        guard !locked.isEmpty else { return (volumes, []) }
        var unlockedAny = false
        for volume in locked {
            guard let uuid = volume.uuid,
                  let password = EncryptedVolumePassword.saved(forVolumeUUID: uuid) else { continue }
            // Unprivileged, and it mounts the volume as well (0.28 s on the
            // 26 VM). On stdin, so the password is in no argument list.
            let result = try? run("/usr/sbin/diskutil",
                                  ["apfs", "unlockVolume", volume.identifier, "-stdinpassphrase"],
                                  input: password)
            if result?.status == 0 {
                unlockedAny = true
                attachLog.log("unlocked \(volume.name, privacy: .public) (\(volume.identifier, privacy: .public)) with its saved password")
            } else {
                attachLog.notice("could not unlock \(volume.name, privacy: .public) with its saved password: \(result?.combined ?? "diskutil did not run", privacy: .public)")
            }
        }
        guard unlockedAny else {
            let names = locked.map(\.name)
            attachLog.log("\(device, privacy: .public) holds locked encrypted volumes: \(names.joined(separator: ", "), privacy: .public)")
            return (volumes, names)
        }
        // `diskutil` has mounted it by the time it returns; hdiutil's view of
        // the mount can trail by a moment.
        var mounted = mountPoints(ofDevice: device)
        for _ in 0 ..< 8 where mounted.isEmpty {
            Thread.sleep(forTimeInterval: 0.25)
            mounted = mountPoints(ofDevice: device)
        }
        disableAccessTimes(on: mounted)
        return (mounted, lockedVolumes(device: device, ifNoneOf: mounted))
    }

    nonisolated private static func isMounted(_ path: String) -> Bool {
        mountTable().contains { $0.on == path }
    }

    /// Remount each volume `noatime`, keeping its other options
    /// (`NoATimeRemount` says why both halves matter). Best effort: a volume
    /// that refuses keeps its access times and the attach still succeeds —
    /// this saves metadata writes, it is not what makes the volume usable.
    /// Runs on the attach's detached task, so a slow remount blocks nothing.
    nonisolated private static func disableAccessTimes(on volumes: [String]) {
        for path in volumes {
            var info = statfs()
            guard statfs(path, &info) == 0,
                  let options = NoATimeRemount.options(forMountFlags: info.f_flags)
            else { continue }
            let result = try? run("/sbin/mount", ["-u", "-o", options, path])
            if result?.status == 0 {
                attachLog.log("remounted \(path, privacy: .public) with \(options, privacy: .public)")
            } else {
                attachLog.error("""
                    could not remount \(path, privacy: .public) noatime: \
                    \(result?.combined ?? "mount did not run", privacy: .public)
                    """)
            }
        }
    }

    /// Every mount on this Mac, every user's. getmntinfo: no subprocess, no
    /// locale, no substring false matches, and `MNT_NOWAIT`, so it cannot
    /// block on a wedged target.
    ///
    /// The `_r_np` form, with a buffer of our own: plain `getmntinfo` returns
    /// one static buffer that the next call may free, and the attach-at-login
    /// run reads the table on the main actor while attach and detach read it
    /// on detached tasks.
    nonisolated static func mountTable() -> [MountTableEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard let buffer else { return [] }
        defer { free(buffer) }
        guard count > 0 else { return [] }
        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return MountTableEntry(from: cString(&entry.f_mntfromname),
                                   on: cString(&entry.f_mntonname),
                                   isFSKit: entry.f_flags_ext & UInt32(MNT_EXT_FSKIT) != 0)
        }
    }

    nonisolated private static func cString<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
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

    /// Parse `hdiutil attach -plist` or `diskutil image attach --plist`; the
    /// latter names devices without "/dev/".
    nonisolated private static func parseAttachPlist(_ data: Data) -> (device: String?, volumes: [String]) {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return (nil, []) }

        var device: String?
        var volumes: [String] = []
        for entity in entities {
            if let dev = entity["dev-entry"] as? String, device == nil,
               dev.range(of: #"^(/dev/)?disk\d+$"#, options: .regularExpression) != nil {
                device = dev.hasPrefix("/dev/") ? dev : "/dev/\(dev)"
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

    /// - Parameter input: written to the child's stdin, which is then closed;
    ///   how a secret reaches a tool without appearing in its arguments.
    @discardableResult
    nonisolated private static func run(_ path: String, _ arguments: [String],
                                        input: Data? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        try process.run()
        if let stdin, let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
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
