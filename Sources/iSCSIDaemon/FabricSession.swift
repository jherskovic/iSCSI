import Foundation
import NVMeKit
import iSCSIKit

/// What `DaemonCore` needs from a session regardless of protocol: the
/// lifecycle, the diagnostics the Sessions pane shows, and the list of
/// units (LUNs, or namespaces) behind it. The block I/O itself goes
/// through `BlockDeviceBackend`. A protocol rather than an enum so the
/// daemon's event-handler, logout and recovery-count code keeps its exact
/// text: both engines emit iSCSIKit's `SessionEvent`.
protocol FabricSession: Sendable {
    func logout() async throws
    var recoveryCount: Int { get async }
    var displayPairs: [String: String] { get async }
    func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void) async
    /// REPORT LUNS for iSCSI; Identify CNS 02h (active namespaces) for NVMe.
    func listUnits() async throws -> [LUNInfo]
}

struct ISCSIFabricSession: FabricSession {
    let session: ISCSISession

    func logout() async throws { try await session.logout() }

    var recoveryCount: Int {
        get async { await session.recoveryCount }
    }

    var displayPairs: [String: String] {
        get async { await session.parameters?.displayPairs ?? [:] }
    }

    func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void) async {
        await session.setEventHandler(handler)
    }

    /// REPORT LUNS against LUN 0 — the one guaranteed to exist, and the one
    /// the target answers the list from.
    func listUnits() async throws -> [LUNInfo] {
        let result = try await session.executeChecked(
            SCSITask(lun: 0, cdb: CDB.reportLuns(), direction: .read(expectedLength: 1024)))

        // SPC LUN list: 4-byte list length (in bytes), 4 reserved, then one
        // 8-byte LUN per entry.
        let data = result.data
        guard data.count >= 8 else { return [] }
        let listLength = Int(data.beU32(0))
        var luns: [LUNInfo] = []
        var offset = 8
        while offset + 8 <= min(data.count, 8 + listLength) {
            if let lun = DaemonCore.lunNumber(fromReportLUNsEntry: Data(data.sub(offset, 8))) {
                luns.append(LUNInfo(lun: lun))
            }
            offset += 8
        }
        return luns
    }
}

struct NVMeFabricSession: FabricSession {
    let controller: NVMeController

    func logout() async throws { try await controller.logout() }

    var recoveryCount: Int {
        get async { await controller.recoveryCount }
    }

    var displayPairs: [String: String] {
        get async { await controller.displayPairs }
    }

    func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void) async {
        await controller.setEventHandler(handler)
    }

    func listUnits() async throws -> [LUNInfo] {
        try await controller.activeNamespaces().map { LUNInfo(lun: UInt64($0)) }
    }
}
