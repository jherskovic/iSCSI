import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

/// Login and the editor's test probe take the pin from the saved record — a
/// client cannot choose it, and the probe validates what an attach will run.
/// Discovery has no record yet, so it takes the pin as parameters.
@Suite("Interface binding through XPC", .timeLimit(.minutes(1)))
struct InterfaceBindingXPCTests {

    private func makeStore(_ records: [TargetRecord] = []) async throws -> TargetStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        let store = TargetStore(url: url)
        for record in records { try await store.save(record) }
        return store
    }

    private func pinnedRecord() -> TargetRecord {
        TargetRecord(id: "t1", displayName: "NAS", host: "nas", port: 3260,
                     targetIQN: spyIQN, lun: 0,
                     networkInterface: "en18", interfaceFallback: true)
    }

    @Test("login pins to the saved target's interface")
    func loginUsesRecordBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore([pinnedRecord()]))
        let (handle, error) = await withCheckedContinuation { c in
            service.login(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(error == nil)
        #expect(handle != nil)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == InterfaceBinding(name: "en18", fallback: true) })
    }

    @Test("the connection test pins exactly as login does")
    func testConnectionUsesRecordBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore([pinnedRecord()]))
        let (data, error) = await withCheckedContinuation { c in
            service.testConnection(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(error == nil)
        #expect(data != nil)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == InterfaceBinding(name: "en18", fallback: true) })
    }

    @Test("iSCSI discovery pins to the interface it is given")
    func discoverTargetsUsesParameters() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore())
        let (data, error) = await withCheckedContinuation { c in
            service.discoverTargets(host: "nas", port: 3260, chapUser: nil, chapSecret: nil,
                                    interfaceName: "en17", interfaceFallback: false) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(error == nil)
        #expect(data != nil)
        #expect(log.all == [InterfaceBinding(name: "en17", fallback: false)])
    }

    /// The app sends "" when the picker is on Automatic.
    @Test("an empty interface name discovers unpinned")
    func emptyInterfaceNameIsAutomatic() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore())
        _ = await withCheckedContinuation { c in
            service.discoverTargets(host: "nas", port: 3260, chapUser: nil, chapSecret: nil,
                                    interfaceName: "", interfaceFallback: true) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(log.all == [nil])
    }

    @Test("NVMe discovery pins to the interface it is given")
    func discoverSubsystemsUsesParameters() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore())
        _ = await withCheckedContinuation { c in
            service.discoverSubsystems(host: "nas", port: 4420,
                                       interfaceName: "en18", interfaceFallback: true) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(log.all.first == InterfaceBinding(name: "en18", fallback: true))
    }
}
