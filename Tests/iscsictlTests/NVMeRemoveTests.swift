import Foundation
import Testing
import iSCSIKit
@testable import iscsictl

struct NVMeRemoveTests {
    private let record = TargetRecord(id: "saved-id", displayName: "NAS", host: "nas",
                                      port: 4420, targetIQN: "nqn.test:disk", lun: 1)
    private let volume = URL(fileURLWithPath: "/cache/namespace")
    private enum Failure: Error { case mountTable, diskImages, daemon }

    @Test(arguments: ["/cache/namespace", "/Volumes/app-mount"])
    func mountedNamespacePreservesRecord(mountPoint: String) throws {
        let resource = try #require(MountResourceURL.make(host: record.host, port: record.port,
                                                         target: record.targetIQN, lun: record.lun))
        var deleted = false
        var queriedDevice = false
        do {
            try NVMeRemove.remove(record: record, volume: volume,
                mounts: { [MountTableEntry(from: resource.absoluteString, on: mountPoint)] },
                device: { _ in queriedDevice = true; return nil },
                delete: { _ in deleted = true })
            Issue.record("Removal should fail while the namespace is mounted")
        } catch {
            #expect(error.localizedDescription == "Device is in use; cannot remove namespace. Run nvme detach first.")
        }
        #expect(!deleted)
        #expect(!queriedDevice)
    }

    @Test func attachedDiskWithoutBackingMountPreservesRecord() {
        var deleted = false
        #expect(throws: NamespaceError.self) {
            try NVMeRemove.remove(record: record, volume: volume, mounts: { [] },
                device: { path in
                    #expect(path == "/cache/namespace/lun0.img")
                    return "/dev/disk9"
                }, delete: { _ in deleted = true })
        }
        #expect(!deleted)
    }

    @Test func detachedNamespaceDeletesOnlyMatchingRecord() throws {
        var deleted: [String] = []
        try NVMeRemove.remove(record: record, volume: volume,
            mounts: { [MountTableEntry(from: "nvme://nas:4420/nqn.test:disk/2", on: "/Volumes/other")] },
            device: { _ in nil }, delete: { deleted.append($0.id) })
        #expect(deleted == [record.id])
    }

    @Test func mountInspectionFailurePreservesRecord() {
        var deleted = false
        #expect(throws: Failure.mountTable) {
            try NVMeRemove.remove(record: record, volume: volume,
                mounts: { throw Failure.mountTable },
                device: { _ in Issue.record("Should stop after mount inspection fails"); return nil },
                delete: { _ in deleted = true })
        }
        #expect(!deleted)
    }

    @Test func diskInspectionFailurePreservesRecord() {
        var deleted = false
        #expect(throws: Failure.diskImages) {
            try NVMeRemove.remove(record: record, volume: volume, mounts: { [] },
                device: { _ in throw Failure.diskImages }, delete: { _ in deleted = true })
        }
        #expect(!deleted)
    }

    @Test func daemonFailureIsReported() {
        #expect(throws: Failure.daemon) {
            try NVMeRemove.remove(record: record, volume: volume, mounts: { [] },
                device: { _ in nil }, delete: { _ in throw Failure.daemon })
        }
    }
    @Test func checkedDeletionSendsFullRecord() throws {
        var sent: TargetRecord?
        try NVMeRemove.deleteSavedRecord(record) { data in
            sent = try JSONDecoder().decode(TargetRecord.self, from: data)
        }
        #expect(sent == record)
    }

    @Test func uncertainReplyExplainsRetryWithoutClaimingSuccess() {
        for failure: Error in [NamespaceError("iscsid did not reply."),
                               NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)] {
            do {
                try NVMeRemove.deleteSavedRecord(record) { _ in throw failure }
                Issue.record("Must report uncertain result")
            } catch {
                #expect(error.localizedDescription.contains("could not be confirmed"))
                #expect(error.localizedDescription.contains("retry nvme remove"))
            }
        }
    }

    @Test func daemonRefusalIsNotReportedAsUncertain() {
        #expect(throws: Failure.daemon) {
            try NVMeRemove.deleteSavedRecord(record) { _ in throw Failure.daemon }
        }
    }

    @Test(arguments: ["/tmp/lun0.img", "/cache/fedcba9876543210/lun0.img"])
    func unrelatedImagesDoNotPreventDeletion(otherImage: String) throws {
        var deleted = false
        try NVMeRemove.remove(record: record, volume: volume, mounts: { [] },
            device: { path in
                NamespaceLifecycle.device(in: [
                    ["image-path": otherImage, "system-entities": [["dev-entry": "/dev/disk9"]]]
                ], imagePath: path)
            }, delete: { _ in deleted = true })
        #expect(deleted)
    }
}
