import ArgumentParser
import Foundation
import MockTarget
import iSCSIKit

/// A local iSCSI (or, with --nvme, NVMe/TCP) target, for two things the real
/// NAS cannot do: measure over loopback (no transport ceiling, and the
/// target-side negotiation knobs are ours to set) and break things on
/// purpose — dropped connections, corrupted payloads, stalls, and target
/// power loss with a volatile write cache, which the surviving harness can
/// then inspect. Both protocols share the disk, the cache model and the
/// control socket, so `crash` proves FUA the same way for either.
///
/// Not a production target: one LUN/namespace, one connection per
/// session/queue, no session reinstatement, no persistent reservations, no
/// ERL>0, no in-band NVMe authentication.
@main
struct TargetSim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iscsi-target-sim",
        abstract: "Local iSCSI or NVMe/TCP target for performance and fault-injection testing."
    )

    @Flag(help: "Serve NVMe/TCP instead of iSCSI.")
    var nvme = false

    @Option(help: "Port to serve. Defaults to 3260 (iSCSI) or 4420 (--nvme).")
    var port: UInt16?

    @Option(help: "Subsystem NQN (with --nvme).")
    var subsystemName: String = "nqn.2026-08.me.herko.sim:disk0"

    @Option(help: "Host NQN allowed to connect (with --nvme; repeatable). None means any host.")
    var allowedHost: [String] = []

    @Option(help: "Control socket port (loopback only). 0 disables it.")
    var controlPort: UInt16 = 3262

    @Option(help: "LUN block size in bytes. 4096 matches the real LUN; 512 exercises the read-modify-write path.")
    var blockSize: Int = 4096

    @Option(help: "LUN capacity in MiB.")
    var capacityMib: UInt64 = 1024

    @Option(help: "Backing file for the LUN. Omitted means RAM, which caps capacity at what fits in memory.")
    var backingFile: String?

    @Option(help: "Target IQN.")
    var targetName: String = "iqn.2026-08.me.herko.sim:lun0"

    @Option(help: "Target's MaxRecvDataSegmentLength.")
    var mrdsl: UInt32 = 262_144

    @Option(help: "Target's FirstBurstLength. The real NAS caps this at 65536.")
    var firstBurst: UInt32 = 65536

    @Option(help: "Target's MaxBurstLength.")
    var maxBurst: UInt32 = 1_048_576

    @Option(help: "Digest to select when the initiator offers one: None or CRC32C.")
    var digest: String = "None"

    @Option(help: "Cap on the volatile write cache in MiB before it commits under pressure.")
    var cacheMib: Int = 256

    @Flag(help: "Require CHAP; credentials come from --chap-user/--chap-secret.")
    var requireChap = false

    @Option(help: "CHAP username the initiator must present.")
    var chapUser: String?

    @Option(help: "CHAP secret the initiator must present.")
    var chapSecret: String?

    mutating func run() async throws {
        let capacityBlocks = capacityMib * 1024 * 1024 / UInt64(blockSize)
        guard capacityBlocks > 0 else {
            throw ValidationError("capacity of \(capacityMib) MiB is smaller than one \(blockSize)-byte block")
        }

        let disk: RAMDisk
        if let path = backingFile {
            disk = try RAMDisk(
                blockSize: blockSize,
                capacityBlocks: capacityBlocks,
                filePath: path,
                maxDirtyBytes: cacheMib << 20
            )
        } else {
            disk = RAMDisk(
                blockSize: blockSize,
                capacityBlocks: capacityBlocks,
                maxDirtyBytes: cacheMib << 20
            )
        }

        let faultBox = FaultBox()
        let port = self.port ?? (nvme ? 4420 : 3260)
        let server: MockTargetServer
        if nvme {
            var config = MockNVMeConfig()
            config.subsystemNQN = subsystemName
            config.allowedHosts = allowedHost.isEmpty ? nil : allowedHost
            config.acceptDigests = digest == "CRC32C"
            config.discoveryEntries = [(subnqn: subsystemName, traddr: "127.0.0.1", trsvcid: String(port))]
            let subsystem = MockNVMeSubsystem(config: config, disk: disk, faultBox: faultBox)
            server = try MockTargetServer(port: port) { await subsystem.serve($0) }
        } else {
            var config = MockTargetConfig()
            config.targetName = targetName
            config.maxRecvDataSegmentLength = mrdsl
            config.firstBurstLength = firstBurst
            config.maxBurstLength = maxBurst
            config.digestPick = digest
            config.requireChap = requireChap
            config.chapUser = chapUser
            config.chapSecret = chapSecret
            config.discoveryTargets = [(name: targetName, addresses: ["127.0.0.1:\(port),1"])]
            let frozen = config
            server = try MockTargetServer(port: port, disk: disk, faultBox: faultBox, config: { frozen })
        }
        let bound = try await server.start()

        let backingLabel = backingFile ?? "ram"
        if nvme {
            note("serving NVMe/TCP subsystem \(subsystemName) on port \(bound)"
                 + (allowedHost.isEmpty ? " (any host)" : " (allowed hosts: \(allowedHost.joined(separator: ", ")))"))
            note("namespace 1: \(capacityBlocks) x \(blockSize) bytes (\(capacityMib) MiB), backing=\(backingLabel)")
            note("digests: \(digest == "CRC32C" ? "accepted when offered" : "refused")")
            note("write cache: volatile, \(cacheMib) MiB, commits on FUA and Flush only")
        } else {
            note("serving \(targetName) on port \(bound)")
            note("lun: \(capacityBlocks) x \(blockSize) bytes (\(capacityMib) MiB), backing=\(backingLabel)")
            note("negotiation: MRDSL=\(mrdsl) FirstBurst=\(firstBurst) MaxBurst=\(maxBurst) digest=\(digest)")
            note("write cache: volatile, \(cacheMib) MiB, commits on FUA and SYNCHRONIZE CACHE only")
        }

        let stopSignal = StopSignal()
        if controlPort != 0 {
            let commands = ControlCommands(disk: disk, server: server, faults: faultBox, stop: stopSignal)
            let control = try ControlChannel(port: controlPort) { line in
                await commands.run(line)
            }
            let controlBound = try await control.start()
            note("control socket on 127.0.0.1:\(controlBound) — try 'printf status | nc 127.0.0.1 \(controlBound)'")
        }

        await stopSignal.wait()
        await server.stop()
        note("stopped")
    }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("iscsi-target-sim: \(message)\n".utf8))
}

/// Lets `quit` on the control socket unblock `run()`.
actor StopSignal {
    private var stopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if stopped { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        guard !stopped else { return }
        stopped = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
