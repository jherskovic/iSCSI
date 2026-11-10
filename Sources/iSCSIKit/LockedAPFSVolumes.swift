import Foundation

/// The locked APFS volumes on an attached disk, read from
/// `diskutil apfs list -plist`.
///
/// An encrypted volume that is locked does not mount, so an attach of a LUN
/// holding one ends exactly like an attach of a blank LUN: a device and no
/// volume. Before this, the app could only call that "not formatted" — and
/// told people to erase a disk that held their data behind a password. APFS
/// says which volumes are locked, and the container listing ties each one to
/// the partition it is stored on, so one call answers it for the whole disk.
public enum LockedAPFSVolumes {
    public struct Volume: Equatable, Sendable {
        /// What the user named it: readable while locked, since APFS keeps
        /// the volume name outside the encrypted metadata.
        public let name: String
        /// `disk16s1`: the synthesized volume device.
        public let identifier: String
        /// `APFSVolumeUUID`, also readable while locked: what macOS files the
        /// volume's saved password under. Nil if the listing leaves it out.
        public let uuid: String?

        public init(name: String, identifier: String, uuid: String? = nil) {
            self.name = name
            self.identifier = identifier
            self.uuid = uuid
        }
    }

    /// The locked volumes in every APFS container stored on `disk` — the
    /// attached whole disk, as `/dev/disk15` or `disk15` — or on one of its
    /// partitions. Empty for anything unreadable: a guess here would only
    /// replace one wrong message with another.
    public static func find(onDisk disk: String, apfsList plist: Data) -> [Volume] {
        var locked: [Volume] = []
        for container in containers(onDisk: disk, apfsList: plist) {
            for volume in container["Volumes"] as? [[String: Any]] ?? [] {
                guard volume["Locked"] as? Bool == true,
                      let identifier = volume["DeviceIdentifier"] as? String else { continue }
                let name = (volume["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? identifier
                locked.append(Volume(name: name, identifier: identifier,
                                     uuid: volume["APFSVolumeUUID"] as? String))
            }
        }
        return locked
    }

    /// Whether APFS lists a container stored on `disk`: after an attach, the
    /// sign that APFS has brought it up, so that an empty `find` means no
    /// locked volumes rather than none seen yet.
    public static func hasContainer(onDisk disk: String, apfsList plist: Data) -> Bool {
        !containers(onDisk: disk, apfsList: plist).isEmpty
    }

    private static func containers(onDisk disk: String, apfsList plist: Data) -> [[String: Any]] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil)
                as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return [] }
        let whole = disk.hasPrefix("/dev/") ? String(disk.dropFirst(5)) : disk
        return containers.filter { container in
            let stores = (container["PhysicalStores"] as? [[String: Any]] ?? [])
                .compactMap { $0["DeviceIdentifier"] as? String }
            return stores.contains(where: { isOn($0, wholeDisk: whole) })
        }
    }

    /// `disk15` itself or one of its partitions (`disk15s2`), and not a
    /// different disk that merely shares the prefix (`disk150s2`).
    static func isOn(_ identifier: String, wholeDisk whole: String) -> Bool {
        if identifier == whole { return true }
        guard identifier.hasPrefix(whole + "s") else { return false }
        let slice = identifier.dropFirst(whole.count + 1)
        return !slice.isEmpty && slice.allSatisfy(\.isASCII) && slice.allSatisfy(\.isNumber)
    }
}
