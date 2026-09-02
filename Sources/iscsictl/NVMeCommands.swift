import ArgumentParser
import Foundation
import NVMeKit
import iSCSIDaemon
import iSCSIKit

// iscsictl nvme — the NVMe/TCP one-shots, mirroring discover / verify /
// read-bench. Separate options rather than `GlobalOptions`: the port
// default is 4420, there is no CHAP, and the trace is the NVMe deframer.

struct NVMe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nvme",
        abstract: "NVMe/TCP operations against a subsystem: discover, verify, read-bench.",
        subcommands: [NVMeDiscover.self, NVMeVerify.self, NVMeReadBench.self]
    )
}

struct NVMeOptions: ParsableArguments {
    @Argument(help: "Subsystem host (IP or DNS name).")
    var host: String

    @Option(help: "NVMe/TCP port.")
    var port: UInt16 = 4420

    @Option(help: ArgumentHelp(
        "Host NQN to present.",
        discussion: "Defaults to the same platform-derived NQN the daemon presents, so one "
            + "allowed-hosts entry on the NAS covers both. Or set $NVME_HOST_NQN."))
    var hostNQN: String?

    @Flag(help: "Do not offer header and data digests.")
    var noDigests = false

    @Flag(help: "Trace every PDU on the wire to stderr.")
    var debug = false

    func identity() throws -> NVMeHostIdentity {
        if let explicit = hostNQN ?? ProcessInfo.processInfo.environment["NVME_HOST_NQN"], !explicit.isEmpty {
            do { return try NVMeHostIdentity(nqn: explicit) }
            catch { throw ValidationError("\(explicit) is not a valid NQN") }
        }
        guard HostIdentity.platformUUID() != nil else {
            throw ValidationError("no platform UUID to derive a host NQN from; pass --host-nqn")
        }
        return HostIdentity.nvmeHost()
    }

    func openTransport() async throws -> any ConnectionTransport {
        #if canImport(Network)
        let tcp = try await NetworkTransport.connect(host: host, port: port)
        return debug ? NVMeTracingTransport(tcp, label: host) : tcp
        #else
        throw ValidationError("Network.framework unavailable on this platform")
        #endif
    }

    func controller(subsystem: String) throws -> NVMeController {
        var config = NVMeControllerConfig(host: try identity(), subsystemNQN: subsystem)
        config.requestDigests = !noDigests
        return NVMeController(config: config) { try await openTransport() }
    }
}

// MARK: discover

struct NVMeDiscover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Read the discovery log page and list the subsystems it advertises."
    )

    @OptionGroup var options: NVMeOptions

    func run() async throws {
        let host = try options.identity()
        FileHandle.standardError.write(Data("host NQN: \(host.nqn)\n".utf8))
        let found = try await NVMeDiscovery.getLogPage(
            transport: try await options.openTransport(), host: host,
            requestDigests: !options.noDigests)
        if found.isEmpty {
            print("(no NVM subsystems advertised over TCP)")
        }
        for target in found {
            print("\(target.name)\t\(target.addresses.joined(separator: ","))")
        }
    }
}

// MARK: verify

struct NVMeVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Connect, identify, and run a read (or read/write/verify with --write) against a namespace. --write is DESTRUCTIVE."
    )

    @OptionGroup var options: NVMeOptions

    @Option(help: "Subsystem NQN to connect to.")
    var subsystem: String

    @Option(help: "Namespace ID.")
    var nsid: UInt32 = 1

    @Flag(help: "Also write (DESTRUCTIVE — only use a scratch namespace).")
    var write = false

    @Option(help: "Starting LBA for the write/verify sweep.")
    var lba: UInt64 = 0

    @Option(help: "Number of blocks per I/O.")
    var blocks: UInt32 = 8

    func run() async throws {
        let host = try options.identity()
        print("host NQN: \(host.nqn)")
        let controller = try options.controller(subsystem: subsystem)
        try await controller.activate()
        let pairs = await controller.displayPairs
        print("Connected. CNTLID=\(pairs["CNTLID"] ?? "?") model=\(pairs["Model"] ?? "?") "
              + "serial=\(pairs["Serial"] ?? "?") firmware=\(pairs["Firmware"] ?? "?")")
        print("  HeaderDigest=\(pairs["HeaderDigest"] ?? "?") DataDigest=\(pairs["DataDigest"] ?? "?") "
              + "MDTS=\(pairs["MDTS"] ?? "?") IOCCSZ=\(pairs["IOCCSZ"] ?? "?") VWC=\(pairs["VWC"] ?? "?")")
        let namespaces = try await controller.activeNamespaces()
        print("  namespaces: \(namespaces.map(String.init).joined(separator: ", "))")

        let device = NVMeBlockDevice(controller: controller, nsid: nsid, writeThrough: true)
        let (blockSize, blockCount) = try await device.readCapacity()
        print("  NSID \(nsid): \(blockCount) blocks × \(blockSize) bytes = "
              + "\(blockCount * UInt64(blockSize) / 1_048_576) MiB")

        let byteCount = Int(blocks) * blockSize
        let offset = lba * UInt64(blockSize)
        if write {
            let pattern = Data((0 ..< byteCount).map { UInt8(($0 &* 0x9E) & 0xFF) })
            try await device.write(offset: offset, data: pattern)
            try await device.flush()
            let readback = try await device.read(offset: offset, length: byteCount)
            if readback == pattern {
                print("  VERIFY: OK (\(byteCount) bytes round-tripped at LBA \(lba), FUA + Flush)")
            } else {
                print("  VERIFY: FAILED — data mismatch")
                throw ExitCode(1)
            }
        } else {
            let readback = try await device.read(offset: offset, length: byteCount)
            print("  READ: \(readback.count) bytes at LBA \(lba) (read-only; pass --write to test integrity)")
        }
        try await controller.logout()
        print("Disconnected.")
    }
}

// MARK: read-bench

struct NVMeReadBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read-bench",
        abstract: "Sequential read throughput over raw NVMe/TCP (no filesystem, no disk image)."
    )

    @OptionGroup var options: NVMeOptions

    @Option(help: "Subsystem NQN to connect to.")
    var subsystem: String

    @Option(help: "Namespace ID.")
    var nsid: UInt32 = 1

    @Option(help: "Megabytes to read.")
    var megabytes: Int = 512

    @Option(help: "Bytes per request.")
    var chunk: Int = 1 << 20

    @Option(help: "Starting offset in megabytes (skip cached regions).")
    var offsetMB: Int = 0

    @Option(help: "Requests to keep outstanding at once.")
    var queueDepth: Int = 1

    @Option(help: "Cap on a single NVMe command; a larger request is split into several issued together.")
    var maxTransfer: Int = 256 << 10

    func run() async throws {
        guard queueDepth >= 1 else { throw ValidationError("--queue-depth must be at least 1") }
        let controller = try options.controller(subsystem: subsystem)
        try await controller.activate()
        let device = NVMeBlockDevice(controller: controller, nsid: nsid, maxTransferBytes: maxTransfer)
        let (blockSize, blockCount) = try await device.readCapacity()
        let capacity = UInt64(blockSize) * blockCount
        print("capacity \(capacity / 1_048_576) MiB, blockSize \(blockSize), "
              + "chunk \(chunk), maxTransfer \(maxTransfer), queueDepth \(queueDepth), "
              + "MDTS \(await controller.displayPairs["MDTS"] ?? "?")")

        var offset = UInt64(offsetMB) * 1_048_576
        offset -= offset % UInt64(blockSize)
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
        try await controller.logout()
    }
}
