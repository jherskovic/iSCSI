import Foundation
import iSCSIKit

/// NVMe-oF discovery: an admin-only controller on the well-known discovery
/// NQN, brought up like any other (CC.EN, CSTS.RDY), then the Discovery
/// Log Page. The `Discovery.sendTargets` twin.
public enum NVMeDiscovery {
    /// Bytes per Get Log Page command: 16 entries at a time.
    static let readChunk = 16 * DiscoveryLogEntry.size
    /// A subsystem count past which something is lying.
    static let maxEntries: UInt64 = 4096

    /// Returns every NVM subsystem reachable over TCP that the discovery
    /// controller at `transport` advertises, as `name` = SUBNQN and one
    /// "traddr:trsvcid" address each.
    public static func getLogPage(
        transport: any ConnectionTransport,
        host: NVMeHostIdentity,
        requestDigests: Bool = false
    ) async throws -> [DiscoveredTarget] {
        let queue = NVMeQueue(transport: transport, queueID: 0, entries: 32,
                              requestDigests: requestDigests, maxPDUBytes: NVMeController.adminPDULimit)
        do {
            _ = try await NVMeController.bringUpAdminQueue(
                queue, host: host, subsystemNQN: NQN.discovery, keepAliveMS: 0)
            let page = try await readWholePage(on: queue)
            await queue.close()
            return page.entries
                .filter { $0.trtype == DiscoveryLogEntry.transportTCP && $0.subtype == DiscoveryLogEntry.subtypeNVM }
                .map { DiscoveredTarget(name: $0.subnqn, addresses: ["\($0.traddr):\($0.trsvcid)"]) }
        } catch {
            await queue.close()
            throw error
        }
    }

    /// Header first for NUMREC, then the entries; re-read once if GENCTR
    /// moved underneath us.
    static func readWholePage(on queue: NVMeQueue) async throws -> DiscoveryLogPage {
        var attempts = 0
        while true {
            attempts += 1
            let header = try await read(on: queue, offset: 0, length: DiscoveryLogPage.headerSize)
            let first = try DiscoveryLogPage.parse(header)
            let count = Int(min(first.numrec, maxEntries))
            var page = header
            var offset = DiscoveryLogPage.headerSize
            let total = DiscoveryLogPage.headerSize + count * DiscoveryLogEntry.size
            while offset < total {
                let n = min(readChunk, total - offset)
                page.append(try await read(on: queue, offset: offset, length: n))
                offset += n
            }
            let full = try DiscoveryLogPage.parse(page)
            if full.genctr == first.genctr || attempts >= 2 { return full }
        }
    }

    private static func read(on queue: NVMeQueue, offset: Int, length: Int) async throws -> Data {
        let completion = try await queue.submitChecked(
            NVMeCommands.getLogPage(commandID: 0, logID: NVMeLogPage.discovery,
                                    offset: UInt64(offset), length: UInt32(length)),
            expectedRead: length)
        return completion.data
    }
}
