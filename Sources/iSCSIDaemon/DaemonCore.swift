import Foundation
import iSCSIKit

/// The daemon's session registry and block-I/O engine, independent of the XPC
/// transport so it can be unit-tested directly. Each session handle maps to a
/// live ISCSISession + ISCSIBlockDevice.
public actor DaemonCore {
    struct SessionEntry {
        let session: ISCSISession
        let device: ISCSIBlockDevice
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
    /// How to build a transport to a portal. Injected so tests can use
    /// MemoryPipe and production uses NetworkTransport.
    private let transportFactory: @Sendable (String, UInt16) async throws -> any ConnectionTransport
    /// Whether writes carry FUA. See the note at the call site in `login`.
    private let writeThrough: Bool
    /// Keepalive cadence, recovery backoff, and the per-task deadline.
    private let policy: SessionPolicy

    public init(
        initiatorName: String,
        writeThrough: Bool = true,
        policy: SessionPolicy = SessionPolicy(),
        transportFactory: @escaping @Sendable (String, UInt16) async throws -> any ConnectionTransport
    ) {
        self.initiatorName = initiatorName
        self.writeThrough = writeThrough
        self.policy = policy
        self.transportFactory = transportFactory
    }

    public func discover(host: String, port: UInt16, chap: CHAP.Credentials? = nil) async throws -> [DiscoveredTarget] {
        let transport = try await transportFactory(host, port)
        return try await Discovery.sendTargets(
            transport: transport,
            initiatorName: initiatorName,
            chap: chap
        )
    }

    public func login(
        host: String,
        port: UInt16,
        targetIQN: String,
        lun: UInt64,
        chap: CHAP.Credentials? = nil,
        flushPolicy: FlushPolicy? = nil
    ) async throws -> String {
        // A record's stored policy wins when the caller resolved one; nil is
        // a record-less login (iscsictl direct), which keeps following the
        // process-wide ISCSI_WRITE_THROUGH default.
        let durability = flushPolicy ?? (writeThrough ? FlushPolicy.writeThrough : FlushPolicy.never)
        var config = LoginConfig(
            initiatorName: initiatorName,
            sessionType: .normal,
            targetName: targetIQN,
            chap: chap
        )
        // Once credentials have been resolved, using them is not optional. A nil
        // `chap` further down means "offer AuthMethod=None", so anything that
        // dropped them between here and the login would downgrade the session
        // silently rather than fail. Cheap to assert, and the failure it guards
        // against is invisible from every layer above.
        config.requiresAuthentication = chap != nil
        config.desired.offerDigests = true
        let factory = transportFactory
        let session = ISCSISession(login: config, policy: policy) {
            try await factory(host, port)
        }
        try await session.activate()
        // Write-through by default. Backend A receives no barrier signal from
        // FSKit, so the daemon cannot know when a filesystem above the disk
        // image wanted a flush; if the target caches writes volatilely, an
        // acknowledged write can be lost on power failure while APFS believes
        // its barrier was honoured. FUA costs throughput and buys crash
        // consistency, which is the right trade for a network disk. It is a
        // no-op when the target's write cache is already disabled.
        let device = ISCSIBlockDevice(session: session, lun: lun,
                                      writeThrough: durability == .writeThrough)
        _ = try await device.readCapacity() // fail fast if the LUN is bad

        // Report the target's cache policy once per session: if WCE is set and
        // we are not writing through, durability depends on flushes we never
        // receive.
        // Built in pieces on purpose: the Swift type checker chokes on this as
        // one interpolated expression.
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
        var line = "iscsid: " + targetIQN + " lun " + String(lun)
        line += ": write cache " + cacheLabel + ", " + policyLabel
        DaemonLog.session(line)

        // Route recovery events into the unified log. Without this a session
        // can drop, rebuild itself five times and give up, leaving nothing
        // behind but the original login banner and an I/O that never returns —
        // which is exactly what happened on 2026-08-15 and could not be
        // diagnosed afterwards.
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
        try await device(handle).flush()
    }

    /// Every live session with everything the diagnostics pane needs.
    ///
    /// All of this already existed inside the actor and none of it had ever
    /// crossed XPC, so a report could say "it felt slow" but never
    /// "firstBurstLength negotiated down to 64 KiB and it recovered four times".
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
            let negotiated = await entry.session.parameters?.displayPairs ?? [:]
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

    /// REPORT LUNS against an established session.
    ///
    /// The first caller of `CDB.reportLuns`, which has been implemented and
    /// unused since the SCSI layer was written. Without it the GUI can only
    /// offer a LUN number typed from memory.
    public func reportLUNs(_ handle: String) async throws -> [LUNInfo] {
        guard let entry = sessions[handle] else { throw SessionError.notActive }
        // Addressed to LUN 0: REPORT LUNS is answered by the target, not by a
        // particular logical unit, and LUN 0 is the one guaranteed to exist.
        let result = try await entry.session.executeChecked(
            SCSITask(lun: 0, cdb: CDB.reportLuns(), direction: .read(expectedLength: 1024)))

        // SPC LUN list: 4-byte list length (in bytes), 4 reserved, then one
        // 8-byte LUN per entry.
        let data = result.data
        guard data.count >= 8 else { return [] }
        let listLength = Int(data.beU32(0))
        var luns: [LUNInfo] = []
        var offset = 8
        while offset + 8 <= min(data.count, 8 + listLength) {
            // Peripheral-device addressing: the LUN is in the second byte of the
            // first two-byte field for single-level addressing, which is all any
            // target this app talks to will use.
            let lun = UInt64(data.u8(offset + 1))
            luns.append(LUNInfo(lun: lun))
            offset += 8
        }
        return luns
    }

    public func sessionHandles() -> [String] {
        Array(sessions.keys).sorted()
    }

    private func device(_ handle: String) throws -> ISCSIBlockDevice {
        guard let entry = sessions[handle] else { throw BlockDeviceError.notReady }
        return entry.device
    }
}
