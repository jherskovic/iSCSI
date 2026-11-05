import ArgumentParser
import Darwin
import Foundation
import iSCSIKit

struct NVMeAttach: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Expose a namespace as /dev/diskN using the installed FSKit extension.",
        discussion: "First save the host, port, subsystem NQN and namespace ID with nvme add or the iSCSI Initiator app. The daemon uses that record to log in."
    )

    @OptionGroup var namespace: NVMeNamespaceOptions

    func run() throws {
        try namespace.withVolume(attach)
    }

    private func attach(resource: URL, volume: URL) throws {
        let mounts = try namespaceMounts()
        if let other = AutoAttachRun.otherMount(ofTarget: namespace.subsystem, lun: UInt64(namespace.nsid),
                                                mounts: mounts, except: volume.path) {
            throw NamespaceError("Namespace is already mounted at \(other.on). Detach it there first.")
        }
        let existingMount = mounts.first { $0.on == volume.path }
        if let existingMount, existingMount.from != resource.absoluteString &&
            !existingMount.from.hasPrefix(resource.absoluteString + "?") {
            throw NamespaceError("Unexpected mount at \(volume.path).")
        }
        let wasMounted = existingMount != nil
        let imagePath = volume.appendingPathComponent("lun0.img").path
        let device = try namespaceDevice(image: imagePath)
        switch ImageAttachPlan.decide(fskitWasMounted: wasMounted, existingDevice: device) {
        case .reuse(let disk):
            print(disk)
            print("Backing mount: \(volume.path)")
            return
        case .replaceStale:
            try detachNamespaceDevice(image: imagePath)
        case .attach: break
        }
        if !wasMounted {
            if mkdir(volume.path, 0o700) != 0 {
                let attributes = try FileManager.default.attributesOfItem(atPath: volume.path)
                let empty = try FileManager.default.contentsOfDirectory(atPath: volume.path).isEmpty
                guard NamespaceLifecycle.canReuseDirectory(
                    isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                    isSymbolicLink: attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                    isEmpty: empty) else { throw NamespaceError("Mountpoint is not an empty directory: \(volume.path)") }
            }
        }
        do {
            if !wasMounted {
                try runNamespaceCommand("/sbin/mount", ["-F", "-t", "iSCSI", resource.absoluteString, volume.path])
            }
            let image = volume.appendingPathComponent("lun0.img")
            let file = try FileHandle(forReadingFrom: image)
            defer { try? file.close() }
            let prefix = try file.read(upToCount: PartitionTableProbe.prefixLength) ?? Data()
            var stats = statfs()
            let size = statfs(volume.path, &stats) == 0 ? Int(stats.f_bsize) : nil
            var args = ["attach", "-nomount", "-noverify", "-imagekey", "diskimage-class=CRawDiskImage"]
            if let block = PartitionTableProbe.attachBlockSize(prefix: prefix, lunBlockSize: size) {
                args += ["-blocksize", String(block)]
            }
            try runNamespaceCommand("/usr/bin/hdiutil", args + [image.path])
            print("Backing mount: \(volume.path)")
        } catch {
            // A failed attach may still have created a disk. Keep its backing
            // mount if cleanup cannot establish that the disk is gone.
            do {
                try detachNamespaceDevice(image: imagePath)
                if !wasMounted {
                    // mount can establish the volume before returning an error
                    // or being terminated. Inspect the current mount table.
                    if let mount = try namespaceMounts().first(where: { $0.on == volume.path }) {
                        guard mount.from == resource.absoluteString ||
                            mount.from.hasPrefix(resource.absoluteString + "?") else {
                            throw NamespaceError("Unexpected mount during cleanup at \(volume.path).")
                        }
                        try unmountNamespace(volume.path)
                    }
                }
                if !wasMounted { _ = rmdir(volume.path) }
            } catch {
                FileHandle.standardError.write(Data("Cleanup failed: \(error.localizedDescription)\n".utf8))
            }
            throw error
        }
    }
}
