//
//  iSCSIFSExtension.swift
//  Backend A: an FSKit module that presents a LUN as a regular file, so that
//  `hdiutil attach -imagekey diskimage-class=CRawDiskImage <file>` yields a real
//  /dev/diskN. The block device then comes from Apple's DiskImages framework
//  instead of our DriverKit dext, which is how this backend routes around the
//  wedge documented in docs/feedback-virtual-scsi-wedge.md.
//
//  The resource URL selects the backing store:
//
//    iscsi://proto/lun0                      -> a local sparse file, no network.
//                                               Verified working end to end and
//                                               kept so FSKit problems can be
//                                               separated from network ones.
//    iscsi://[user@]host[:port]/<iqn>/<lun>  -> a real session, forwarded to
//                                               iscsid over XPC.
//
//  Both Backend A risks have been settled (docs/backend-a-fskit-notes.md):
//  DiskImages *will* attach a file living on an FSKit volume, and our read/write
//  path is genuinely used — 123 writes / 38.9 MB in the reference run, 1 MiB max
//  I/O, nothing offloaded behind our back.
//
//  ⚠️ There is NO barrier signal. `synchronize` is never called — not by
//  sync(8), not by fsync(), not by F_FULLFSYNC on the served file. The only
//  durability hook is `closeItem` with no retained modes, so the iSCSI store
//  issues SYNCHRONIZE CACHE there and the target should also be write-through.
//  Do not add code that assumes a barrier will arrive.
//
//  API notes:
//   - FSVolume.Operations is deprecated in macOS 27 in favour of FSVolumeHandler,
//     but FSVolumeHandler is V3-only and the test VM runs 26.6.1, so this
//     targets FSVolume.Operations on purpose.
//   - FSGenericURLResource is macOS 26.0. Every FS* Info.plist key must live
//     inside EXAppExtensionAttributes or FSKit silently ignores it.
//

import FSKit
import Foundation
import iSCSIKit
import iSCSIVolume
import os

/// Name of the single file the volume exposes; this is what hdiutil attaches.
private let kImageName = "lun0.img"



/// Fixed directory for prototype backing files. Nothing derived from a resource
/// URL is ever allowed to change this.
///
/// It must live inside the extension's sandbox container: the appex is built
/// with `com.apple.security.app-sandbox`, so opening a path under /Users/Shared
/// fails with EPERM and `loadResource` reports "Operation not permitted".
/// For a sandboxed extension `NSHomeDirectory()` is the container root.
///
/// This is prototype-only storage. Nothing outside the extension ever needs to
/// see it — the bytes are served *as* a file by this filesystem, so the backing
/// store does not have to be visible to hdiutil or anyone else.
private let kProtoBackingDir = NSHomeDirectory() + "/Documents"


/// Reduces a caller-supplied URL to a single safe filename component.
///
/// An FSKit resource URL is caller-influenced input: `iscsi://h/../../etc/x`
/// would otherwise let a mount request pick the file this extension creates and
/// writes. Only `[A-Za-z0-9._-]` survives, `.` and `..` are rejected outright,
/// and the result is length-bounded — so the value can never contain a path
/// separator or traverse upward.
private func safeTag(from url: URL) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    let filtered = String(url.lastPathComponent.filter { allowed.contains($0) }.prefix(64))
    if filtered.isEmpty || filtered == "." || filtered == ".." { return "default" }
    return filtered
}

/// Describes a URL for logging without leaking credentials.
///
/// An iSCSI URL may carry `user:password@host`; `absoluteString` would put that
/// straight into the system log, which is readable beyond this process.
private func redact(_ url: URL) -> String {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    parts?.user = nil
    parts?.password = nil
    return parts?.string ?? url.scheme.map { "\($0)://<redacted>" } ?? "<redacted>"
}

// MARK: - Extension entry point

/// The Info.plist declares this as the principal class.
@main
final class ISCSIFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: ISCSIUnaryFileSystem { ISCSIUnaryFileSystem() }
}

final class ProtoItem: FSItem {
    let name: FSFileName
    let itemType: FSItem.ItemType
    let itemID: FSItem.Identifier
    var size: UInt64

    init(name: String, type: FSItem.ItemType, id: FSItem.Identifier, size: UInt64) {
        self.name = FSFileName(string: name)
        self.itemType = type
        self.itemID = id
        self.size = size
        super.init()
    }

    func attributes(matching request: FSItem.GetAttributesRequest) -> FSItem.Attributes {
        let a = FSItem.Attributes()
        let want = request.wantedAttributes
        if want.contains(.type) { a.type = itemType }
        if want.contains(.mode) { a.mode = itemType == .directory ? 0o755 : 0o644 }
        if want.contains(.linkCount) { a.linkCount = 1 }
        if want.contains(.uid) { a.uid = 0 }
        if want.contains(.gid) { a.gid = 0 }
        if want.contains(.flags) { a.flags = 0 }
        if want.contains(.size) { a.size = size }
        if want.contains(.allocSize) { a.allocSize = size }
        if want.contains(.fileID) { a.fileID = itemID }
        if want.contains(.parentID) {
            a.parentID = itemType == .directory ? .parentOfRoot : .rootDirectory
        }
        let now = timespec(tv_sec: time(nil), tv_nsec: 0)
        if want.contains(.accessTime) { a.accessTime = now }
        if want.contains(.modifyTime) { a.modifyTime = now }
        if want.contains(.changeTime) { a.changeTime = now }
        if want.contains(.birthTime) { a.birthTime = now }
        return a
    }
}

/// Stable ID for the one file; root is FSItem.Identifier.rootDirectory (2).
private let kImageItemID = FSItem.Identifier(rawValue: 3)!

/// Stable identity for the container and the volume.
///
/// FSContainer.h: "For unary file systems, the volume identifier is the same as
/// the container identifier." A fresh UUID per call would also make the volume
/// look like a different one on every probe.
private let kVolumeUUID = UUID(uuidString: "6F1C2B14-9A4E-4E31-B1E2-4C7A9D0E5B33")!

// MARK: - File system

final class ISCSIUnaryFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    /// Resolves the backing path from whichever resource kind FSKit hands us,
    /// and logs which one it was — that answers, empirically, which Info.plist
    /// resource key `/sbin/mount` actually honours.
    ///
    /// The resource URL is caller-influenced, so the generic-URL branch never
    /// interpolates it into a path directly: `safeTag` reduces it to a single
    /// bounded `[A-Za-z0-9._-]` component, which cannot contain `/` or `..` and
    /// so cannot escape the fixed directory.
    private func backingPath(for resource: FSResource) -> String? {
        if let pathURL = resource as? FSPathURLResource {
            fsLog.log("resource: FSPathURLResource \(redact(pathURL.url), privacy: .public)")
            return pathURL.url.path
        }
        if let generic = resource as? FSGenericURLResource {
            let url = generic.url
            fsLog.log("resource: FSGenericURLResource \(redact(url), privacy: .public)")
            // TODO(iscsi): this URL is the target/LUN identifier; hand it to
            // iscsid instead of mapping it onto a local file.
            return "\(kProtoBackingDir)/iscsi-proto-\(safeTag(from: url)).img"
        }
        fsLog.error("resource: unsupported kind \(String(describing: type(of: resource)), privacy: .public)")
        return nil
    }

    /// Chooses the backing store from the resource URL.
    ///
    ///   iscsi://proto/lun0                     → local file (prototype)
    ///   iscsi://[user@]host[:port]/<iqn>/<lun> → real session via iscsid
    ///
    /// Keeping the `proto` host means the known-good local configuration stays
    /// available for separating FSKit problems from network ones.
    private func makeStore(for resource: FSResource, localPath: String) throws -> LUNStore {
        guard let generic = resource as? FSGenericURLResource,
              let host = generic.url.host, host != "proto" else {
            return try BackingStore(path: localPath)
        }
        let url = generic.url
        // Path is /<target-iqn>/<lun>; the IQN itself contains no slashes.
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 1 else {
            fsLog.error("iscsi URL needs /<target-iqn>[/<lun>]")
            throw POSIXError(.EINVAL)
        }
        let target = parts[0]
        let lun = parts.count >= 2 ? (UInt64(parts[1]) ?? 0) : 0
        fsLog.log("connecting to iscsid: host=\(host, privacy: .public) target=\(target, privacy: .public) lun=\(lun)")
        // `url.user` is deliberately ignored. It used to be forwarded as the
        // daemon's keychain lookup key, which made a mount URL a way to name
        // which stored secret root should spend. The daemon now decides that
        // from its own saved record, and refuses portals it has no record for.
        return try DaemonStore(host: host, port: url.port ?? 3260,
                               target: target, lun: lun)
    }

    func probeResource(resource: FSResource,
                       replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard backingPath(for: resource) != nil else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }
        let containerID = FSContainerIdentifier(uuid: kVolumeUUID)
        reply(FSProbeResult.usable(name: "iSCSIProto", containerID: containerID), nil)
    }

    func loadResource(resource: FSResource,
                      options: FSTaskOptions,
                      replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let path = backingPath(for: resource) else {
            reply(nil, fs_errorForPOSIXError(ENOTSUP))
            return
        }
        do {
            let store = try makeStore(for: resource, localPath: path)
            let volume = ProtoVolume(store: store)
            // The container state machine is notReady -> ready -> active, and
            // `loadResource` is the transition to *ready*: "ready, but
            // inactive". `.active` means a volume is already active, and FSKit
            // rejects the load with "unexpected container state" (surfaced by
            // mount as "Protocol not supported").
            //
            // Use the no-error form. `.ready(status: fs_errorForPOSIXError(0))`
            // would attach a real NSError with POSIX code 0, which FSKit reports
            // as "Undefined error: 0".
            containerStatus = .ready
            fsLog.log("loadResource ok, volume ready")
            reply(volume, nil)
        } catch {
            // Include the path: the first real failure here was a sandbox EPERM,
            // which is indistinguishable from any other I/O error without it.
            fsLog.error("loadResource failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reply(nil, fs_errorForPOSIXError(EIO))
        }
    }

    func unloadResource(resource: FSResource,
                        options: FSTaskOptions,
                        replyHandler reply: @escaping ((any Error)?) -> Void) {
        fsLog.log("unloadResource")
        reply(nil)
    }
}

// MARK: - Volume

// FSVolume.OpenCloseOperations is optional — "if a file system volume doesn't
// conform to this protocol, the kernel layer can skip making such calls". It is
// implemented here mainly to observe *when* the disk image is opened for write
// and finally closed, which is a candidate point for the flush that never
// reaches `synchronize`.
final class ProtoVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations,
                         FSVolume.OpenCloseOperations {
    private let store: LUNStore
    private let root: ProtoItem
    private let image: ProtoItem

    init(store: LUNStore) {
        self.store = store
        self.root = ProtoItem(name: "/", type: .directory, id: .rootDirectory, size: 0)
        self.image = ProtoItem(name: kImageName, type: .file, id: kImageItemID, size: store.byteCount)
        super.init(volumeID: FSVolume.Identifier(uuid: kVolumeUUID),
                   volumeName: FSFileName(string: "iSCSIProto"))
    }

    // MARK: FSVolumePathConfOperations

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { store.byteCount }

    // MARK: FSVolume.Operations

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supports64BitObjectIDs = true
        caps.supportsSparseFiles = true
        caps.supportsHiddenFiles = true
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "iSCSIProto")
        let bs = Int(store.blockSize)
        let blocks = store.byteCount / store.blockSize
        s.blockSize = bs
        s.ioSize = 1 << 20
        s.totalBlocks = blocks
        s.availableBlocks = 0
        s.freeBlocks = 0
        s.usedBlocks = blocks
        s.totalBytes = store.byteCount
        s.availableBytes = 0
        s.freeBytes = 0
        s.usedBytes = store.byteCount
        s.totalFiles = 1
        s.freeFiles = 0
        return s
    }

    func activate(options: FSTaskOptions,
                  replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        fsLog.log("activate")
        reply(root, nil)
    }

    func deactivate(options: FSDeactivateOptions,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        fsLog.log("deactivate — \(self.store.summary, privacy: .public)")
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        fsLog.log("mount")
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        fsLog.log("unmount — \(self.store.summary, privacy: .public)")
        try? store.flush()
        reply()
    }

    /// Question (2): does a flush from the attached disk image reach us?
    /// Logged unconditionally so the answer is visible even if nothing else is.
    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        fsLog.log("SYNCHRONIZE flags=\(flags.rawValue)")
        trace("SYNCHRONIZE flags=\(flags.rawValue)")
        do {
            try store.flush()
            reply(nil)
        } catch {
            reply(fs_errorForPOSIXError(EIO))
        }
    }

    func lookupItem(named name: FSFileName,
                    inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard name.string == kImageName else {
            reply(nil, nil, fs_errorForPOSIXError(ENOENT))
            return
        }
        reply(image, image.name, nil)
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                       of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let proto = item as? ProtoItem else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        reply(proto.attributes(matching: desiredAttributes), nil)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                       on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        // The image is fixed-size; accept and report current state rather than
        // failing, since disk-image attach may set timestamps.
        guard let proto = item as? ProtoItem else {
            reply(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        let request = FSItem.GetAttributesRequest()
        request.wantedAttributes = [.type, .mode, .size, .fileID, .parentID, .linkCount]
        reply(proto.attributes(matching: request), nil)
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        // Per the header: pack "." and ".." only when `attributes` is nil.
        var next: UInt64 = cookie.rawValue
        let verifierOut = FSDirectoryVerifier(rawValue: 1)

        if next == 0 {
            if attributes == nil {
                _ = packer.packEntry(name: FSFileName(string: "."), itemType: .directory,
                                     itemID: .rootDirectory, nextCookie: FSDirectoryCookie(rawValue: 1),
                                     attributes: nil)
                _ = packer.packEntry(name: FSFileName(string: ".."), itemType: .directory,
                                     itemID: .parentOfRoot, nextCookie: FSDirectoryCookie(rawValue: 2),
                                     attributes: nil)
            }
            _ = packer.packEntry(name: image.name, itemType: .file, itemID: kImageItemID,
                                 nextCookie: FSDirectoryCookie(rawValue: 3),
                                 attributes: attributes.map { image.attributes(matching: $0) })
            next = 3
        }
        reply(verifierOut, nil)
    }

    // MARK: FSVolume.OpenCloseOperations

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes,
                  replyHandler reply: @escaping ((any Error)?) -> Void) {
        trace("OPEN modes=\(modes.rawValue)")
        reply(nil)
    }

    /// A final close (no modes retained) is the last chance to make the backing
    /// store durable, so flush here regardless of whether `synchronize` fires.
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes,
                   replyHandler reply: @escaping ((any Error)?) -> Void) {
        trace("CLOSE keeping=\(modes.rawValue) flushing=\(modes.isEmpty)")
        if !traceEnabled {
            fsLog.log("CLOSE keeping=\(modes.rawValue) — \(self.store.summary, privacy: .public)")
        }
        if modes.isEmpty { try? store.flush() }
        reply(nil)
    }

    // MARK: FSVolume.ReadWriteOperations

    func read(from item: FSItem,
              at offset: off_t,
              length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            let n = try buffer.withUnsafeMutableBytes { raw -> Int in
                try store.read(into: raw, at: UInt64(offset), length: min(length, raw.count))
            }
            reply(n, nil)
        } catch {
            reply(0, fs_errorForPOSIXError(EIO))
        }
    }

    func write(contents: Data,
               to item: FSItem,
               at offset: off_t,
               replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            reply(try store.write(contents, at: UInt64(offset)), nil)
        } catch {
            reply(0, fs_errorForPOSIXError(EIO))
        }
    }

    // MARK: Unsupported mutations
    //
    // The volume is a fixed, single-file namespace: the image file is created
    // by `loadResource` and never renamed, deleted, or joined by siblings.

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, fs_errorForPOSIXError(EROFS))
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, fs_errorForPOSIXError(ENOTSUP))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(ENOTSUP))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(EROFS))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(fs_errorForPOSIXError(EROFS))
    }

    func readSymbolicLink(_ item: FSItem,
                          replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(EINVAL))
    }
}
