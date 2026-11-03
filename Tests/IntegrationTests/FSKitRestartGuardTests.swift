import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit

/// The daemon's half of item 14: `refreshFSKitEnablement` kills fskitd as
/// root, so it refuses while anything FSKit serves is mounted. Both the mount
/// table and the kill are injected; nothing here can restart this Mac's fskitd.
@Suite("Daemon: restarting fskitd", .serialized)
struct FSKitRestartGuardTests {
    final class Kills: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func refresh(mounts: [MountTableEntry]) async -> (Error?, kills: Int) {
        let kills = Kills()
        let (previousTable, previousRestart) = (ISCSIXPCService.mountTable, ISCSIXPCService.restartFSKit)
        ISCSIXPCService.mountTable = { mounts }
        ISCSIXPCService.restartFSKit = { kills.record(); return 0 }
        defer {
            ISCSIXPCService.mountTable = previousTable
            ISCSIXPCService.restartFSKit = previousRestart
        }
        let core = DaemonCore(initiatorName: "iqn.test:initiator") { _, _, _ in
            throw TransportError.connectFailed("no target in this test")
        }
        let store = TargetStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("targets.json"))
        let service = ISCSIXPCService(core: core, targets: store)
        let error = await withCheckedContinuation { continuation in
            service.refreshFSKitEnablement { continuation.resume(returning: $0) }
        }
        return (error, kills.value)
    }

    @Test("another account's attached volume stops the restart")
    func anotherAccountsVolumeRefusesTheRestart() async {
        let theirs = MountTableEntry(
            from: "iscsi://192.168.20.1/iqn.me.herko.planet-express:iscsi-driver-testing/0",
            on: "/Users/another/Library/Caches/me.herko.iSCSIInitiator/b23babc2ec98916d",
            isFSKit: true)
        let (error, kills) = await refresh(mounts: [theirs])
        #expect(kills == 0)
        let message = (error as NSError?)?.localizedDescription ?? ""
        #expect(message.contains("another's"), "got: \(message)")
        #expect((error as NSError?)?.localizedRecoverySuggestion?.contains("restart this Mac") == true)
    }

    @Test("with nothing FSKit mounted, the restart runs")
    func nothingMountedRestarts() async {
        let (error, kills) = await refresh(mounts: [
            MountTableEntry(from: "/dev/disk3s1", on: "/System/Volumes/Data"),
        ])
        #expect(error == nil)
        #expect(kills == 1)
    }
}
