import ArgumentParser
import Darwin
import Foundation

struct NVMeDetach: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detach",
        abstract: "Detach a namespace disk and release its backing FSKit mount."
    )

    @OptionGroup var namespace: NVMeNamespaceOptions

    func run() throws {
        try namespace.withVolume { resource, volume in
            var mounts: UnsafeMutablePointer<statfs>?
            let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
            guard count > 0, let mounts else { throw ValidationError("Cannot read the mount table.") }
            defer { free(mounts) }
            var mounted = false
            for index in 0..<Int(count) {
                var entry = mounts[index]
                let path = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                guard path == volume.path else { continue }
                let source = withUnsafeBytes(of: &entry.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                guard source == resource.absoluteString || source.hasPrefix(resource.absoluteString + "?") else {
                    throw ValidationError("Unexpected mount at \(path): \(source)")
                }
                mounted = true
            }

            let output = Pipe()
            let data = try runNamespaceCommand("/usr/bin/hdiutil", ["info", "-plist"], output: output)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let images = plist["images"] as? [[String: Any]] else {
                throw ValidationError("Cannot read the attached image list.")
            }
            let imagePath = volume.appendingPathComponent("lun0.img").path
            for image in images where image["image-path"] as? String == imagePath {
                let entities = image["system-entities"] as? [[String: Any]]
                guard let disk = entities?.compactMap({ $0["dev-entry"] as? String }).first(where: {
                    $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
                }) else { throw ValidationError("Cannot identify the disk for \(imagePath).") }
                try runNamespaceCommand("/usr/bin/hdiutil", ["detach", disk])
            }
            if mounted { try runNamespaceCommand("/sbin/umount", [volume.path]) }
            guard rmdir(volume.path) == 0 || errno == ENOENT else {
                throw ValidationError("Cannot remove \(volume.path): \(String(cString: strerror(errno))).")
            }
            print("Namespace detached: \(resource.absoluteString)")
        }
    }
}
