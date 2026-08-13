//
//  iSCSIFSExtension.swift
//  Backend A: an FSKit module that presents a LUN as a regular file, so that
//  `hdiutil attach -imagekey diskimage-class=CRawDiskImage <file>` yields a real
//  /dev/diskN. The block device then comes from Apple's DiskImages framework
//  instead of our DriverKit dext, which is how this backend routes around the
//  wedge documented in docs/feedback-virtual-scsi-wedge.md.
//
//  ── CURRENT STAGE: PROTOTYPE ────────────────────────────────────────────────
//  The single file served here is backed by a LOCAL FILE, not by iSCSI. That is
//  deliberate. Two Backend A risks are untested and decide whether the design
//  works at all, and neither involves iSCSI:
//
//    1. Will DiskImages attach a file that lives on an FSKit (non-local)
//       volume at all?
//    2. Does flush/sync propagate from the disk image down to this extension?
//       (The barrier saga in docs/architecture.md is why this is verified
//       rather than assumed — see `synchronize`, which logs every call.)
//
//  Answering those with a local backing store keeps the failure surface small.
//  Wiring reads/writes to iscsid over XPC is the next step, and is marked
//  TODO(iscsi) below.
//
//  API notes (see docs/backend-a-fskit-notes.md for the full reconnaissance):
//   - FSVolume.Operations is deprecated in macOS 27 in favour of FSVolumeHandler,
//     but FSVolumeHandler is V3-only and the test VM runs 26.6.1, so this
//     targets FSVolume.Operations on purpose.
//   - FSGenericURLResource/FSPathURLResource are macOS 26.0. The Info.plist
//     advertises both PathURL and generic-URL support so that the first mount
//     attempt tells us empirically which one /sbin/mount hands over.
//

import FSKit
import Foundation
import os

let fsLog = Logger(subsystem: "me.herko.iSCSIInitiator.fsext", category: "fs")

/// Name of the single file the volume exposes; this is what hdiutil attaches.
private let kImageName = "lun0.img"

/// Prototype image size (512 MiB), matching the dext's scratch disk so the
/// existing probes in scripts/vm-scratch-apfs.sh compare like with like.
private let kDefaultImageBytes: UInt64 = 512 * 1024 * 1024

/// Block size reported through statfs. 512 keeps parity with the scratch dext.
private let kBlockSize = 512

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

// MARK: - Backing store

/// The bytes behind `lun0.img`.
///
/// TODO(iscsi): replace this with an XPC client to iscsid — `read(lba:count:)`,
/// `write(lba:data:)`, `flush()`, `capacity()` — translating byte offset to
/// LBA × blockSize. The protocol boundary is deliberately this narrow so the
/// swap touches nothing else in this file.
final class BackingStore {
    private let fd: Int32
    private let lock = NSLock()
    let byteCount: UInt64

    /// Opens (creating if needed) a sparse file of `kDefaultImageBytes`.
    ///
    /// `O_NOFOLLOW` is deliberate: the backing path lives in a world-writable
    /// directory, so without it anyone could plant a symlink there and redirect
    /// this extension's writes to a file of their choosing.
    init(path: String) throws {
        // The container's Documents directory may not exist on first use.
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let opened = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { throw POSIXError.Code(rawValue: errno).map { POSIXError($0) } ?? POSIXError(.EIO) }
        fd = opened

        var st = stat()
        if fstat(fd, &st) == 0, st.st_size > 0 {
            byteCount = UInt64(st.st_size)
        } else {
            // Sparse: ftruncate does not allocate blocks until written.
            guard ftruncate(fd, off_t(kDefaultImageBytes)) == 0 else {
                close(opened)
                throw POSIXError(.EIO)
            }
            byteCount = kDefaultImageBytes
        }
        fsLog.log("BackingStore opened \(path, privacy: .public) size=\(self.byteCount)")
    }

    deinit { close(fd) }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, length: Int) throws -> Int {
        guard offset < byteCount else { return 0 }
        let clamped = min(Int(byteCount - offset), length)
        lock.lock(); defer { lock.unlock() }
        let n = pread(fd, buffer.baseAddress, clamped, off_t(offset))
        guard n >= 0 else { throw POSIXError(.EIO) }
        return n
    }

    func write(_ data: Data, at offset: UInt64) throws -> Int {
        guard offset < byteCount else { throw POSIXError(.ENOSPC) }
        let clamped = min(Int(byteCount - offset), data.count)
        lock.lock(); defer { lock.unlock() }
        let n = data.withUnsafeBytes { raw in
            pwrite(fd, raw.baseAddress, clamped, off_t(offset))
        }
        guard n >= 0 else { throw POSIXError(.EIO) }
        return n
    }

    /// Whether a flush ever reaches us is precisely question (2) above.
    func flush() throws {
        lock.lock(); defer { lock.unlock() }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
    }
}

// MARK: - Items

/// A file or directory in the prototype volume. The volume is flat: a root
/// directory containing exactly one file.
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
            let store = try BackingStore(path: path)
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

final class ProtoVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    private let store: BackingStore
    private let root: ProtoItem
    private let image: ProtoItem

    init(store: BackingStore) {
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
        let blocks = store.byteCount / UInt64(kBlockSize)
        s.blockSize = kBlockSize
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
        fsLog.log("deactivate")
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        fsLog.log("mount")
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        fsLog.log("unmount")
        try? store.flush()
        reply()
    }

    /// Question (2): does a flush from the attached disk image reach us?
    /// Logged unconditionally so the answer is visible even if nothing else is.
    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        fsLog.log("SYNCHRONIZE flags=\(flags.rawValue)")
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
