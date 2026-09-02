import Foundation
import iSCSIKit

/// Who we are and what we are attaching to.
public struct NVMeControllerConfig: Sendable {
    public var host: NVMeHostIdentity
    public var subsystemNQN: String
    /// Offer header and data digests in ICReq; the controller picks.
    public var requestDigests = true
    /// I/O queue depth to ask for, clamped to CAP.MQES.
    public var ioQueueEntries: UInt16 = 128
    public var adminQueueEntries: UInt16 = 32
    /// KATO for the admin Connect, in ms. nil derives twice the keepalive
    /// interval from the session policy (0, i.e. no timer, when the policy
    /// runs no keepalive).
    public var keepAliveMS: UInt32?

    public init(host: NVMeHostIdentity, subsystemNQN: String) {
        self.host = host
        self.subsystemNQN = subsystemNQN
    }
}

/// One NVMe-oF controller: an admin queue and one I/O queue, each its own
/// TCP connection, brought up together and torn down together. Owns
/// keepalive and recovery the way `ISCSISession` does: any loss of either
/// queue destroys the pair, and the next command rebuilds a fresh one.
public actor NVMeController {
    public typealias TransportFactory = @Sendable () async throws -> any ConnectionTransport

    private enum QueueKind { case admin, io }

    /// The largest inbound I/O PDU: nvmet answers a read with a single
    /// C2HData for the whole transfer, so this bounds the transfer size.
    static let ioPDULimit = (1 << 20) + 4096
    static let adminPDULimit = 64 << 10
    /// The largest single Read a block device may issue: what fits in one
    /// inbound PDU with room for the header and digests.
    public static let maxIOTransferBytes = ioPDULimit - 4096

    private let makeTransport: TransportFactory
    private let config: NVMeControllerConfig
    private let policy: SessionPolicy

    private var admin: NVMeQueue?
    private var io: NVMeQueue?
    private var controllerID: UInt16 = 0
    private var capabilities: ControllerCapabilities?
    public private(set) var identity: IdentifyController?
    public private(set) var digests = NVMeTCPDigests()
    private var keepaliveTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, any Error>?
    private var loggedOut = false
    /// Diagnostics for tests and status reporting.
    public private(set) var recoveryCount = 0
    private var onEvent: (@Sendable (SessionEvent) -> Void)?

    public init(config: NVMeControllerConfig, policy: SessionPolicy = SessionPolicy(),
                transportFactory: @escaping TransportFactory) {
        self.config = config
        self.policy = policy
        self.makeTransport = transportFactory
    }

    public func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void) {
        onEvent = handler
    }

    public var subsystemNQN: String { config.subsystemNQN }

    /// VWC from Identify Controller: whether FUA and Flush mean anything.
    public var volatileWriteCachePresent: Bool? { identity?.volatileWriteCachePresent }

    /// MDTS in bytes; nil when the controller sets no limit.
    public var maxTransferBytes: Int? {
        guard let identity, let capabilities else { return nil }
        return identity.maxTransferBytes(pageBytes: capabilities.minPageBytes)
    }

    var keepAliveMS: UInt32 {
        if let explicit = config.keepAliveMS { return explicit }
        guard let interval = policy.nopInterval else { return 0 }
        return UInt32(clamping: Self.milliseconds(interval) * 2)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - Lifecycle

    public func activate() async throws {
        guard io == nil else { return }
        loggedOut = false
        try await establish()
    }

    public func logout() async throws {
        loggedOut = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        // Best effort: clear CC.EN so the controller shuts down cleanly.
        // nvmet frees the controller when the admin connection closes anyway.
        if let admin {
            _ = try? await withDeadline(.seconds(2)) {
                _ = try await admin.submit(NVMeCommands.propertySet(commandID: 0, offset: NVMeProperty.cc, value: 0))
            }
        }
        await dropQueues()
    }

    // MARK: - Command execution

    /// Run an I/O command to a successful completion, transparently
    /// rebuilding the controller and retrying on connection loss (bounded by
    /// policy). Block I/O is idempotent, so the retry is safe.
    public func execute(_ sqe: SQE, data: Data = Data(), expectedRead: Int = 0) async throws -> NVMeCompletion {
        try await execute(on: .io, sqe, data: data, expectedRead: expectedRead)
    }

    /// The same for admin commands.
    public func executeAdmin(_ sqe: SQE, expectedRead: Int = 0) async throws -> NVMeCompletion {
        try await execute(on: .admin, sqe, data: Data(), expectedRead: expectedRead)
    }

    private func execute(on kind: QueueKind, _ sqe: SQE, data: Data, expectedRead: Int) async throws -> NVMeCompletion {
        var attempt = 0
        while true {
            let queue = try await ensureActive(kind)
            do {
                return try await withDeadline(policy.taskTimeout) {
                    try await queue.submitChecked(sqe, data: data, expectedRead: expectedRead)
                }
            } catch let error as ConnectionError {
                try Task.checkCancellation()
                guard !loggedOut, attempt < policy.taskRetries else { throw error }
                attempt += 1
                try await recover(after: error)
            } catch is DeadlineError {
                try Task.checkCancellation()
                // No usable Abort on NVMe-oF: drop the pair rather than let a
                // wedge be inherited, and rebuild on the next attempt.
                guard !loggedOut, attempt < policy.taskRetries else {
                    await dropQueues()
                    throw SessionError.taskTimedOut
                }
                attempt += 1
                try await recover(after: nil)
            }
        }
    }

    /// Identify Active Namespace ID list.
    public func activeNamespaces() async throws -> [UInt32] {
        let completion = try await executeAdmin(
            NVMeCommands.identify(commandID: 0, cns: IdentifyCNS.activeNamespaces, nsid: 0),
            expectedRead: IdentifyNamespace.size)
        return ActiveNamespaceList.parse(completion.data)
    }

    /// Identify Namespace, reduced to the geometry a block device needs.
    public func identifyNamespace(_ nsid: UInt32) async throws -> (blockSize: Int, blockCount: UInt64) {
        let completion = try await executeAdmin(
            NVMeCommands.identify(commandID: 0, cns: IdentifyCNS.namespace, nsid: nsid),
            expectedRead: IdentifyNamespace.size)
        return try IdentifyNamespace.geometry(from: completion.data)
    }

    /// Label/value pairs for the Sessions pane, the `OperationalParameters.
    /// displayPairs` twin.
    public var displayPairs: [String: String] {
        var out: [String: String] = [
            "HeaderDigest": digests.header ? "CRC32C" : "None",
            "DataDigest": digests.data ? "CRC32C" : "None",
            "KATO": "\(keepAliveMS) ms",
            "CNTLID": String(controllerID),
        ]
        if let identity {
            out["Model"] = identity.model
            out["Serial"] = identity.serial
            out["Firmware"] = identity.firmware
            out["VWC"] = identity.volatileWriteCachePresent ? "present" : "absent"
            out["MDTS"] = maxTransferBytes.map { "\($0) bytes" } ?? "unlimited"
            out["IOCCSZ"] = "\(identity.inCapsuleDataBytes) bytes in-capsule"
        }
        if let capabilities {
            out["MQES"] = String(capabilities.maxQueueEntries)
        }
        return out
    }

    // MARK: - Bring-up

    private func ensureActive(_ kind: QueueKind) async throws -> NVMeQueue {
        if loggedOut { throw SessionError.loggedOut }
        if let queue = (kind == .admin ? admin : io) { return queue }
        try await recover(after: nil)
        guard let queue = (kind == .admin ? admin : io) else { throw SessionError.notActive }
        return queue
    }

    /// Admin queue up and the controller enabled — shared with discovery,
    /// which stops here.
    static func bringUpAdminQueue(
        _ queue: NVMeQueue, host: NVMeHostIdentity, subsystemNQN: String, keepAliveMS: UInt32
    ) async throws -> (controllerID: UInt16, capabilities: ControllerCapabilities) {
        let (controllerID, authRequired) = try await queue.connect(
            host: host, subsystemNQN: subsystemNQN, controllerID: 0xFFFF, keepAliveMS: keepAliveMS)
        if authRequired {
            // Surfaced as the status the spec assigns it, so the error text
            // can say what to switch off on the NAS.
            throw BlockDeviceError.nvmeStatus(sct: 1, sc: 0x91, opcode: NVMeOpcode.Admin.fabrics)
        }
        let cap = ControllerCapabilities(raw: try await queue.submitChecked(
            NVMeCommands.propertyGet(commandID: 0, offset: NVMeProperty.cap, wide: true)).cqe.result64)
        guard cap.supportsNVMCommandSet else {
            throw ConnectionError.protocolError("controller does not support the NVM command set")
        }
        _ = try await queue.submitChecked(NVMeCommands.propertySet(
            commandID: 0, offset: NVMeProperty.cc, value: NVMeCommands.controllerConfigurationEnable))
        // CSTS.RDY follows CC.EN within CAP.TO; CFS means it never will.
        try await withDeadline(.milliseconds(max(cap.readyTimeoutMS, 500))) {
            while true {
                let raw = try await queue.submitChecked(
                    NVMeCommands.propertyGet(commandID: 0, offset: NVMeProperty.csts, wide: false)).cqe.dw0
                let csts = ControllerStatus(raw: raw)
                if csts.fatal { throw BlockDeviceError.notReady }
                if csts.ready { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        return (controllerID, cap)
    }

    private func establish() async throws {
        let adminQueue = NVMeQueue(
            transport: try await makeTransport(), queueID: 0, entries: config.adminQueueEntries,
            requestDigests: config.requestDigests, maxPDUBytes: Self.adminPDULimit)
        do {
            let (cntlid, cap) = try await Self.bringUpAdminQueue(
                adminQueue, host: config.host, subsystemNQN: config.subsystemNQN, keepAliveMS: keepAliveMS)
            controllerID = cntlid
            capabilities = cap
            digests = await adminQueue.digests

            let id = try IdentifyController(data: try await adminQueue.submitChecked(
                NVMeCommands.identify(commandID: 0, cns: IdentifyCNS.controller),
                expectedRead: IdentifyController.size).data)
            identity = id
            // One I/O submission queue and one completion queue (0's based).
            _ = try await adminQueue.submitChecked(NVMeCommands.setFeatures(
                commandID: 0, featureID: NVMeFeature.numberOfQueues, dword11: 0))

            let entries = UInt16(clamping: min(Int(config.ioQueueEntries), cap.maxQueueEntries))
            let ioQueue = NVMeQueue(
                transport: try await makeTransport(), queueID: 1, entries: max(entries, 2),
                requestDigests: config.requestDigests, maxPDUBytes: Self.ioPDULimit)
            do {
                _ = try await ioQueue.connect(host: config.host, subsystemNQN: config.subsystemNQN,
                                              controllerID: cntlid, keepAliveMS: 0)
                // In-capsule data is addressed from ICDOFF, which this
                // initiator only supports at 0 (nvmet's value); anything
                // else means every write is solicited instead.
                await ioQueue.setInCapsuleLimit(id.inCapsuleDataOffsetBytes == 0 ? id.inCapsuleDataBytes : 0)
            } catch {
                await ioQueue.close()
                throw error
            }
            admin = adminQueue
            io = ioQueue
            startKeepalive(on: adminQueue)
            watchForClose(of: adminQueue)
            watchForClose(of: ioQueue)
        } catch {
            await adminQueue.close()
            throw error
        }
    }

    /// Tear both queues down without rebuilding. The next `ensureActive`
    /// starts fresh, so a wedge is not inherited by whoever comes next.
    private func dropQueues() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        let oldAdmin = admin
        let oldIO = io
        admin = nil
        io = nil
        await oldIO?.close()
        await oldAdmin?.close()
    }

    /// Recovery: tear the pair down, back off, bring a fresh pair up.
    /// Coalesces concurrent callers onto a single recovery task.
    private func recover(after error: ConnectionError?) async throws {
        if let existing = recoveryTask {
            try await existing.value
            return
        }
        onEvent?(.connectionLost(reason: error.map { "\($0)" } ?? "no active controller"))
        await dropQueues()

        let task = Task { [policy, onEvent] in
            var lastError = error.map { "\($0)" } ?? "initial"
            for attempt in 0 ..< policy.maxRecoveryAttempts {
                onEvent?(.recoveryAttempt(number: attempt + 1, of: policy.maxRecoveryAttempts))
                if attempt > 0 || error != nil {
                    try await Task.sleep(for: Self.recoveryDelay(attempt: attempt, policy: policy))
                }
                try Task.checkCancellation()
                do {
                    try await self.establishForRecovery()
                    onEvent?(.recovered(totalRecoveries: await self.recoveryCount))
                    return
                } catch {
                    lastError = "\(error)"
                }
            }
            onEvent?(.recoveryExhausted(lastError: lastError))
            throw SessionError.recoveryExhausted(lastError: lastError)
        }
        recoveryTask = task
        defer { recoveryTask = nil }
        try await task.value
    }

    /// Plain exponential backoff; NVMe-oF has no DefaultTime2Wait to honour.
    static func recoveryDelay(attempt: Int, policy: SessionPolicy) -> Duration {
        let factor = 1 << min(attempt, 8)
        return min(policy.recoveryBackoffBase * factor, policy.recoveryBackoffCap)
    }

    private func establishForRecovery() async throws {
        try await establish()
        recoveryCount += 1
    }

    private func startKeepalive(on queue: NVMeQueue) {
        guard let interval = policy.nopInterval else { return }
        keepaliveTask = Task { [policy] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                do {
                    try await withDeadline(policy.nopTimeout) {
                        _ = try await queue.submitChecked(NVMeCommands.keepAlive(commandID: 0))
                    }
                } catch {
                    // Dead peer: kill the queue; execute() paths recover.
                    await queue.close()
                    return
                }
            }
        }
    }

    private func watchForClose(of queue: NVMeQueue) {
        Task { [weak self] in
            _ = await queue.waitClosed()
            await self?.noteClosed(queue)
        }
    }

    /// Either queue closing ends the controller: nvmet frees it when the
    /// admin connection goes, and an I/O queue cannot outlive its admin
    /// queue's identity in any way this initiator wants to reason about.
    private func noteClosed(_ closed: NVMeQueue) async {
        guard closed === admin || closed === io else { return }
        await dropQueues()
    }
}
