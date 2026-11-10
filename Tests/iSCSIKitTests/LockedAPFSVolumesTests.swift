import Foundation
import Testing
@testable import iSCSIKit

/// An encrypted, locked volume attaches like a blank disk: a device and
/// nothing mounted. These pin how the app tells the two apart from
/// `diskutil apfs list -plist`, in the shape that command prints (seen on
/// macOS 27.2 with the encrypted `ssd-vms` LUN, 2026-11-09).
@Suite("Locked APFS volumes")
struct LockedAPFSVolumesTests {
    private func listing(_ containers: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Containers": containers],
                                           format: .xml, options: 0)
    }

    private func container(stores: [String], volumes: [[String: Any]]) -> [String: Any] {
        ["ContainerReference": "disk99",
         "PhysicalStores": stores.map { ["DeviceIdentifier": $0] },
         "Volumes": volumes]
    }

    private func volume(_ id: String, _ name: String, locked: Bool, fileVault: Bool = true) -> [String: Any] {
        ["DeviceIdentifier": id, "Name": name, "Locked": locked,
         "FileVault": fileVault, "Encryption": fileVault, "Roles": [String]()]
    }

    @Test("a locked volume on a partition of the attached disk is found, by name")
    func lockedVolumeOnTheDisk() throws {
        let plist = try listing([
            container(stores: ["disk15s2"], volumes: [volume("disk16s1", "ssd-vms", locked: true)]),
        ])
        #expect(LockedAPFSVolumes.find(onDisk: "/dev/disk15", apfsList: plist)
                == [.init(name: "ssd-vms", identifier: "disk16s1")])
        #expect(LockedAPFSVolumes.find(onDisk: "disk15", apfsList: plist).count == 1)
    }

    @Test("an unlocked volume, encrypted or not, is not reported")
    func unlockedVolumesAreNotLocked() throws {
        let plist = try listing([
            container(stores: ["disk15s2"], volumes: [
                volume("disk16s1", "ssd-vms", locked: false),
                volume("disk16s2", "plain", locked: false, fileVault: false),
            ]),
        ])
        #expect(LockedAPFSVolumes.find(onDisk: "/dev/disk15", apfsList: plist).isEmpty)
    }

    @Test("another disk's locked volume does not count, even one whose name shares the prefix")
    func otherDisksAreIgnored() throws {
        let plist = try listing([
            container(stores: ["disk150s2"], volumes: [volume("disk151s1", "elsewhere", locked: true)]),
            container(stores: ["disk3"], volumes: [volume("disk3s5", "Data", locked: true)]),
        ])
        #expect(LockedAPFSVolumes.find(onDisk: "/dev/disk15", apfsList: plist).isEmpty)
    }

    @Test("a container on the whole disk, with no partition table, counts too")
    func containerOnTheWholeDisk() throws {
        let plist = try listing([
            container(stores: ["disk15"], volumes: [volume("disk16s1", "", locked: true)]),
        ])
        // No name: the device stands in for it.
        #expect(LockedAPFSVolumes.find(onDisk: "/dev/disk15", apfsList: plist)
                == [.init(name: "disk16s1", identifier: "disk16s1")])
    }

    @Test("an unreadable listing reports nothing rather than guessing")
    func unreadableListing() {
        #expect(LockedAPFSVolumes.find(onDisk: "/dev/disk15", apfsList: Data("nope".utf8)).isEmpty)
        #expect(LockedAPFSVolumes.find(onDisk: "/dev/disk15", apfsList: Data()).isEmpty)
    }

    @Test("this Mac's own listing parses, whatever it holds")
    func realListingParses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(root?["Containers"] is [[String: Any]], "diskutil's plist shape changed")
        // A disk that cannot exist: nothing is found, and nothing traps.
        #expect(LockedAPFSVolumes.find(onDisk: "/dev/disk999999", apfsList: data).isEmpty)
    }
}
