import ArgumentParser
import Darwin
import Foundation
import iSCSIKit

struct NVMeDetach: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detach",
        abstract: "Detach a namespace disk and release its backing FSKit mount."
    )

    @OptionGroup var namespace: NVMeNamespaceOptions

    func run() throws {
        try namespace.withVolume { resource, volume in
            let mounts = try namespaceMounts()
            let mount = mounts.first { $0.on == volume.path }
            if let mount, mount.from != resource.absoluteString &&
                !mount.from.hasPrefix(resource.absoluteString + "?") {
                throw NamespaceError("Unexpected mount at \(volume.path).")
            }
            let image = volume.appendingPathComponent("lun0.img").path
            let device = try namespaceDevice(image: image)
            guard NamespaceLifecycle.isAttached(mounted: mount != nil, device: device) else {
                throw NamespaceError("Namespace is not attached: \(resource.absoluteString)")
            }
            try detachNamespaceDevice(image: image)
            try unmountNamespace(volume.path)
            guard rmdir(volume.path) == 0 || errno == ENOENT else {
                throw NamespaceError("Cannot remove \(volume.path): \(String(cString: strerror(errno))).")
            }
            print("Namespace detached: \(resource.absoluteString)")
        }
    }
}
