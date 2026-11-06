import Testing
@testable import iSCSIKit

struct NamespaceLifecycleTests {
    @Test func canonicalRecordPreservesSpellingAndIdentity() {
        let record = TargetRecord(id: "a", displayName: "NAS", host: "NAS", port: 4420,
                                  targetIQN: "nqn.test:disk", lun: 1)
        #expect(NamespaceLifecycle.record(in: [record], host: "nas", port: 4420,
                                         subsystem: record.targetIQN, nsid: 1) == record)
        #expect(NamespaceLifecycle.record(in: [record], host: "nas", port: 4420,
                                         subsystem: "nqn.test:other", nsid: 1) == nil)
        #expect(NamespaceLifecycle.record(in: [record], host: "nas", port: 4421,
                                         subsystem: record.targetIQN, nsid: 1) == nil)
        #expect(NamespaceLifecycle.record(in: [record], host: "nas", port: 4420,
                                         subsystem: record.targetIQN, nsid: 2) == nil)
    }

    @Test func onlyEmptyRealDirectoriesCanBeReused() {
        #expect(NamespaceLifecycle.canReuseDirectory(isDirectory: true, isSymbolicLink: false, isEmpty: true))
        #expect(!NamespaceLifecycle.canReuseDirectory(isDirectory: true, isSymbolicLink: true, isEmpty: true))
        #expect(!NamespaceLifecycle.canReuseDirectory(isDirectory: true, isSymbolicLink: false, isEmpty: false))
        #expect(!NamespaceLifecycle.canReuseDirectory(isDirectory: false, isSymbolicLink: false, isEmpty: true))
    }

    @Test func imageWithoutWholeDiskIsDetached() {
        let path = "/cache/lun0.img"
        #expect(NamespaceLifecycle.device(in: [], imagePath: path) == nil)
        #expect(NamespaceLifecycle.device(in: [["image-path": path]], imagePath: path) == nil)
        let partitionOnly: [[String: Any]] = [
            ["image-path": path, "system-entities": [["dev-entry": "/dev/disk9s1"]]]
        ]
        #expect(NamespaceLifecycle.device(in: partitionOnly, imagePath: path) == nil)
        let attached: [[String: Any]] = [
            ["image-path": path, "system-entities": [
                ["dev-entry": "/dev/disk9s1"], ["dev-entry": "/dev/disk9"]
            ]]
        ]
        #expect(NamespaceLifecycle.device(in: attached, imagePath: path) == "/dev/disk9")
        #expect(NamespaceLifecycle.device(in: attached, imagePath: "/other/lun0.img") == nil)
        // A stale entry for the path does not hide a live one behind it.
        let staleThenLive: [[String: Any]] = [["image-path": path]] + attached
        #expect(NamespaceLifecycle.device(in: staleThenLive, imagePath: path) == "/dev/disk9")
    }

    @Test func attachmentRequiresAtLeastOneLayer() {
        #expect(!NamespaceLifecycle.isAttached(mounted: false, device: nil))
        #expect(NamespaceLifecycle.isAttached(mounted: true, device: nil))
        #expect(NamespaceLifecycle.isAttached(mounted: false, device: "/dev/disk9"))
    }
    @Test func onlyManagedOrphanedImagesBlockRemoval() {
        let root = "/Users/test/Library/Caches/me.herko.iSCSIInitiator"
        let current = root + "/0123456789abcdef/lun0.img"
        let orphan = root + "/fedcba9876543210/lun0.img"
        func images(_ path: String) -> [[String: Any]] {
            [["image-path": path, "system-entities": [["dev-entry": "/dev/disk9"]]]]
        }
        #expect(NamespaceLifecycle.removalBlockingImage(in: images("/tmp/lun0.img"),
                    imagePath: current, mounts: []) == nil)
        #expect(NamespaceLifecycle.removalBlockingImage(in: images(root + "/ordinary/lun0.img"),
                    imagePath: current, mounts: []) == nil)
        let blocked = NamespaceLifecycle.removalBlockingImage(in: images(orphan), imagePath: current, mounts: [])
        #expect(blocked?.device == "/dev/disk9")
        #expect(blocked?.imagePath == orphan)
        #expect(NamespaceLifecycle.removalBlockingImage(in: images(orphan), imagePath: current,
                    mounts: [MountTableEntry(from: "nvme://nas/nqn.test:other/1", on: root + "/fedcba9876543210")]) == nil)
        #expect(NamespaceLifecycle.removalBlockingImage(in: [["image-path": orphan]],
                    imagePath: current, mounts: []) == nil)
        #expect(NamespaceLifecycle.removalBlockingImage(in: images(current),
                    imagePath: current, mounts: [])?.device == "/dev/disk9")
    }
}
