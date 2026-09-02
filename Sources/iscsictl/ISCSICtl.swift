import ArgumentParser

import Foundation
import iSCSIDaemon
import iSCSIKit

/// A secret from a file or the environment — never from `argv`, which
/// `ps -axww` publishes to every local user (and shell history keeps).
/// Trailing whitespace is stripped so `echo secret > file` does the obvious
/// thing.
func readSecret(file: String?, env: String, label: String) throws -> String {
    if let file {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw ValidationError("cannot read the \(label) from \(file)")
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
        return value
    }
    let flag = label.contains("mutual") ? "--mutual-secret-file" : "--chap-secret-file"
    throw ValidationError("no \(label): pass \(flag) or set $\(env)")
}

// iscsictl — control CLI: protocol operations run directly against a target
// over TCP as one-shots, independent of the daemon.

@main
struct ISCSICtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iscsictl",
        abstract: "Control the macOS iSCSI initiator.",
        version: "0.1.0",
        subcommands: ISCSICtl.enabledSubcommands
    )
}

extension ISCSICtl {
    /// The dext subcommands exist only when Backend B is compiled in, so the
    /// list is assembled rather than literal — otherwise turning the flag off
    /// leaves a reference to a type that is no longer there.
    static var enabledSubcommands: [any ParsableCommand.Type] {
        var commands: [any ParsableCommand.Type] =
            [Discover.self, Verify.self, ReadBench.self, WriteBench.self, Wipe.self, NVMe.self]
        #if ISCSI_BACKEND_B
        commands += [DextAttach.self, DextStatsCommand.self]
        #endif
        return commands
    }
}

struct GlobalOptions: ParsableArguments {
    @Argument(help: "Target portal host (IP or DNS name).")
    var host: String

    @Option(help: "Target portal TCP port.")
    var port: UInt16 = 3260

    @Option(help: "Initiator IQN.")
    var initiator = IQN.defaultInitiatorName(
        hostIdentifier: Host.current().localizedName ?? "mac"
    )

    @Option(help: "CHAP username.")
    var chapUser: String?

    @Option(help: ArgumentHelp("File containing the CHAP secret.",
                               discussion: "Or set $ISCSI_CHAP_SECRET."))
    var chapSecretFile: String?

    @Option(help: "Mutual CHAP username (target authenticates to us).")
    var mutualUser: String?

    @Option(help: ArgumentHelp("File containing the mutual CHAP secret.",
                               discussion: "Or set $ISCSI_MUTUAL_SECRET."))
    var mutualSecretFile: String?

    @Flag(help: "Trace every PDU on the wire to stderr.")
    var debug = false

    /// Credentials, or nil when no CHAP user was given. Throws rather than
    /// substituting an empty secret — a missing secret (e.g. `sudo` stripping
    /// the environment) would otherwise produce a well-formed exchange over
    /// `MD5(id ‖ "" ‖ challenge)`. Deliberately no `--chap-secret` option:
    /// see `readSecret`.
    func credentials() throws -> CHAP.Credentials? {
        guard let user = chapUser else { return nil }
        let secret = try readSecret(file: chapSecretFile,
                                    env: "ISCSI_CHAP_SECRET",
                                    label: "CHAP secret")
        let mutual = mutualUser == nil ? nil
            : try readSecret(file: mutualSecretFile,
                             env: "ISCSI_MUTUAL_SECRET",
                             label: "mutual CHAP secret")
        return try CHAP.Credentials.validated(name: user, secret: secret,
                                              mutualName: mutualUser,
                                              mutualSecret: mutual)
    }

    /// The login exchange's narration, under the same flag as the PDU trace:
    /// the trace shows what crossed the wire (CHAP values redacted), this says
    /// what we were trying to do with it.
    var authTrace: (@Sendable (String) -> Void)? {
        guard debug else { return nil }
        let label = host
        return { message in
            FileHandle.standardError.write(Data("[\(label)] \(message)\n".utf8))
        }
    }

    func openTransport() async throws -> any ConnectionTransport {
        #if canImport(Network)
        let tcp = try await NetworkTransport.connect(host: host, port: port)
        return debug ? TracingTransport(tcp, label: host) : tcp
        #else
        throw ValidationError("Network.framework unavailable on this platform")
        #endif
    }
}

// MARK: discover

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a SendTargets discovery session and list targets."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        #if canImport(Network)
        let transport = try await options.openTransport()
        let targets = try await Discovery.sendTargets(
            transport: transport,
            initiatorName: options.initiator,
            chap: try options.credentials(),
            trace: options.authTrace
        )
        if targets.isEmpty {
            print("No targets advertised by \(options.host):\(options.port)")
        }
        for target in targets {
            print(target.name)
            for address in target.addresses {
                print("    \(address)")
            }
        }
        #else
        throw ValidationError("Network.framework unavailable on this platform")
        #endif
    }
}

// MARK: verify

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Log in and run a read/write/verify sweep against a scratch LUN. DESTRUCTIVE."
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "Target IQN to log into.")
    var target: String

    @Option(help: "LUN number.")
    var lun: UInt64 = 0

    @Flag(help: "Also write (DESTRUCTIVE — only use a scratch LUN).")
    var write = false

    @Option(help: "Starting LBA for the write/verify sweep.")
    var lba: UInt64 = 0

    @Option(help: "Number of blocks per I/O.")
    var blocks: UInt32 = 8

    func run() async throws {
        #if canImport(Network)
        let transport = try await options.openTransport()
        var config = LoginConfig(
            initiatorName: options.initiator,
            sessionType: .normal,
            targetName: target,
            chap: try options.credentials(),
            trace: options.authTrace
        )
        config.desired.offerDigests = true
        let connection = ISCSIConnection(transport: transport, login: config)
        let result = try await connection.login()
        print("Logged in. TSIH=\(result.tsih)")
        print("  HeaderDigest=\(result.parameters.headerDigest) DataDigest=\(result.parameters.dataDigest)")
        print("  InitialR2T=\(result.parameters.initialR2T) ImmediateData=\(result.parameters.immediateData)")
        print("  MaxBurst=\(result.parameters.maxBurstLength) FirstBurst=\(result.parameters.firstBurstLength)")

        let lunAddress = lun << 48

        let inquiry = try await connection.execute(SCSITask(
            lun: lunAddress, cdb: CDB.inquiry(), direction: .read(expectedLength: 96)
        ))
        if inquiry.data.count >= 32 {
            let vendor = String(data: inquiry.data.sub(8, 8), encoding: .ascii) ?? "?"
            let product = String(data: inquiry.data.sub(16, 16), encoding: .ascii) ?? "?"
            print("  INQUIRY: \(vendor.trimmingCharacters(in: .whitespaces)) / \(product.trimmingCharacters(in: .whitespaces))")
        }

        // A fresh nexus answers its first non-INQUIRY command with UNIT
        // ATTENTION; absorb it. Never guess the block size: a 512 fallback
        // against a 4Kn LUN makes every CDB describe 8× the data carried.
        var capacity = SCSITaskResult(status: 0x02)
        for _ in 0 ..< 3 {
            capacity = try await connection.execute(SCSITask(
                lun: lunAddress, cdb: CDB.readCapacity16(), direction: .read(expectedLength: 32)
            ))
            if capacity.isGood { break }
            guard capacity.sense.flatMap(SenseData.init)?.key == 0x06 else { break }
        }
        guard capacity.isGood else {
            throw ValidationError("READ CAPACITY failed: status \(capacity.status)")
        }
        let (blockSizeInt, blockCount) = try ISCSIBlockDevice
            .geometry(fromReadCapacity16: capacity.data)
        let blockSize = UInt32(blockSizeInt)
        print("  CAPACITY: \(blockCount) blocks × \(blockSize) bytes = \(blockCount * UInt64(blockSize) / 1_048_576) MiB")

        let byteCount = Int(blocks) * Int(blockSize)
        if write {
            let pattern = Data((0 ..< byteCount).map { UInt8(($0 &* 0x9E) & 0xFF) })
            let w = try await connection.executeChecked(SCSITask(
                lun: lunAddress, cdb: CDB.write16(lba: lba, blocks: blocks), direction: .write(pattern)
            ))
            _ = w
            _ = try await connection.execute(SCSITask(lun: lunAddress, cdb: CDB.synchronizeCache16()))
            let readback = try await connection.executeChecked(SCSITask(
                lun: lunAddress, cdb: CDB.read16(lba: lba, blocks: blocks), direction: .read(expectedLength: UInt32(byteCount))
            ))
            if readback.data == pattern {
                print("  VERIFY: OK (\(byteCount) bytes round-tripped at LBA \(lba))")
            } else {
                print("  VERIFY: FAILED — data mismatch")
                throw ExitCode(1)
            }
        } else {
            let readback = try await connection.executeChecked(SCSITask(
                lun: lunAddress, cdb: CDB.read16(lba: lba, blocks: blocks), direction: .read(expectedLength: UInt32(byteCount))
            ))
            print("  READ: \(readback.data.count) bytes at LBA \(lba) (read-only; pass --write to test integrity)")
        }

        _ = try await connection.logout()
        print("Logged out.")
        #else
        throw ValidationError("Network.framework unavailable on this platform")
        #endif
    }
}

// MARK: wipe

/// Raw sequential I/O straight over iSCSI — no FSKit, no DiskImages, no
/// filesystem — so a disappointing end-to-end number can be split into "our
/// stack" versus "the transport".
struct WriteBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write-bench",
        abstract: "Sequential write throughput over raw iSCSI. DESTRUCTIVE — scratch LUNs only."
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "Target IQN to log into.")
    var target: String

    @Option(help: "LUN number.")
    var lun: UInt64 = 0

    @Option(help: "Megabytes to write.")
    var megabytes: Int = 512

    @Option(help: "Bytes per SCSI command.")
    var chunk: Int = 1 << 20

    @Option(help: "Starting offset in megabytes.")
    var offsetMB: Int = 0

    @Flag(help: "Send every write with FUA (what the shipping daemon does).")
    var fua = false

    @Option(help: ArgumentHelp(
        "Cap on a single SCSI command.", discussion: """
        The write counterpart of read-bench's flag of the same name, and read \
        it the same way: a request larger than this is split into several \
        commands, which are issued together. Leaving it equal to --chunk is one \
        command per request, which is what this tool did before the option \
        existed — and it is why it could not measure whether splitting a write \
        helps at all.
        """))
    var maxTransfer: Int?

    func run() async throws {
        #if canImport(Network)
        let transport = try await options.openTransport()
        var config = LoginConfig(
            initiatorName: options.initiator,
            sessionType: .normal,
            targetName: target,
            chap: try options.credentials(),
            trace: options.authTrace
        )
        config.desired.offerDigests = true
        let session = ISCSISession(login: config) { try await transport }
        let login = try await session.activate()
        let device = ISCSIBlockDevice(
            session: session, lun: lun,
            maxTransferBytes: maxTransfer ?? chunk, writeThrough: fua
        )
        let (blockSize, blockCount) = try await device.readCapacity()
        let capacity = UInt64(blockSize) * blockCount
        let params = login.parameters
        // The negotiated burst sizes decide how many round trips a write costs,
        // so print them: comparing two runs without them is comparing nothing.
        print("capacity \(capacity / 1_048_576) MiB, blockSize \(blockSize), "
              + "chunk \(chunk), maxTransfer \(maxTransfer ?? chunk), "
              + "commands/request \(max(1, chunk / (maxTransfer ?? chunk))), fua \(fua)")
        print("negotiated: FirstBurst=\(params.firstBurstLength) MaxBurst=\(params.maxBurstLength) "
            + "ImmediateData=\(params.immediateData) InitialR2T=\(params.initialR2T) "
            + "HeaderDigest=\(params.headerDigest) DataDigest=\(params.dataDigest)")

        let payload = Data((0 ..< chunk).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        var offset = UInt64(offsetMB) * 1_048_576
        offset -= offset % UInt64(blockSize)
        var remaining = megabytes * 1_048_576
        let start = Date()
        var moved = 0
        while remaining > 0, offset < capacity {
            var n = min(chunk, remaining, Int(capacity - offset))
            n -= n % blockSize
            guard n > 0 else { break }
            try await device.write(offset: offset, data: payload.prefix(n))
            offset += UInt64(n)
            remaining -= n
            moved += n
        }
        let el = Date().timeIntervalSince(start)
        let mbps = Double(moved) / el / 1_000_000
        print(String(format: "wrote %.2f GB in %.2fs = %.1f MB/s", Double(moved) / 1e9, el, mbps))
        try await session.logout()
        #else
        print("requires macOS")
        #endif
    }
}

struct ReadBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read-bench",
        abstract: "Sequential read throughput over raw iSCSI (no filesystem, no disk image)."
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "Target IQN to log into.")
    var target: String

    @Option(help: "LUN number.")
    var lun: UInt64 = 0

    @Option(help: "Megabytes to read.")
    var megabytes: Int = 512

    @Option(help: "Bytes per SCSI command.")
    var chunk: Int = 1 << 20

    @Option(help: "Starting offset in megabytes (skip cached regions).")
    var offsetMB: Int = 0

    @Option(help: """
        Commands to keep outstanding at once. 1 issues one read, waits for it, \
        then issues the next — which leaves the link idle for a whole round \
        trip every time.
        """)
    var queueDepth: Int = 1

    @Option(help: """
        Cap on a single SCSI command, which is a different thing from --chunk: \
        a request larger than this is split into several commands issued \
        together. Defaults to what the daemon uses. Set it equal to --chunk to \
        measure one command per request, which is how the large-command cliff \
        in docs/queue-depth.md was found.
        """)
    var maxTransfer: Int = 256 << 10

    func run() async throws {
        #if canImport(Network)
        guard queueDepth >= 1 else {
            throw ValidationError("--queue-depth must be at least 1")
        }
        let transport = try await options.openTransport()
        var config = LoginConfig(
            initiatorName: options.initiator,
            sessionType: .normal,
            targetName: target,
            chap: try options.credentials(),
            trace: options.authTrace
        )
        config.desired.offerDigests = true
        let session = ISCSISession(login: config) { try await transport }
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: lun, maxTransferBytes: maxTransfer)
        let (blockSize, blockCount) = try await device.readCapacity()
        let capacity = UInt64(blockSize) * blockCount
        print("capacity \(capacity / 1_048_576) MiB, blockSize \(blockSize), "
              + "chunk \(chunk), maxTransfer \(maxTransfer), queueDepth \(queueDepth)")

        var offset = UInt64(offsetMB) * 1_048_576
        // Align to a block boundary; the device rejects unaligned requests.
        offset -= offset % UInt64(blockSize)

        // Plan the whole run first, so the timed section contains nothing but
        // I/O and the two queue depths are compared over identical work.
        var plan: [(offset: UInt64, length: Int)] = []
        var remaining = megabytes * 1_048_576
        while remaining > 0, offset < capacity {
            let n = min(chunk, remaining, Int(capacity - offset))
            plan.append((offset, n - (n % blockSize)))
            offset += UInt64(n)
            remaining -= n
        }

        let start = Date()
        var moved = 0
        if queueDepth == 1 {
            for request in plan {
                _ = try await device.read(offset: request.offset, length: request.length)
                moved += request.length
            }
        } else {
            // A sliding window: start `queueDepth` reads, and each time one
            // finishes start another. The session multiplexes them over the one
            // connection by ITT, and the CmdSN window bounds how many the target
            // has agreed to accept — so this measures pipelining, not a second
            // socket.
            moved = try await withThrowingTaskGroup(of: Int.self) { group in
                var issued = 0
                var total = 0
                for _ in 0 ..< min(queueDepth, plan.count) {
                    let request = plan[issued]
                    issued += 1
                    group.addTask {
                        _ = try await device.read(offset: request.offset, length: request.length)
                        return request.length
                    }
                }
                while let done = try await group.next() {
                    total += done
                    guard issued < plan.count else { continue }
                    let request = plan[issued]
                    issued += 1
                    group.addTask {
                        _ = try await device.read(offset: request.offset, length: request.length)
                        return request.length
                    }
                }
                return total
            }
        }
        let el = Date().timeIntervalSince(start)
        let mbps = Double(moved) / el / 1_000_000
        print(String(format: "read %.2f GB in %.2fs = %.1f MB/s", Double(moved) / 1e9, el, mbps))
        try await session.logout()
        #else
        print("requires macOS")
        #endif
    }
}

struct Wipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Zero the partition-table regions of a scratch LUN so macOS sees a blank disk. DESTRUCTIVE."
    )

    @OptionGroup var options: GlobalOptions

    @Option(help: "Target IQN to log into.")
    var target: String

    @Option(help: "LUN number.")
    var lun: UInt64 = 0

    @Option(help: "MiB to zero at the start of the LUN (GPT + filesystem superblocks).")
    var headMiB: Int = 16

    @Option(help: "MiB to zero at the end of the LUN (backup GPT).")
    var tailMiB: Int = 1

    func run() async throws {
        #if canImport(Network)
        let transport = try await options.openTransport()
        let config = LoginConfig(
            initiatorName: options.initiator,
            sessionType: .normal,
            targetName: target,
            chap: try options.credentials(),
            trace: options.authTrace
        )
        let connection = ISCSIConnection(transport: transport, login: config)
        _ = try await connection.login()

        let lunAddress = lun << 48

        // A fresh I_T nexus answers its first non-INQUIRY command with UNIT
        // ATTENTION (6/29/00, power-on/reset); absorb it and retry.
        func checked(_ task: SCSITask) async throws -> SCSITaskResult {
            for _ in 0 ..< 3 {
                let result = try await connection.execute(task)
                if result.isGood { return result }
                let sense = result.sense.flatMap(SenseData.init)
                if sense?.key == 0x06 { continue }
                throw ValidationError("SCSI error: status \(result.status), sense \(sense.map(String.init(describing:)) ?? "none")")
            }
            throw ValidationError("persistent UNIT ATTENTION")
        }

        let capacity = try await checked(SCSITask(
            lun: lunAddress, cdb: CDB.readCapacity16(), direction: .read(expectedLength: 32)
        ))
        // The daemon's validated parse, which guards the trapping
        // `lastLBA + 1` and the division by an unchecked zero block size.
        let (blockSize, blockCount) = try ISCSIBlockDevice
            .geometry(fromReadCapacity16: capacity.data)
        print("LUN: \(blockCount) x \(blockSize)-byte blocks")

        // 256 KiB per WRITE(16) keeps each burst well inside any negotiated
        // MaxBurstLength while still finishing a 17 MiB wipe in ~70 commands.
        let chunkBlocks = max(1, (256 * 1024) / blockSize)
        let zeros = Data(count: chunkBlocks * blockSize)

        func zero(range: Range<UInt64>, label: String) async throws {
            var lba = range.lowerBound
            while lba < range.upperBound {
                let blocks = min(UInt64(chunkBlocks), range.upperBound - lba)
                let chunk = blocks == UInt64(chunkBlocks) ? zeros : Data(count: Int(blocks) * blockSize)
                _ = try await checked(SCSITask(
                    lun: lunAddress,
                    cdb: CDB.write16(lba: lba, blocks: UInt32(blocks)),
                    direction: .write(chunk)
                ))
                lba += blocks
            }
            print("  zeroed \(label): LBA \(range.lowerBound) ..< \(range.upperBound)")
        }

        let headBlocks = min(blockCount, UInt64((headMiB * 1_048_576) / blockSize))
        try await zero(range: 0 ..< headBlocks, label: "head")
        let tailBlocks = min(blockCount, UInt64((tailMiB * 1_048_576) / blockSize))
        if tailBlocks > 0 && blockCount > headBlocks {
            let start = max(headBlocks, blockCount - tailBlocks)
            try await zero(range: start ..< blockCount, label: "tail")
        }

        _ = try await checked(SCSITask(lun: lunAddress, cdb: CDB.synchronizeCache16()))
        _ = try await connection.logout()
        print("Wipe complete; the LUN now presents as a blank disk.")
        #else
        throw ValidationError("Network.framework unavailable on this platform")
        #endif
    }
}

// MARK: dext-attach

/// Read the dext's task counters straight out of the driver. During a wedge
/// `log show` hangs and logd loses the window, but bare ssh keeps working —
/// this is the channel that still answers "was every task completed" and
/// "is the dext watchdog alive".
#if ISCSI_BACKEND_B  // Backend B, parked — see DextBridge.swift
struct DextStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dext-stats",
        abstract: "Read the dext's task counters (works while the device is wedged)."
    )

    @Option(help: "Sample twice, this many seconds apart, to show the watchdog tick advancing.")
    var interval: Double = 0

    func run() async throws {
        #if canImport(IOKit)
        let bridge = DextBridge()
        try await bridge.open()
        defer { Task { await bridge.close() } }

        // Built in pieces: as one interpolated expression the type checker
        // gives up on it ("unable to type-check in reasonable time").
        func dump(_ s: DextStats, label: String) {
            var line = "\(label): parked=\(s.parked)"
            line += " full=\(s.parkFull)"
            line += " fetched=\(s.fetched)"
            line += " completed=\(s.completed)"
            line += " wdFail=\(s.watchdogFail)"
            line += " aborted=\(s.aborted)"
            line += " zLate=\(s.zombieLate)"
            line += " zExpired=\(s.zombieExpired)"
            line += " inflight=\(s.inflight)"
            line += " zombies=\(s.zombies)"
            line += " tick=\(s.watchdogTick)"
            print(line)
        }

        let first = try await bridge.stats()
        dump(first, label: "stats")

        if interval > 0 {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let second = try await bridge.stats()
            dump(second, label: "stats")
            // A tick that does not advance means the dext's watchdog thread is
            // not running — which is exactly what a stopped LOG heartbeat could
            // never distinguish from logging having died.
            let advanced = second.watchdogTick > first.watchdogTick
            print(advanced
                ? "watchdog: ALIVE (tick advanced \(first.watchdogTick) -> \(second.watchdogTick))"
                : "watchdog: STALLED (tick stuck at \(first.watchdogTick))")
            let outstanding = second.fetched &- second.completed
            print("outstanding (fetched - completed): \(outstanding)")
        }
        #else
        print("dext-stats requires IOKit (macOS).")
        #endif
    }
}

struct DextAttach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dext-attach",
        abstract: "Log in and serve the LUN to the DriverKit dext as a real block device."
    )

    // The portal is an option (not the usual positional argument) because this
    // command is meant to be typed bare against the test target.
    @Option(help: "Target portal host (IP or DNS name).")
    var portal = "192.168.0.101"

    @Option(help: "Target portal TCP port.")
    var port: UInt16 = 3260

    @Option(help: "Target IQN to log into.")
    var target = "iqn.me.herko.planet-express:iscsi-driver-testing"

    @Option(help: "LUN number.")
    var lun: UInt64 = 0

    @Option(help: "Initiator IQN.")
    var initiator = IQN.defaultInitiatorName(
        hostIdentifier: Host.current().localizedName ?? "mac"
    )

    @Option(help: "CHAP username.")
    var chapUser: String?

    @Option(help: ArgumentHelp("File containing the CHAP secret.",
                               discussion: "Or set $ISCSI_CHAP_SECRET."))
    var chapSecretFile: String?

    @Option(help: "Mutual CHAP username (target authenticates to us).")
    var mutualUser: String?

    @Option(help: ArgumentHelp("File containing the mutual CHAP secret.",
                               discussion: "Or set $ISCSI_MUTUAL_SECRET."))
    var mutualSecretFile: String?

    @Flag(help: "Trace every PDU on the wire to stderr.")
    var debug = false

    /// Credentials, or nil when no CHAP user was given. Throws rather than
    /// substituting an empty secret — a missing secret (e.g. `sudo` stripping
    /// the environment) would otherwise produce a well-formed exchange over
    /// `MD5(id ‖ "" ‖ challenge)`. Deliberately no `--chap-secret` option:
    /// see `readSecret`.
    func credentials() throws -> CHAP.Credentials? {
        guard let user = chapUser else { return nil }
        let secret = try readSecret(file: chapSecretFile,
                                    env: "ISCSI_CHAP_SECRET",
                                    label: "CHAP secret")
        let mutual = mutualUser == nil ? nil
            : try readSecret(file: mutualSecretFile,
                             env: "ISCSI_MUTUAL_SECRET",
                             label: "mutual CHAP secret")
        return try CHAP.Credentials.validated(name: user, secret: secret,
                                              mutualName: mutualUser,
                                              mutualSecret: mutual)
    }

    func run() async throws {
        #if canImport(IOKit) && canImport(Network)
        let trace = debug
        let label = portal
        let core = DaemonCore(initiatorName: initiator) { host, port in
            let tcp = try await NetworkTransport.connect(host: host, port: port)
            return trace ? TracingTransport(tcp, label: label) : tcp
        }

        let handle = try await core.login(
            host: portal, port: port, targetIQN: target, lun: lun, chap: try credentials()
        )
        print("Logged in to \(target) LUN \(lun). Session=\(handle)")

        do {
            let (blockSize, blockCount) = try await core.capacity(handle)
            let bytes = blockCount * UInt64(blockSize)
            print("  CAPACITY: \(blockCount) blocks × \(blockSize) bytes = \(bytes / 1_048_576) MiB "
                + "(\(String(format: "%.2f", Double(bytes) / 1_073_741_824)) GiB)")

            let bridge = DextBridge()
            do {
                try await bridge.open()
            } catch {
                print("Cannot open the dext user client: \(error)")
                print("  Is the dext loaded? Check `systemextensionsctl list`.")
                throw ExitCode(1)
            }

            // Ctrl-C has to unwind rather than kill us mid-flight, so the LUN is
            // withdrawn and the session logged out instead of left dangling.
            let pump = Task { await bridge.run(handle: handle, core: core) }
            signal(SIGINT, SIG_IGN)
            let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            interrupts.setEventHandler { pump.cancel() }
            interrupts.resume()

            print("  Attached: servicing SCSI tasks; press Ctrl-C to stop.")
            await pump.value
            interrupts.cancel()

            try? await bridge.unpublish()
            await bridge.close()
            print("Detached.")
        } catch {
            try? await core.logout(handle)
            throw error
        }

        try await core.logout(handle)
        print("Logged out.")
        #else
        throw ValidationError("IOKit/Network unavailable on this platform — dext-attach requires macOS")
        #endif
    }
}

#endif // ISCSI_BACKEND_B