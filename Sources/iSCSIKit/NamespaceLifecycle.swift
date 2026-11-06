import Foundation

/// Pure decisions shared by namespace CLI operations.
public enum NamespaceLifecycle {
    public static func record(in records: [TargetRecord], host: String, port: UInt16,
                              subsystem: String, nsid: UInt64) -> TargetRecord? {
        records.first {
            $0.host.caseInsensitiveCompare(host) == .orderedSame &&
            $0.port == port && $0.targetIQN == subsystem && $0.lun == nsid
        }
    }

    public static func canReuseDirectory(isDirectory: Bool, isSymbolicLink: Bool,
                                         isEmpty: Bool) -> Bool {
        isDirectory && !isSymbolicLink && isEmpty
    }

    /// DiskImages may retain an image entry after its media has disappeared.
    /// Only a whole-disk entry proves that a device remains attached.
    public static func device(in images: [[String: Any]], imagePath: String) -> String? {
        for image in images where image["image-path"] as? String == imagePath {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            if let disk = entities.compactMap({ $0["dev-entry"] as? String }).first(where: {
                $0.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
            }) { return disk }
        }
        return nil
    }

    /// Only managed namespace images qualify as unknown orphaned devices.
    /// A regular file elsewhere named lun0.img is unrelated to our mounts.
    public static func removalBlockingImage(in images: [[String: Any]], imagePath: String,
                                            mounts: [MountTableEntry]) -> (device: String, imagePath: String)? {
        let root = URL(fileURLWithPath: imagePath).deletingLastPathComponent().deletingLastPathComponent()
        for image in images {
            guard let path = image["image-path"] as? String,
                  let disk = device(in: [image], imagePath: path) else { continue }
            if path == imagePath { return (disk, path) }
            let url = URL(fileURLWithPath: path)
            let volume = url.deletingLastPathComponent()
            if url.lastPathComponent == "lun0.img",
               volume.deletingLastPathComponent().path == root.path,
               volume.lastPathComponent.range(of: #"^[0-9a-f]{16}$"#, options: .regularExpression) != nil,
               !mounts.contains(where: { $0.on == volume.path }) {
                return (disk, path)
            }
        }
        return nil
    }

    public static func isAttached(mounted: Bool, device: String?) -> Bool {
        mounted || device != nil
    }
}
