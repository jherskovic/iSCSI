import Foundation
import NVMeKit
import iSCSIKit

/// The daemon's session registry and block-I/O engine, independent of the XPC
/// transport so it can be unit-tested directly. Each session handle maps to a
/// live session (iSCSI or NVMe/TCP) and the block device over it. Which
/// protocol a login speaks is decided in exactly one place, `login`, from
/// the target name's prefix.
public actor DaemonCore {
    struct SessionEntry {
        let session: any FabricSession
        let device: any BlockDeviceBackend
        let targetIQN: String
        let lun: UInt64
        let flushPolicy: FlushPolicy
        /// The periodic SYNCHRONIZE CACHE loop; only `.interval` sessions
        /// have one.
        var flushTask: Task<Void, Never>?
        /// Bumped on every write; compared against `flushedGeneration` so an
        /// idle session's timer skips the round trip. Two counters rather
        /// than a dirty flag because `flush` suspends the actor: a write that
        /// lands mid-flush must not have its dirtiness cleared by the flush
        /// that missed it.
        var writeGeneration: UInt64 = 0
        var flushedGeneration: UInt64 = 0
    }

    private var sessions: [String: SessionEntry] = [:]
    private var handleCounter: UInt64 = 0
    private let initiatorName: String
    /// The NVMe host NQN and HOSTID presented in every Connect.
    private let hostIdentity: NVMeHostIdentity
    /// How to build a transport to a portal. Injected so tests can use
    /// MemoryPipe and production uses NetworkTransport. NVMe calls it twice
    /// per attach (admin queue, I/O queue) and twice per recovery.
    private let transportFactory: @Sendable (String, UInt16) async throws -> any ConnectionTransport
    /// Whether writes carry FUA. See the note at the call site in `login`.
    private let writeThrough: Bool
    /// Keepalive cadence, recovery backoff, and the per-task deadline. One
    /// policy for both protocols: NVMe's Keep Alive runs on `nopInterval`.
    private let policy: SessionPolicy

    public init(
        initiatorName: String,
        writeThrough: Bool = true,
        policy: SessionPolicy = SessionPolicy(),
        hostIdentity: NVMeHostIdentity? = nil,
        transportFactory: @escaping @Sendable (String, UInt16) async throws -> any ConnectionTransport
    ) {
        self.initiatorName = initiatorName
        self.hostIdentity = hostIdentity ?? HostIdentity.nvmeHost()
        self.writeThrough = writeThrough
        self.policy = policy
        self.transportFactory = transportFactory
    }

    /// The host NQN this daemon presents, for the app to show.
    public var hostNQN: String { hostIdentity.nqn }

    /// iSCSIKit narrates the login exchange through a closure rather than a
    /// logger of its own — see `LoginConfig.trace`. This is where the daemon
    /// supplies one.
    static let authTrace: @Sendable (String) -> Void = { DaemonLog.auth($0) }

    public func discover(host: String, port: UInt16, chap: CHAP.Credentials? = nil) async throws -> [DiscoveredTarget] {
        let transport = try await transportFactory(host, port)
        return try await Discovery.sendTargets(
            transport: transport,
            initiatorName: initiatorName,
            chap: chap,
            trace: Self.authTrace
        )
    }

    /// NVMe/TCP discovery at a portal: the discovery log page's subsystems.
    public func discoverSubsystems(host: String, port: UInt16) async throws -> [DiscoveredTarget] {
        let transport = try await transportFactory(host, port)
        return try await NVMeDiscovery.getLogPage(transport: transport, host: hostIdentity)
    }

    public func login(
        host: String,
        port: UInt16,
        targetIQN: String,
        lun: UInt64,
        chap: CHAP.Credentials? = nil,
        flushPolicy: FlushPolicy? = nil
    ) async throws -> String {
        // A record's stored policy wins; nil is a record-less login
        // (iscsictl direct), which follows the ISCSI_WRITE_THROUGH default.
        let durability = flushPolicy ?? (writeThrough ? FlushPolicy.writeThrough : FlushPolicy.never)
        // Write-through by default: FSKit delivers no barrier signal, so a
        // volatile target cache can lose an acknowledged write APFS believes
        // was barriered. FUA trades throughput for crash consistency; it is a
        // no-op when the target's cache is already disabled.
        let writeThrough = durability == .writeThrough

        // The one place the protocol is decided: an NQN attaches over
        // NVMe/TCP, anything else is iSCSI.
        let session: any FabricSession
        let device: any BlockDeviceBackend
        if IQN.isNQN(targetIQN) {
            (session, device) = try await attachNVMe(host: host, port: port, subsystemNQN: targetIQN,
                                                     nsid: lun, chap: chap, writeThrough: writeThrough)
        } else {
            (session, device) = try await attachISCSI(host: host, port: port, targetIQN: targetIQN,
                                                      lun: lun, chap: chap, writeThrough: writeThrough)
        }
        _ = try await device.readCapacity() // fail fast if the LUN is bad

        // Log the cache policy once per session: WCE set without
        // write-through means durability depends on flushes we never receive.
        // Built in pieces — the type checker chokes on one interpolation.
        let wce = try? await device.writeCacheEnabled()
        let cacheLabel: String
        switch wce {
        case .some(true): cacheLabel = "ENABLED"
        case .some(false): cacheLabel = "disabled"
        case nil: cacheLabel = "unknown (target returned no caching page)"
        }
        let policyLabel: String
        switch durability {
        case .writeThrough: policyLabel = "write-through (FUA)"
        case .interval(let seconds): policyLabel = "flush every \(seconds)s"
        case .never: policyLabel = "no periodic flush (cache declared non-volatile)"
        }
        var line = "iscsid: " + targetIQN + (IQN.isNQN(targetIQN) ? " nsid " : " lun ") + String(lun)
        line += ": write cache " + cacheLabel + ", " + policyLabel
        DaemonLog.session(line)

        // Route recovery events into the unified log; otherwise a session can
        // drop, rebuild, and give up with nothing behind but the login banner
        // and an I/O that never returns.
        let logTarget = targetIQN
        await session.setEventHandler { event in
            switch event {
            case .connectionLost(let reason):
                DaemonLog.session("\(logTarget): connection lost (\(reason)); recovering")
            case .recoveryAttempt(let number, let total):
                DaemonLog.session("\(logTarget): recovery attempt \(number)/\(total)")
            case .recovered(let total):
                DaemonLog.session("\(logTarget): recovered (\(total) time(s) so far)")
            case .recoveryExhausted(let lastError):
                DaemonLog.error("\(logTarget): RECOVERY EXHAUSTED after \(lastError). "
                                + "Every I/O on this session will now fail, and anything "
                                + "already waiting on it stays blocked until it does.")
            }
        }

        handleCounter += 1
        let handle = "s\(handleCounter)"
        sessions[handle] = SessionEntry(session: session, device: device,
                                        targetIQN: targetIQN, lun: lun,
                                        flushPolicy: durability)
        if case .interval(let seconds) = durability {
            sessions[handle]?.flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
                    await self?.flushIfDirty(handle)
                }
            }
        }
        return handle
    }

    private func attachISCSI(
        host: String, port: UInt16, targetIQN: String, lun: UInt64,
        chap: CHAP.Credentials?, writeThrough: Bool
    ) async throws -> (any FabricSession, any BlockDeviceBackend) {
        var config = LoginConfig(
            initiatorName: initiatorName,
            sessionType: .normal,
            targetName: targetIQN,
            chap: chap,
            trace: Self.authTrace
        )
        // Resolved credentials must be used: a nil `chap` downstream means
        // "offer AuthMethod=None", so dropping them would silently downgrade
        // the session rather than fail.
        config.requiresAuthentication = chap != nil
        config.desired.offerDigests = true
        let factory = transportFactory
        let session = ISCSISession(login: config, policy: policy) {
            try await factory(host, port)
        }
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: lun, writeThrough: writeThrough)
        return (ISCSIFabricSession(session: session), device)
    }

    private func attachNVMe(
        host: String, port: UInt16, subsystemNQN: String, nsid: UInt64,
        chap: CHAP.Credentials?, writeThrough: Bool
    ) async throws -> (any FabricSession, any BlockDeviceBackend) {
        // NSIDs are 32-bit; a larger value is a bad record, not a wire
        // request, and 0xFFFFFFFF clamped from it would mean "every namespace".
        guard let namespace = UInt32(exactly: nsid) else {
            throw BlockDeviceError.nvmeStatus(sct: 0, sc: 0x0B, opcode: NVMeOpcode.Admin.identify)
        }
        if chap != nil {
            // There is no CHAP on NVMe-oF; the editor never stores one for an
            // NQN, so this is a hand-edited record. Say so rather than fail.
            DaemonLog.auth("\(subsystemNQN): ignoring CHAP credentials — access to an NVMe "
                           + "subsystem is by host NQN (\(hostIdentity.nqn)), not CHAP")
        }
        var config = NVMeControllerConfig(host: hostIdentity, subsystemNQN: subsystemNQN)
        config.requestDigests = true
        let factory = transportFactory
        let controller = NVMeController(config: config, policy: policy) {
            try await factory(host, port)
        }
        try await controller.activate()
        let device = NVMeBlockDevice(controller: controller, nsid: namespace, writeThrough: writeThrough)
        return (NVMeFabricSession(controller: controller), device)
    }

    /// One tick of an `.interval` session's timer: SYNCHRONIZE CACHE, but only
    /// if something was written since the last one — an idle session should
    /// not keep a network round trip on a metronome.
    private func flushIfDirty(_ handle: String) async {
        guard let entry = sessions[handle],
              entry.writeGeneration > entry.flushedGeneration else { return }
        let goal = entry.writeGeneration
        do {
            try await entry.device.flush()
            // Only advance to what this flush provably covered; a write that
            // landed while the flush was in flight stays dirty.
            if let current = sessions[handle], current.flushedGeneration < goal {
                sessions[handle]?.flushedGeneration = goal
            }
        } catch {
            // The next tick retries. A failing flush must not tear the session
            // down by itself — the death latch decides that from the I/O path.
            DaemonLog.error("\(entry.targetIQN): periodic SYNCHRONIZE CACHE failed (\(error)); retrying next tick")
        }
    }

    public func logout(_ handle: String) async throws {
        guard let entry = sessions.removeValue(forKey: handle) else { return }
        entry.flushTask?.cancel()
        // Under FUA every acknowledged write is already durable. In either
        // relaxed mode the target's cache may hold acknowledged writes, and
        // this detach is the last chance to commit them.
        if entry.flushPolicy != .writeThrough {
            do {
                try await entry.device.flush()
            } catch {
                DaemonLog.error("\(entry.targetIQN): SYNCHRONIZE CACHE on detach failed (\(error)); "
                                + "writes acknowledged since the last flush may not be on stable media")
            }
        }
        try await entry.session.logout()
    }

    public func capacity(_ handle: String) async throws -> (blockSize: Int, blockCount: UInt64) {
        try await device(handle).readCapacity()
    }

    public func read(_ handle: String, offset: UInt64, length: Int) async throws -> Data {
        try await device(handle).read(offset: offset, length: length)
    }

    public func write(_ handle: String, offset: UInt64, data: Data) async throws {
        try await device(handle).write(offset: offset, data: data)
        sessions[handle]?.writeGeneration += 1
    }

    public func flush(_ handle: String) async throws {
        // Deliberately does not advance `flushedGeneration`: this path has no
        // proof of which writes it covered relative to the counter. The worst
        // case is one redundant SYNCHRONIZE CACHE on an interval session's
        // next tick, which is cheaper than reasoning about the race.
        try await device(handle).flush()
    }

    /// Every live session with everything the diagnostics pane needs.
    public func sessionDetails() async -> [SessionInfo] {
        var out: [SessionInfo] = []
        for (handle, entry) in sessions {
            // Deliberately tolerant: a wedged session is exactly when someone
            // opens this pane, so one unavailable field must not cost them the
            // rest of the row.
            let wce = try? await entry.device.writeCacheEnabled()
            let blockSize = await entry.device.blockSize
            let blockCount = await entry.device.blockCount
            let recoveries = await entry.session.recoveryCount
            let negotiated = await entry.session.displayPairs
            out.append(SessionInfo(
                handle: handle,
                targetIQN: entry.targetIQN,
                lun: entry.lun,
                blockSize: blockSize,
                blockCount: blockCount,
                writeCacheEnabled: wce ?? nil,
                writeThrough: entry.flushPolicy == .writeThrough,
                recoveryCount: recoveries,
                negotiated: negotiated
            ))
        }
        return out.sorted { $0.handle < $1.handle }
    }

    /// REPORT LUNS (or the active namespace list) against an established
    /// session, for the GUI's LUN picker.
    public func reportLUNs(_ handle: String) async throws -> [LUNInfo] {
        guard let entry = sessions[handle] else { throw SessionError.notActive }
        return try await entry.session.listUnits()
    }

    /// Decode one 8-byte REPORT LUNS entry (SAM-2 first-level field):
    /// peripheral addressing (00b, bus 0) or flat-space addressing (01b).
    /// Entries in other formats are skipped rather than misread.
    static func lunNumber(fromReportLUNsEntry entry: Data) -> UInt64? {
        guard entry.count >= 8 else { return nil }
        let b0 = entry.u8(0)
        switch b0 & 0xC0 {
        case 0x00:
            guard b0 & 0x3F == 0 else { return nil } // multi-level: unsupported
            return UInt64(entry.u8(1))
        case 0x40:
            return (UInt64(b0 & 0x3F) << 8) | UInt64(entry.u8(1))
        default:
            return nil
        }
    }

    public func sessionHandles() -> [String] {
        Array(sessions.keys).sorted()
    }

    private func device(_ handle: String) throws -> any BlockDeviceBackend {
        guard let entry = sessions[handle] else { throw BlockDeviceError.notReady }
        return entry.device
    }
}
