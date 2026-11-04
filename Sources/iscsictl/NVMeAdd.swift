import ArgumentParser
import Foundation
import iSCSIKit
import os

struct NVMeAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a namespace target online through iscsid.",
        discussion: "Requires a Developer ID signed iscsictl and a daemon that allows it."
    )

    @OptionGroup var namespace: NVMeNamespaceOptions
    @Option(help: "Display name for a newly saved target.") var name: String?

    func run() throws {
        try namespace.withVolume { _, _ in }
        let connection = NSXPCConnection(machServiceName: iscsiDaemonServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ISCSIDaemonProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Result<Data, Error>?>(initialState: nil)
        let finish: @Sendable (Data?, Error?) -> Void = { data, error in
            result.withLock { value in
                guard value == nil else { return }
                value = error.map { .failure($0) } ?? .success(data ?? Data())
                semaphore.signal()
            }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({
            finish(nil, $0)
        }) as? ISCSIDaemonProtocol else { throw ValidationError("Cannot connect to iscsid.") }
        proxy.listTargets { data, error in
            if let error { finish(nil, error); return }
            do {
                let records = try JSONDecoder().decode([TargetRecord].self, from: data ?? Data())
                if let existing = records.first(where: {
                    $0.host.caseInsensitiveCompare(namespace.host) == .orderedSame &&
                    $0.port == namespace.port && $0.targetIQN == namespace.subsystem &&
                    $0.lun == UInt64(namespace.nsid)
                }) {
                    finish(try JSONEncoder().encode(existing), nil)
                    return
                }
                let record = TargetRecord(id: UUID().uuidString, displayName: name ?? namespace.subsystem,
                                          host: namespace.host, port: namespace.port,
                                          targetIQN: namespace.subsystem, lun: UInt64(namespace.nsid))
                proxy.saveTarget(try JSONEncoder().encode(record), reply: finish)
            } catch { finish(nil, error) }
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw ValidationError("iscsid did not reply. Check the CLI signature and daemon version.")
        }
        let data = try result.withLock { try $0!.get() }
        let saved = try JSONDecoder().decode(TargetRecord.self, from: data)
        print("Target added: \(saved.id)")
    }
}
