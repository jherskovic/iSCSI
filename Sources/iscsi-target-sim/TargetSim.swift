import ArgumentParser
import Foundation
import MockTarget
import iSCSIKit

/// A local iSCSI target, for two things the real NAS cannot do.
///
/// **Measure without the network.** Run it on the same machine as the
/// initiator and loopback removes the ~98 MB/s transport ceiling that has
/// bounded every measurement so far, so what is left is our own cost. It also
/// exposes the target-side negotiation knobs (`FirstBurstLength` above all)
/// that were untestable because they belonged to someone else's NAS.
///
/// **Break things on purpose.** Drop connections mid-write, corrupt payloads,
/// stall commands, and — the one that matters — simulate target power loss with
/// a volatile write cache. The earlier crash test cut power to the *initiator*,
/// which cannot discriminate FUA from non-FUA; `crash` here can, because the
/// harness survives to inspect the damage.
///
/// Not a production target: one LUN, one connection per session, no session
/// reinstatement, no persistent reservations, no ERL>0.
@main
struct TargetSim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iscsi-target-sim",
        abstract: "Local iSCSI target for performance and fault-injection testing."
    )

    @Option(help: "iSCSI port to serve. 3260 needs root; use 3261+ otherwise.")
    var port: UInt16 = 3260

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

        let server = try MockTargetServer(
            port: port,
            disk: disk,
            faultBox: faultBox,
            config: { frozen }
        )
        let bound = try await server.start()

        let backingLabel = backingFile ?? "ram"
        note("serving \(targetName) on port \(bound)")
        note("lun: \(capacityBlocks) x \(blockSize) bytes (\(capacityMib) MiB), backing=\(backingLabel)")
        note("negotiation: MRDSL=\(mrdsl) FirstBurst=\(firstBurst) MaxBurst=\(maxBurst) digest=\(digest)")
        note("write cache: volatile, \(cacheMib) MiB, commits on FUA and SYNCHRONIZE CACHE only")

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
