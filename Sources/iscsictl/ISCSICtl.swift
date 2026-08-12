import ArgumentParser
import Foundation
import iSCSIDaemon
import iSCSIKit

// iscsictl — control CLI. In Phase 4 the read-only protocol operations
// (discover, verify) run directly against a target over TCP. The login/attach
// operations that manage a persistent session are handled by the daemon
// (later in Phase 4) via XPC; here they are exposed as direct one-shots too.

@main
struct ISCSICtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iscsictl",
        abstract: "Control the macOS iSCSI initiator.",
        version: "0.1.0",
        subcommands: [Discover.self, Verify.self, DextAttach.self]
    )
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

    @Option(help: "CHAP secret (prefer $ISCSI_CHAP_SECRET env var).")
    var chapSecret: String?

    @Option(help: "Mutual CHAP username (target authenticates to us).")
    var mutualUser: String?

    @Option(help: "Mutual CHAP secret.")
    var mutualSecret: String?

    @Flag(help: "Trace every PDU on the wire to stderr.")
    var debug = false

    func credentials() -> CHAP.Credentials? {
        guard let user = chapUser else { return nil }
        let secret = chapSecret ?? ProcessInfo.processInfo.environment["ISCSI_CHAP_SECRET"] ?? ""
        return CHAP.Credentials(
            name: user, secret: secret,
            mutualName: mutualUser,
            mutualSecret: mutualSecret ?? ProcessInfo.processInfo.environment["ISCSI_MUTUAL_SECRET"]
        )
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
            chap: options.credentials()
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
            chap: options.credentials()
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

        let capacity = try await connection.execute(SCSITask(
            lun: lunAddress, cdb: CDB.readCapacity16(), direction: .read(expectedLength: 32)
        ))
        var blockSize: UInt32 = 512
        if capacity.data.count >= 12 {
            let lastLBA = capacity.data.beU64(0)
            blockSize = capacity.data.beU32(8)
            print("  CAPACITY: \(lastLBA + 1) blocks × \(blockSize) bytes = \((lastLBA + 1) * UInt64(blockSize) / 1_048_576) MiB")
        }

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

// MARK: dext-attach

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

    @Option(help: "CHAP secret (prefer $ISCSI_CHAP_SECRET env var).")
    var chapSecret: String?

    @Option(help: "Mutual CHAP username (target authenticates to us).")
    var mutualUser: String?

    @Option(help: "Mutual CHAP secret.")
    var mutualSecret: String?

    @Flag(help: "Trace every PDU on the wire to stderr.")
    var debug = false

    func credentials() -> CHAP.Credentials? {
        guard let user = chapUser else { return nil }
        let secret = chapSecret ?? ProcessInfo.processInfo.environment["ISCSI_CHAP_SECRET"] ?? ""
        return CHAP.Credentials(
            name: user, secret: secret,
            mutualName: mutualUser,
            mutualSecret: mutualSecret ?? ProcessInfo.processInfo.environment["ISCSI_MUTUAL_SECRET"]
        )
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
            host: portal, port: port, targetIQN: target, lun: lun, chap: credentials()
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
