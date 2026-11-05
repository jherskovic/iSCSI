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
