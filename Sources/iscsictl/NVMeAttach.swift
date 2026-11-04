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
        // Reserve this namespace's mountpoint before opening a session.
        guard mkdir(volume.path, 0o700) == 0 else {
            throw ValidationError("Cannot reserve \(volume.path): \(String(cString: strerror(errno))). Check for an existing attachment.")
        }
        var mounted = false
        do {
            try runNamespaceCommand("/sbin/mount", ["-F", "-t", "iSCSI", resource.absoluteString, volume.path])
            mounted = true
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
            if mounted { try runNamespaceCommand("/sbin/umount", [volume.path]) }
            _ = rmdir(volume.path)
            if !mounted {
                FileHandle.standardError.write(Data("""
                    FSKit could not mount \(resource.absoluteString). Save this namespace with nvme add or iSCSI Initiator using the same host, port, subsystem NQN and NSID.
                    For the underlying error, run:
                      /usr/bin/log show --last 5m --predicate 'subsystem == "me.herko.iSCSIInitiator.fsext" AND eventMessage CONTAINS "loadResource failed"'

                    """.utf8))
            }
            throw error
        }
    }
}
