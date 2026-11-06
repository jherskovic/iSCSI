import ArgumentParser
import Foundation
import iSCSIKit

struct NVMeAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a namespace target online through iscsid.",
        discussion: "Requires a Developer ID signed iscsictl and a daemon that allows it."
    )

    @OptionGroup var namespace: NVMeNamespaceOptions
    @Option(help: "Display name for a newly saved target.") var name: String?

    func run() throws {
        try namespace.validate()
        let records = try namespaceTargets()
        if let existing = NamespaceLifecycle.record(in: records, host: namespace.host,
                                                     port: namespace.port,
                                                     subsystem: namespace.subsystem,
                                                     nsid: UInt64(namespace.nsid)) {
            print("Target already saved: \(existing.id)")
            if name != nil {
                FileHandle.standardError.write(Data("--name applies only to new targets. The existing name was preserved.\n".utf8))
            }
            return
        }
        let record = TargetRecord(id: UUID().uuidString, displayName: name ?? namespace.subsystem,
                                  host: namespace.host, port: namespace.port,
                                  targetIQN: namespace.subsystem, lun: UInt64(namespace.nsid))
        let encoded = try JSONEncoder().encode(record)
        let data = try namespaceRequest { proxy, finish in
            proxy.saveTarget(encoded, reply: finish)
        }
        let saved = try JSONDecoder().decode(TargetRecord.self, from: data)
        print("Target added: \(saved.id)")
    }
}

struct NVMeRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a saved namespace target through iscsid.",
        discussion: "Requires a Developer ID signed iscsictl and a daemon that allows it. This only removes configuration; detach an attached namespace with nvme detach first."
    )

    @OptionGroup var namespace: NVMeNamespaceOptions

    func run() throws {
        try namespace.validate()
        let records = try namespaceTargets()
        guard let record = NamespaceLifecycle.record(in: records, host: namespace.host,
                                                       port: namespace.port,
                                                       subsystem: namespace.subsystem,
                                                       nsid: UInt64(namespace.nsid)) else {
            print("Target is not saved.")
            return
        }
        // Share attach/detach's namespace lock so an attachment cannot start
        // between checking the disk state and deleting its configuration.
        try namespace.withVolume(record: record) { _, volume in
            try Self.remove(record: record, volume: volume)
        }
        print("Target removed: \(record.id)")
    }

    /// Called while holding the namespace lock. Inject I/O so refusal and
    /// error paths can be tested without a mounted disk or a live daemon.
    static func remove(
        record: TargetRecord, volume: URL,
        mounts: () throws -> [MountTableEntry] = namespaceMounts,
        device: (String) throws -> String? = { try namespaceRemovalDevice(image: $0) },
        delete: (TargetRecord) throws -> Void = { try deleteSavedRecord($0) }
    ) throws {
        let entries = try mounts()
        let mounted = entries.contains { $0.on == volume.path } ||
            AutoAttachRun.otherMount(ofTarget: record.targetIQN, lun: record.lun,
                                     mounts: entries, except: volume.path) != nil
        guard !mounted else {
            throw NamespaceError("Device is in use; cannot remove namespace. Run nvme detach first.")
        }
        let disk = try device(volume.appendingPathComponent("lun0.img").path)
        guard !NamespaceLifecycle.isAttached(mounted: mounted, device: disk) else {
            throw NamespaceError("Device is in use; cannot remove namespace. Run nvme detach first.")
        }
        try delete(record)
    }

    static func deleteSavedRecord(_ record: TargetRecord, request: (Data) throws -> Void = { encoded in
        _ = try namespaceRequest { proxy, finish in
            proxy.deleteTargetIfUnchanged(encoded) { error in finish(nil, error) }
        }
    }) throws {
        let encoded = try JSONEncoder().encode(record)
        do {
            try request(encoded)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain || error is NamespaceError {
                throw NamespaceError("Removal result could not be confirmed: \(error.localizedDescription) Refresh saved targets or retry nvme remove. A compatible updated daemon is required.")
            }
            throw error
        }
    }

}
