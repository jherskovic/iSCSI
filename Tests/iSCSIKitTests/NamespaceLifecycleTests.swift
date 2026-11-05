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
    }

    @Test func attachmentRequiresAtLeastOneLayer() {
        #expect(!NamespaceLifecycle.isAttached(mounted: false, device: nil))
        #expect(NamespaceLifecycle.isAttached(mounted: true, device: nil))
        #expect(NamespaceLifecycle.isAttached(mounted: false, device: "/dev/disk9"))
    }
}
