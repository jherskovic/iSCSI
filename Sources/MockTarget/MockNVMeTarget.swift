import Foundation
import NVMeKit
import iSCSIKit

/// What the simulated NVMe/TCP subsystem looks like to a host. Every knob
/// has the value nvmet would give a plain zvol namespace, so the default
/// configuration is the real target and tests only name what they change.
public struct MockNVMeConfig: Sendable {
    public var subsystemNQN = "nqn.2026-08.test.example:disk0"
    /// The one namespace. NSID 0 is reserved; nvmet numbers from 1.
    public var nsid: UInt32 = 1
    /// nil = allow any host; otherwise the Connect's HOSTNQN must be listed.
    public var allowedHosts: [String]?
    /// Bytes of write data accepted in the command capsule; advertised as
    /// IOCCSZ. nvmet-tcp's default inline size is 16 KiB.
    public var inCapsuleDataBytes = 16384
    /// Largest H2CData PDU we accept, announced in ICResp.
    public var maxH2CData: UInt32 = 65536
    /// C2HData PDU size for reads.
    public var c2hChunkBytes = 65536
    /// MDTS as advertised; 0 = no limit.
    public var mdts: UInt8 = 0
    /// Accept whatever digests the host offers; false answers "none".
    public var acceptDigests = true
    /// Set SUCCESS on the last C2HData and skip the CapsuleResp.
    public var emitSuccessFlag = false
    /// Answer Connect with AUTHREQ set, as a subsystem demanding DH-HMAC-CHAP.
    public var requireAuth = false
    public var model = "MockNVMe"
    public var serial = "MOCK0001"
    public var firmware = "1.0"
    /// CAP.MQES + 1.
    public var maxQueueEntries: UInt16 = 128
    /// MAXCMD in Identify Controller; 0 mirrors `maxQueueEntries`, as nvmet does.
    public var maxOutstandingCommands: UInt16 = 0
    /// Entries for the discovery log page served to the discovery NQN.
    public var discoveryEntries: [(subnqn: String, traddr: String, trsvcid: String)] = []
    /// Subsystems among `discoveryEntries` whose entry says TLS is required
    /// (TREQ = 01b, TSAS SECTYPE = TLS 1.3).
    public var tlsRequiredSubsystems: Set<String> = []
    /// The transport-neutral fault script (drops, stalls, corruption, mute).
    public var faults = MockTargetFaults()
    /// NVMe/TCP-specific misbehaviour.
    public var hostility = MockNVMeHostility()

    public init() {}
}

/// Protocol violations only an NVMe/TCP controller can commit. Off by
/// default; tests switch on the one they probe.
public struct MockNVMeHostility: Sendable {
    /// Answer ICReq with this PDU format version.
    public var icrespPFV: UInt16 = 0
    /// Demand this data alignment in ICResp.
    public var icrespCPDA: UInt8 = 0
    /// Answer the first I/O command with a C2HTermReq instead of serving it.
    public var terminateOnFirstIOCommand = false
    /// Before every I/O completion, complete a CID nobody submitted.
    public var completeUnknownCID = false
    /// I/O reads only: after the real data, one more C2HData of 512 bytes
    /// at the next offset, carrying LAST_PDU. Contiguous on purpose, so the
    /// host's offset check passes and its read-buffer bounds check is what
    /// has to catch it.
    public var c2hDataOverrun = false
    /// Ask, by R2T, for more bytes than the write carries.
    public var r2tOverrun = false
    /// Start the first R2T one block in rather than at offset 0.
    public var r2tSkipsFirstBlock = false
    /// I/O reads only: every C2HData PDU claims DATAO 0.
    public var c2hDataRepeatsOffsetZero = false
    /// I/O reads only: SUCCESS set on a C2HData PDU with LAST_PDU clear.
    public var successWithoutLast = false
    /// I/O reads only: LAST_PDU on the first C2HData of a multi-PDU read.
    public var lastPDUTooEarly = false
    /// Corrupt the payload of the first I/O read only, on the wire.
    public var corruptFirstReadOnly = false

    public init() {}
}

/// In-process NVMe/TCP subsystem. One instance serves any number of
/// connections, because a controller is two of them (admin queue and I/O
/// queue) and the I/O Connect must name the CNTLID the admin Connect
/// returned — so the controller registry lives here, and each connection is
/// a `MockNVMeQueue`. The `RAMDisk` is shared for the same reason
/// `MockTarget` shares it: state must survive a simulated reboot.
///
/// The queues refuse what nvmet refuses, the way nvmet refuses it: commands
/// before CC.EN, a data SGL that does not match the command, a Connect
/// naming the wrong controller, H2CData out of sequence, more commands
/// outstanding than the queue holds. Each refusal is also recorded in
/// `protocolViolations`, so a test can tell an initiator bug from a fault
/// it scripted itself.
public actor MockNVMeSubsystem {
    public let config: MockNVMeConfig
    public let disk: RAMDisk
    /// The shared fault script for the simulator; tests hand each connection
    /// its own box via `serve(_:faultBox:)`.
    public let faultBox: FaultBox

    struct ControllerState {
        let id: UInt16
        let hostNQN: String
        let subsystemNQN: String
        let isDiscovery: Bool
        var cc: UInt32 = 0
        let kato: UInt32
        /// QIDs with a live connection. nvmet frees a controller when the
        /// last of its queues goes, and refuses a second Connect for a QID
        /// that is still installed.
        var queues: Set<UInt16> = []
    }

    private var controllers: [UInt16: ControllerState] = [:]
    private var nextControllerID: UInt16 = 1
    private var live: [MockNVMeQueue] = []

    // Diagnostics the tests assert on.
    public private(set) var connectionsServed = 0
    public private(set) var keepAlivesReceived = 0
    public private(set) var r2tsSent = 0
    public private(set) var h2cDataPDUsReceived = 0
    public private(set) var inCapsuleWrites = 0
    /// Commands swallowed by `stallCommands`, the `stalledITTs` twin.
    public private(set) var stalledCIDs: [UInt16] = []
    /// FES of every H2CTermReq a host sent before closing.
    public private(set) var h2cTermReqsReceived: [NVMeTCPFatalErrorStatus] = []
    /// Property Sets of CC with a shutdown notification (SHN) requested.
    public private(set) var shutdownsRequested = 0
    /// Every host protocol violation a queue refused, in words.
    public private(set) var protocolViolations: [String] = []
    /// Most commands outstanding at once on any queue with this QID.
    public private(set) var peakOutstanding: [UInt16: Int] = [:]

    public init(config: MockNVMeConfig = MockNVMeConfig(), disk: RAMDisk? = nil,
                faultBox: FaultBox? = nil) {
        self.config = config
        self.disk = disk ?? RAMDisk()
        self.faultBox = faultBox ?? FaultBox(config.faults)
    }

    /// Serve one connection until it closes.
    public func serve(_ transport: any ConnectionTransport, faultBox: FaultBox? = nil) async {
        connectionsServed += 1
        let queue = MockNVMeQueue(subsystem: self, config: config, disk: disk,
                                  faultBox: faultBox ?? self.faultBox, transport: transport)
        live.append(queue)
        await queue.run()
        live.removeAll { $0 === queue }
    }

    /// Drop every live connection: the target rebooting.
    public func stop() async {
        let queues = live
        live = []
        for queue in queues { await queue.stop() }
    }

    public var liveConnections: Int { live.count }

    // MARK: Controller registry

    enum ConnectOutcome {
        case accepted(UInt16)
        case invalidHost
        /// Connect Invalid Parameters; `attribute` is the IATTR/IPO value
        /// nvmet returns in DW0 to say which field was wrong.
        case invalidParameter(attribute: UInt32)
        /// The QID is already connected to that controller.
        case commandSequenceError
    }

    /// IPO_IATTR_CONNECT_DATA(cntlid): byte 16 of the Connect data.
    static let connectDataCNTLID: UInt32 = 1 << 16 | 16

    func connectAdmin(hostNQN: String, subsystemNQN: String, kato: UInt32) -> ConnectOutcome {
        let isDiscovery = subsystemNQN == NQN.discovery
        guard isDiscovery || subsystemNQN == config.subsystemNQN else {
            return .invalidParameter(attribute: 1 << 16 | 256)   // SUBNQN
        }
        if let allowed = config.allowedHosts, !allowed.contains(hostNQN) { return .invalidHost }
        let id = nextControllerID
        nextControllerID &+= 1
        controllers[id] = ControllerState(id: id, hostNQN: hostNQN, subsystemNQN: subsystemNQN,
                                          isDiscovery: isDiscovery, kato: kato, queues: [0])
        return .accepted(id)
    }

    /// nvmet_ctrl_find_get: the controller must exist and belong to this
    /// host and this subsystem; discovery controllers have no I/O queues.
    func connectIO(controllerID: UInt16, qid: UInt16, hostNQN: String, subsystemNQN: String) -> ConnectOutcome {
        guard var state = controllers[controllerID], state.hostNQN == hostNQN,
              state.subsystemNQN == subsystemNQN, !state.isDiscovery else {
            return .invalidParameter(attribute: Self.connectDataCNTLID)
        }
        guard state.queues.insert(qid).inserted else { return .commandSequenceError }
        controllers[controllerID] = state
        return .accepted(controllerID)
    }

    func queueClosed(controllerID: UInt16, qid: UInt16) {
        guard var state = controllers[controllerID] else { return }
        state.queues.remove(qid)
        controllers[controllerID] = state.queues.isEmpty ? nil : state
    }

    func controllerConfiguration(_ id: UInt16) -> UInt32 { controllers[id]?.cc ?? 0 }

    func setControllerConfiguration(_ id: UInt16, _ cc: UInt32) {
        controllers[id]?.cc = cc
        if cc & 0xC000 != 0 { shutdownsRequested += 1 }
    }

    /// CSTS.RDY as this model has it: follows CC.EN at once, and drops when
    /// a shutdown is requested — nvmet_update_cc clears the controller then.
    func isReady(_ id: UInt16) -> Bool {
        let cc = controllerConfiguration(id)
        return cc & 1 == 1 && cc & 0xC000 == 0
    }

    func isDiscoveryController(_ id: UInt16) -> Bool { controllers[id]?.isDiscovery ?? false }

    // MARK: Counters

    func noteKeepAlive() { keepAlivesReceived += 1 }
    func noteR2T() { r2tsSent += 1 }
    func noteH2CData() { h2cDataPDUsReceived += 1 }
    func noteInCapsuleWrite() { inCapsuleWrites += 1 }
    func noteStalled(_ cid: UInt16) { stalledCIDs.append(cid) }
    func noteH2CTermReq(_ fes: NVMeTCPFatalErrorStatus) { h2cTermReqsReceived.append(fes) }
    func noteViolation(_ what: String) { protocolViolations.append(what) }
    func noteOutstanding(qid: UInt16, _ count: Int) {
        peakOutstanding[qid] = max(peakOutstanding[qid] ?? 0, count)
    }
}

/// Generic command status values this model answers with (NVMe Base 2.0
/// Figure 102), DNR set as nvmet sets it.
private extension NVMeStatus {
    static let invalidOpcode = NVMeStatus(sct: 0, sc: 0x01, dnr: true)
    static let invalidField = NVMeStatus(sct: 0, sc: 0x02, dnr: true)
    static let commandSequenceError = NVMeStatus(sct: 0, sc: 0x0C, dnr: true)
    static let dataSGLLengthInvalid = NVMeStatus(sct: 0, sc: 0x0F, dnr: true)
    static let sglDescriptorTypeInvalid = NVMeStatus(sct: 0, sc: 0x11, dnr: true)
    static let sglOffsetInvalid = NVMeStatus(sct: 0, sc: 0x16, dnr: true)
    static let invalidNamespace = NVMeStatus(sct: 0, sc: 0x0B, dnr: true)
    static let lbaOutOfRange = NVMeStatus(sct: 0, sc: 0x80, dnr: true)
    static let connectIncompatibleFormat = NVMeStatus(sct: 1, sc: 0x80, dnr: true)
    static let connectInvalidParameters = NVMeStatus(sct: 1, sc: 0x82, dnr: true)
    static let connectInvalidHost = NVMeStatus(sct: 1, sc: 0x84, dnr: true)
}

/// One NVMe/TCP connection = one queue pair, served to completion.
///
/// Two loops share the actor. A reader takes PDUs off the wire as soon as
/// they arrive, the way a real controller's socket does, and does the
/// accounting that has to happen on arrival: how many commands the host has
/// outstanding against the queue size, and any H2CTermReq. The processor
/// then serves them strictly in order. A single loop that finished each
/// command before reading the next would never see two outstanding, and so
/// could never catch a host that overfills the queue.
actor MockNVMeQueue {
    private let subsystem: MockNVMeSubsystem
    private let config: MockNVMeConfig
    private let disk: RAMDisk
    private let faultBox: FaultBox
    private let transport: any ConnectionTransport
    private var faults: MockTargetFaults { faultBox.value }

    private var serializer = NVMeTCPSerializer()
    private var deframer = NVMeTCPDeframer(maxPDUBytes: 4 << 20)
    private var digests = NVMeTCPDigests()

    private var controllerID: UInt16?
    private var queueID: UInt16 = 0
    private var connected = false
    private var sentPDUs = 0
    private var running = true
    private var corruptedReads = 0

    /// SQSIZE + 1 from the Connect: the queue's entries.
    private var queueEntries: Int?
    /// CIDs submitted and not yet completed, counted on arrival.
    private var outstanding: Set<UInt16> = []

    private struct PendingWrite {
        let slba: UInt64
        let fua: Bool
        var buffer: Data
        let ttag: UInt16
        /// Where the next H2CData must start: data for an R2T is contiguous
        /// from the R2T's offset (nvmet compares DATAO with rbytes_done).
        var nextOffset: Int
        /// End of the range the outstanding R2T solicited.
        var r2tEnd: Int
        /// Bytes accepted; the write completes only when it has them all.
        var received = 0
    }

    private var writes: [UInt16: PendingWrite] = [:]
    private var nextTTag: UInt16 = 1

    init(subsystem: MockNVMeSubsystem, config: MockNVMeConfig, disk: RAMDisk,
         faultBox: FaultBox, transport: any ConnectionTransport) {
        self.subsystem = subsystem
        self.config = config
        self.disk = disk
        self.faultBox = faultBox
        self.transport = transport
    }

    func run() async {
        do {
            try await initializeConnection()
            let (inbound, sink) = AsyncThrowingStream.makeStream(of: RawNVMeTCPPDU.self)
            // Not cancelled when processing stops: after close() it still
            // reads what the host sent last — typically its H2CTermReq — and
            // then ends on EOF.
            Task { await self.readAhead(into: sink) }
            for try await raw in inbound {
                guard running else { break }
                try await handle(raw)
            }
        } catch {
            // Connection torn down by the fault script, the peer, or a
            // violation this side refused.
        }
        running = false
        await transport.close()
        if connected, let controllerID {
            await subsystem.queueClosed(controllerID: controllerID, qid: queueID)
        }
    }

    func stop() async {
        running = false
        await transport.close()
    }

    // MARK: Plumbing

    private func nextPDU() async throws -> RawNVMeTCPPDU? {
        while true {
            if let raw = try deframer.next() { return raw }
            guard let chunk = try await transport.receive() else { return nil }
            deframer.append(chunk)
        }
    }

    private func readAhead(into sink: AsyncThrowingStream<RawNVMeTCPPDU, any Error>.Continuation) async {
        do {
            while let raw = try await nextPDU() {
                if raw.pduType == .h2cTermReq, let term = try? H2CTermReqPDU(raw: raw) {
                    await subsystem.noteH2CTermReq(term.fes)
                } else if raw.pduType == .capsuleCmd, let violation = admit(raw) {
                    // nvmet_tcp_fatal_error: the queue is torn down with no
                    // termination request — there is no FES for either case.
                    await subsystem.noteViolation(violation)
                    running = false
                    await transport.close()
                    sink.finish(throwing: TransportError.closed)
                    return
                }
                sink.yield(raw)
            }
            sink.finish()
        } catch {
            sink.finish(throwing: error)
        }
    }

    /// Arrival accounting for a command capsule; a violation in words, or
    /// nil. Before Connect there is no queue size, and the Connect itself
    /// is not counted.
    private func admit(_ raw: RawNVMeTCPPDU) -> String? {
        guard let entries = queueEntries, raw.psh.count >= SQE.size else { return nil }
        let cid = raw.psh.leU16(2)
        // Two outstanding commands with one CID make every completion for it
        // ambiguous. nvmet does not check; the host it serves then
        // mismatches completions, which is worse than a refusal.
        guard outstanding.insert(cid).inserted else {
            return "QID \(queueID): CID \(cid) submitted while a command with that CID is outstanding"
        }
        Task { [subsystem, queueID, count = outstanding.count] in
            await subsystem.noteOutstanding(qid: queueID, count)
        }
        // More commands than the queue has entries: nvmet-tcp runs out of
        // command slots and kills the queue (nvmet_tcp_fatal_error). The
        // host is told SQSIZE and must never go past it.
        guard outstanding.count <= entries else {
            return "QID \(queueID): \(outstanding.count) commands outstanding on a queue of \(entries) entries"
        }
        return nil
    }

    private func send(_ raw: RawNVMeTCPPDU) async throws {
        if let delay = faults.responseDelay {
            try await Task.sleep(for: delay)
        }
        var bytes = serializer.serialize(raw)
        if faults.corruptHeaderDigestOnce && digests.header && connected {
            bytes.setU8(bytes.u8(9) ^ 0xFF, 9)   // inside the PSH, after the digest was computed
        }
        // I/O queue only: corrupting Identify data on the admin queue would
        // stop the controller coming up at all, which is not the fault this
        // models (bad bytes in read data, on the wire).
        let corruptOnce = config.hostility.corruptFirstReadOnly && corruptedReads == 0
        if (faults.corruptDataInPayload || corruptOnce) && connected && queueID != 0
            && raw.pduType == .c2hData && !raw.data.isEmpty {
            let dataOffset = Int(bytes.u8(3))
            bytes.setU8(bytes.u8(dataOffset) ^ 0x01, dataOffset)
            corruptedReads += 1
        }
        try await transport.send(bytes)
        sentPDUs += 1
        if let limit = faults.dropAfterSentPDUs, connected, sentPDUs >= limit {
            await transport.close()
            throw TransportError.closed
        }
    }

    private func respond(cid: UInt16, status: NVMeStatus = .success, dw0: UInt32 = 0, dw1: UInt32 = 0) async throws {
        outstanding.remove(cid)
        let cqe = CQE(dw0: dw0, dw1: dw1, sqHead: 0, sqID: queueID, commandID: cid, status: status)
        try await send(CapsuleRespPDU(cqe: cqe.encoded).encode())
    }

    /// A fatal transport error the host caused (NVMe/TCP 1.1 §3.5): recorded,
    /// answered with a C2HTermReq carrying the offending header, and the
    /// connection closed. nvmet itself closes without the C2HTermReq (its
    /// code says FIXME); the host ends up in the same place, and the FES
    /// says why.
    private func refuse(_ fes: NVMeTCPFatalErrorStatus, fei: UInt32 = 0, _ raw: RawNVMeTCPPDU,
                        _ violation: String) async throws -> Never {
        await subsystem.noteViolation(violation)
        var header = NVMeTCPHeader(type: raw.type, flags: raw.flags, hlen: UInt8(raw.hlen), pdo: 0, plen: 0).encoded
        header.append(raw.psh)
        try? await send(C2HTermReqPDU(fes: fes, fei: fei, offendingHeader: header.prefix(128)).encode())
        running = false
        throw TransportError.closed
    }

    /// Read data as C2HData PDUs, then the completion — unless SUCCESS on the
    /// last data PDU stood in for it. `overrun` bytes beyond `data` follow
    /// in a PDU of their own, which then carries LAST_PDU instead.
    private func sendReadData(cid: UInt16, data: Data, overrun: Int = 0) async throws {
        let chunk = max(1, config.c2hChunkBytes)
        let hostile = queueID != 0 ? config.hostility : MockNVMeHostility()
        var offset = 0
        var index = 0
        var completed = false
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let last = end == data.count && overrun == 0
            var flagLast = last || (hostile.lastPDUTooEarly && index == 0)
            var success = last && config.emitSuccessFlag
            if hostile.successWithoutLast {
                flagLast = false
                success = true
            }
            if success { outstanding.remove(cid) }
            try await send(C2HDataPDU(cccid: cid,
                                      dataOffset: hostile.c2hDataRepeatsOffsetZero ? 0 : UInt32(offset),
                                      data: Data(data.sub(offset, end - offset)),
                                      last: flagLast, success: success).encode())
            completed = success
            offset = end
            index += 1
        }
        if overrun > 0 {
            if config.emitSuccessFlag { outstanding.remove(cid) }
            try await send(C2HDataPDU(cccid: cid, dataOffset: UInt32(data.count), data: Data(count: overrun),
                                      last: true, success: config.emitSuccessFlag).encode())
            completed = config.emitSuccessFlag
        }
        if !completed { try await respond(cid: cid) }
    }

    // MARK: Connection initialization

    private func initializeConnection() async throws {
        guard let raw = try await nextPDU() else { throw TransportError.closed }
        guard case .icReq(let icreq) = try AnyNVMeTCPPDU.decode(raw) else {
            throw NVMeTCPError.malformed("expected ICReq")
        }
        guard icreq.pfv == 0 else { throw NVMeTCPError.malformed("unsupported PFV") }
        let accepted = config.acceptDigests ? icreq.digests : NVMeTCPDigests()
        try await send(ICRespPDU(pfv: config.hostility.icrespPFV, cpda: config.hostility.icrespCPDA,
                                 digests: accepted, maxH2CData: config.maxH2CData).encode())
        // Digests apply from the first PDU after the IC exchange.
        digests = accepted
        serializer = NVMeTCPSerializer(digests: accepted)
        deframer = NVMeTCPDeframer(digests: accepted, maxPDUBytes: 4 << 20)
    }

    // MARK: Dispatch

    private func handle(_ raw: RawNVMeTCPPDU) async throws {
        switch try AnyNVMeTCPPDU.decode(raw) {
        case .capsuleCmd(let cmd):
            try await handleCommand(cmd)
        case .h2cData(let pdu):
            try await handleH2CData(pdu, raw: raw)
        case .h2cTermReq:
            // Recorded by the reader on arrival.
            throw TransportError.closed
        default:
            throw NVMeTCPError.malformed("unexpected PDU type \(raw.type) from host")
        }
    }

    private func handleCommand(_ cmd: CapsuleCmdPDU) async throws {
        let sqe = try SQE(bytes: cmd.sqe)
        let cid = sqe.commandID
        // nvmet_req_init, for every command: no fused operations, and PSDT
        // must say "SGL" (01b) — fabrics has no PRPs.
        guard sqe.flags & 0x03 == 0, sqe.flags & 0xC0 == 0x40 else {
            await subsystem.noteViolation("opcode 0x\(String(sqe.opcode, radix: 16)): FUSE/PSDT flags 0x\(String(sqe.flags, radix: 16))")
            try await respond(cid: cid, status: .invalidField)
            return
        }
        if sqe.opcode == NVMeOpcode.Admin.fabrics {
            try await handleFabrics(sqe, data: cmd.inCapsuleData)
            return
        }
        // nvmet_parse_connect_cmd: before Connect, nothing else is an opcode.
        guard connected, let controllerID else {
            await subsystem.noteViolation("opcode 0x\(String(sqe.opcode, radix: 16)) before Connect")
            try await respond(cid: cid, status: .invalidOpcode)
            return
        }
        // nvmet_check_ctrl_status: admin and I/O commands need CC.EN = 1 and
        // CSTS.RDY = 1. A discovery controller answers Invalid Opcode instead
        // (nvmet_parse_discovery_cmd).
        guard await subsystem.isReady(controllerID) else {
            await subsystem.noteViolation("QID \(queueID): opcode 0x\(String(sqe.opcode, radix: 16)) while the controller is not ready")
            let discovery = await subsystem.isDiscoveryController(controllerID)
            try await respond(cid: cid, status: discovery ? .invalidOpcode : .commandSequenceError)
            return
        }
        if faults.stallCommands {
            await subsystem.noteStalled(cid)
            return
        }
        if queueID == 0 {
            try await handleAdmin(sqe, controllerID: controllerID)
        } else {
            try await handleIO(sqe, data: cmd.inCapsuleData)
        }
    }

    /// nvmet_tcp_map_data then nvmet_check_transfer_len: the SGL in the SQE
    /// must describe exactly the `expected` bytes the command moves. Data
    /// in the capsule only for a write, and no more than the inline size;
    /// otherwise a Transport SGL Data Block. nil when it does.
    private func dataSGLStatus(_ sqe: SQE, expected: Int, inCapsule: Data, isWrite: Bool) async -> NVMeStatus? {
        let sgl = sqe.sgl
        let what = "QID \(queueID) opcode 0x\(String(sqe.opcode, radix: 16))"
        if sgl.length > 0 {
            if sgl.isInCapsule {
                guard isWrite else {
                    await subsystem.noteViolation("\(what): in-capsule SGL on a command that is not a write")
                    return .invalidField
                }
                guard Int(sgl.length) <= config.inCapsuleDataBytes else {
                    await subsystem.noteViolation("\(what): \(sgl.length) in-capsule bytes, IOCCSZ allows \(config.inCapsuleDataBytes)")
                    return .sglOffsetInvalid
                }
                guard inCapsule.count == Int(sgl.length) else {
                    await subsystem.noteViolation("\(what): SGL says \(sgl.length) in-capsule bytes, the capsule carries \(inCapsule.count)")
                    return .dataSGLLengthInvalid
                }
            } else {
                // nvmet treats any other descriptor as a transport one; the
                // NVMe/TCP binding defines only these two, so anything else
                // is a host bug this model names.
                guard sgl.typeByte == SGLDescriptor.transport(length: 0).typeByte else {
                    await subsystem.noteViolation("\(what): SGL descriptor type 0x\(String(sgl.typeByte, radix: 16))")
                    return .sglDescriptorTypeInvalid
                }
                guard inCapsule.isEmpty else {
                    await subsystem.noteViolation("\(what): in-capsule data under a transport SGL")
                    return .dataSGLLengthInvalid
                }
            }
        } else if !inCapsule.isEmpty {
            await subsystem.noteViolation("\(what): in-capsule data under a null SGL")
            return .dataSGLLengthInvalid
        }
        guard Int(sgl.length) == expected else {
            await subsystem.noteViolation("\(what): SGL length \(sgl.length), the command moves \(expected) bytes")
            return .dataSGLLengthInvalid
        }
        return nil
    }

    // MARK: Fabrics

    private func handleFabrics(_ sqe: SQE, data: Data) async throws {
        let cid = sqe.commandID
        switch sqe.fabricsType {
        case FabricsCommandType.connect:
            // A queue that already has a controller parses Connect as an
            // ordinary fabrics command, which it is not.
            guard !connected else {
                await subsystem.noteViolation("QID \(queueID): a second Connect on one connection")
                try await respond(cid: cid, status: .invalidOpcode)
                return
            }
            guard sqe.sgl.isInCapsule, Int(sqe.sgl.length) == NVMeCommands.connectDataSize,
                  data.count == NVMeCommands.connectDataSize else {
                await subsystem.noteViolation("Connect with \(data.count) data bytes under SGL length \(sqe.sgl.length)")
                try await respond(cid: cid, status: .dataSGLLengthInvalid)
                return
            }
            let recfmt = sqe.bytes.leU16(40)
            let qid = sqe.bytes.leU16(42)
            let sqsize = sqe.bytes.leU16(44)
            let kato = sqe.bytes.leU32(48)
            let requestedController = data.leU16(16)
            let subnqn = asciiField(data, 256, 256)
            let hostnqn = asciiField(data, 512, 256)
            if faults.rejectLoginStatus != nil {
                try await respond(cid: cid, status: .connectInvalidHost)
                throw TransportError.closed
            }
            guard recfmt == 0 else {
                await subsystem.noteViolation("Connect RECFMT \(recfmt)")
                try await respond(cid: cid, status: .connectIncompatibleFormat)
                throw TransportError.closed
            }
            // nvmet_install_queue: SQSIZE is 0's based and never 0, and an
            // I/O queue may not be deeper than CAP.MQES. IATTR 0, IPO 44.
            guard sqsize > 0, qid == 0 || sqsize <= config.maxQueueEntries - 1 else {
                await subsystem.noteViolation("Connect QID \(qid) SQSIZE \(sqsize), MQES \(config.maxQueueEntries - 1)")
                try await respond(cid: cid, status: .connectInvalidParameters, dw0: 44)
                throw TransportError.closed
            }
            let outcome: MockNVMeSubsystem.ConnectOutcome
            if qid == 0 {
                // The dynamic controller model, which is all nvmet has: the
                // admin Connect asks for "any controller" and is told its ID.
                guard requestedController == 0xFFFF else {
                    await subsystem.noteViolation("admin Connect names CNTLID \(requestedController), not 0xFFFF")
                    try await respond(cid: cid, status: .connectInvalidParameters,
                                      dw0: MockNVMeSubsystem.connectDataCNTLID)
                    throw TransportError.closed
                }
                outcome = await subsystem.connectAdmin(hostNQN: hostnqn, subsystemNQN: subnqn, kato: kato)
            } else {
                outcome = await subsystem.connectIO(controllerID: requestedController, qid: qid,
                                                    hostNQN: hostnqn, subsystemNQN: subnqn)
            }
            switch outcome {
            case .invalidHost:
                try await respond(cid: cid, status: .connectInvalidHost)
                throw TransportError.closed
            case .invalidParameter(let attribute):
                await subsystem.noteViolation("Connect QID \(qid) CNTLID \(requestedController) refused (IATTR/IPO 0x\(String(attribute, radix: 16)))")
                try await respond(cid: cid, status: .connectInvalidParameters, dw0: attribute)
                throw TransportError.closed
            case .commandSequenceError:
                await subsystem.noteViolation("Connect QID \(qid) to CNTLID \(requestedController), which already has that queue")
                try await respond(cid: cid, status: .commandSequenceError)
                throw TransportError.closed
            case .accepted(let id):
                controllerID = id
                queueID = qid
                // Before the response goes out: the next command the reader
                // sees is counted against this.
                queueEntries = Int(sqsize) + 1
                // AUTHREQ: bit 17 (ATR) of DW0 says in-band authentication is required.
                let authreq: UInt32 = (config.requireAuth && qid == 0) ? 1 << 17 : 0
                try await respond(cid: cid, dw0: UInt32(id) | authreq)
                // Drop-after-N faults count post-connect PDUs only, like the
                // iSCSI mock counts full-feature-phase PDUs.
                connected = true
                sentPDUs = 0
            }
        case FabricsCommandType.propertyGet, FabricsCommandType.propertySet:
            // Before Connect nothing but Connect is an opcode; on an I/O
            // queue the property commands are not either.
            guard connected, let controllerID, queueID == 0 else {
                await subsystem.noteViolation("QID \(queueID): property command \(connected ? "on an I/O queue" : "before Connect")")
                try await respond(cid: cid, status: .invalidOpcode)
                return
            }
            if let status = await dataSGLStatus(sqe, expected: 0, inCapsule: data, isWrite: false) {
                try await respond(cid: cid, status: status)
                return
            }
            let offset = sqe.bytes.leU32(44)
            if sqe.fabricsType == FabricsCommandType.propertyGet {
                let value: UInt64
                switch offset {
                case NVMeProperty.cap:
                    value = UInt64(config.maxQueueEntries - 1) | UInt64(30) << 24 | 1 << 37
                case NVMeProperty.vs:
                    value = 0x0002_0000
                case NVMeProperty.cc:
                    value = UInt64(await subsystem.controllerConfiguration(controllerID))
                case NVMeProperty.csts:
                    // RDY as the subsystem models it; SHST reports 10b
                    // (complete) once SHN was set.
                    let cc = await subsystem.controllerConfiguration(controllerID)
                    let ready: UInt64 = await subsystem.isReady(controllerID) ? 1 : 0
                    value = ready | (cc & 0xC000 != 0 ? 0x8 : 0)
                default:
                    try await respond(cid: cid, status: .invalidField)
                    return
                }
                try await respond(cid: cid, dw0: UInt32(value & 0xFFFF_FFFF), dw1: UInt32(value >> 32))
            } else {
                guard offset == NVMeProperty.cc, sqe.bytes.u8(40) & 1 == 0 else {
                    try await respond(cid: cid, status: .invalidField)
                    return
                }
                await subsystem.setControllerConfiguration(controllerID, sqe.bytes.leU32(48))
                try await respond(cid: cid)
            }
        default:
            try await respond(cid: cid, status: .invalidOpcode)
        }
    }

    // MARK: Admin

    private func handleAdmin(_ sqe: SQE, controllerID: UInt16) async throws {
        let cid = sqe.commandID
        switch sqe.opcode {
        case NVMeOpcode.Admin.identify:
            if let status = await dataSGLStatus(sqe, expected: 4096, inCapsule: Data(), isWrite: false) {
                try await respond(cid: cid, status: status)
                return
            }
            let cns = sqe.bytes.u8(40)
            switch cns {
            case IdentifyCNS.controller:
                try await sendReadData(cid: cid, data: identifyController(controllerID))
            case IdentifyCNS.namespace:
                guard sqe.nsid == config.nsid, await !subsystem.isDiscoveryController(controllerID) else {
                    try await respond(cid: cid, status: .invalidNamespace)
                    return
                }
                try await sendReadData(cid: cid, data: identifyNamespace())
            case IdentifyCNS.activeNamespaces:
                var list = Data(count: 4096)
                if config.nsid > sqe.nsid { list.setLE32(config.nsid, 0) }
                try await sendReadData(cid: cid, data: list)
            default:
                try await respond(cid: cid, status: .invalidField)
            }
        case NVMeOpcode.Admin.setFeatures:
            if let status = await dataSGLStatus(sqe, expected: 0, inCapsule: Data(), isWrite: false) {
                try await respond(cid: cid, status: status)
                return
            }
            // Number of Queues answers with the allocation (0's based): one each.
            try await respond(cid: cid, dw0: 0)
        case NVMeOpcode.Admin.keepAlive:
            if faults.swallowNops { return }
            if let status = await dataSGLStatus(sqe, expected: 0, inCapsule: Data(), isWrite: false) {
                try await respond(cid: cid, status: status)
                return
            }
            await subsystem.noteKeepAlive()
            try await respond(cid: cid)
        case NVMeOpcode.Admin.getLogPage:
            let lid = sqe.bytes.u8(40)
            guard lid == NVMeLogPage.discovery else {
                try await respond(cid: cid, status: .invalidField)
                return
            }
            let numd = UInt32(sqe.bytes.leU16(42)) | UInt32(sqe.bytes.leU16(44)) << 16
            let length = Int(numd + 1) * 4
            if let status = await dataSGLStatus(sqe, expected: length, inCapsule: Data(), isWrite: false) {
                try await respond(cid: cid, status: status)
                return
            }
            let offset = Int(sqe.bytes.leU64(48))
            let page = discoveryLogPage()
            var slice = Data(count: length)
            if offset < page.count {
                let n = min(length, page.count - offset)
                slice.setSub(page.sub(offset, n), 0)
            }
            try await sendReadData(cid: cid, data: slice)
        default:
            try await respond(cid: cid, status: .invalidOpcode)
        }
    }

    private func identifyController(_ id: UInt16) -> Data {
        var d = Data(count: 4096)
        d.setSub(Data(config.serial.utf8.prefix(20)), 4)
        d.setSub(Data(config.model.utf8.prefix(40)), 24)
        d.setSub(Data(config.firmware.utf8.prefix(8)), 64)
        d.setU8(config.mdts, 77)
        d.setLE16(id, 78)
        d.setLE16(100, 320)                                  // KAS: 10 s granularity
        d.setU8(0x66, 512)                                   // SQES 64 B
        d.setU8(0x44, 513)                                   // CQES 16 B
        d.setLE16(config.maxOutstandingCommands == 0 ? config.maxQueueEntries
                  : config.maxOutstandingCommands, 514)      // MAXCMD
        d.setLE32(1, 516)                                    // NN
        d.setU8(1, 525)                                      // VWC present
        d.setLE32(0x0010_0005, 536)                          // SGLS
        d.setSub(Data(config.subsystemNQN.utf8.prefix(255)), 768)
        d.setLE32(UInt32((config.inCapsuleDataBytes + SQE.size) / 16), 1792)   // IOCCSZ
        d.setLE32(1, 1796)                                   // IORCSZ
        d.setLE16(0, 1800)                                   // ICDOFF
        return d
    }

    private func identifyNamespace() -> Data {
        var d = Data(count: 4096)
        d.setLE64(disk.capacityBlocks, 0)
        d.setLE64(disk.capacityBlocks, 8)
        d.setLE64(disk.capacityBlocks, 16)
        d.setU8(0, 25)                                       // one LBA format
        d.setU8(0, 26)
        d.setU8(UInt8(disk.blockSize.trailingZeroBitCount), 130)   // LBADS
        return d
    }

    private func discoveryLogPage() -> Data {
        var page = Data(count: DiscoveryLogPage.headerSize)
        page.setLE64(1, 0)
        page.setLE64(UInt64(config.discoveryEntries.count), 8)
        for entry in config.discoveryEntries {
            var e = Data(count: DiscoveryLogEntry.size)
            e.setU8(DiscoveryLogEntry.transportTCP, 0)
            e.setU8(1, 1)
            e.setU8(DiscoveryLogEntry.subtypeNVM, 2)
            if config.tlsRequiredSubsystems.contains(entry.subnqn) {
                e.setU8(0x01, 3)                             // TREQ: secure channel required
                e.setU8(0x02, 768)                           // TSAS SECTYPE: TLS 1.3
            }
            e.setLE16(1, 4)
            e.setLE16(0xFFFF, 6)
            e.setLE16(config.maxQueueEntries, 8)
            e.setSub(Data(entry.trsvcid.utf8.prefix(31)), 32)
            e.setSub(Data(entry.subnqn.utf8.prefix(255)), 256)
            e.setSub(Data(entry.traddr.utf8.prefix(255)), 512)
            page.append(e)
        }
        return page
    }

    // MARK: NVM I/O

    private var ioCommandsSeen = 0

    private func handleIO(_ sqe: SQE, data inCapsule: Data) async throws {
        let cid = sqe.commandID
        ioCommandsSeen += 1
        if config.hostility.terminateOnFirstIOCommand && ioCommandsSeen == 1 {
            try await send(C2HTermReqPDU(fes: .pduSequenceError, fei: 0,
                                         offendingHeader: Data([4, 0, 72, 0, 72, 0, 0, 0])).encode())
            throw TransportError.closed
        }
        if config.hostility.completeUnknownCID {
            try await respond(cid: 0xFFFE)
        }
        if faults.checkConditionAll {
            try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x06))   // internal error
            return
        }
        guard sqe.nsid == config.nsid else {
            try await respond(cid: cid, status: .invalidNamespace)
            return
        }
        let blocks = Int(sqe.bytes.leU16(48)) + 1
        switch sqe.opcode {
        case NVMeOpcode.NVM.flush:
            if let status = await dataSGLStatus(sqe, expected: 0, inCapsule: inCapsule, isWrite: false) {
                try await respond(cid: cid, status: status)
                return
            }
            await disk.flush()
            try await respond(cid: cid)
        case NVMeOpcode.NVM.read:
            let slba = sqe.bytes.leU64(40)
            if let status = await dataSGLStatus(sqe, expected: blocks * disk.blockSize,
                                                inCapsule: inCapsule, isWrite: false) {
                try await respond(cid: cid, status: status)
                return
            }
            guard let payload = await disk.read(lba: slba, blocks: UInt32(blocks)) else {
                try await respond(cid: cid, status: .lbaOutOfRange)
                return
            }
            try await sendReadData(cid: cid, data: payload, overrun: config.hostility.c2hDataOverrun ? 512 : 0)
        case NVMeOpcode.NVM.write:
            let slba = sqe.bytes.leU64(40)
            let fua = sqe.bytes.leU16(50) & 0x4000 != 0
            let total = blocks * disk.blockSize
            if let status = await dataSGLStatus(sqe, expected: total, inCapsule: inCapsule, isWrite: true) {
                try await respond(cid: cid, status: status)
                return
            }
            guard slba + UInt64(blocks) <= disk.capacityBlocks else {
                try await respond(cid: cid, status: .lbaOutOfRange)
                return
            }
            if sqe.sgl.isInCapsule {
                await subsystem.noteInCapsuleWrite()
                await disk.write(lba: slba, data: inCapsule, fua: fua)
                try await respond(cid: cid)
                return
            }
            let ttag = nextTTag
            nextTTag &+= 1
            let skip = config.hostility.r2tSkipsFirstBlock ? disk.blockSize : 0
            let length = config.hostility.r2tOverrun ? total + disk.blockSize : r2tLength(from: skip, of: total)
            writes[cid] = PendingWrite(slba: slba, fua: fua, buffer: Data(count: total), ttag: ttag,
                                       nextOffset: skip, r2tEnd: skip + length)
            try await sendR2T(cid: cid, ttag: ttag, offset: skip, length: length)
        default:
            try await respond(cid: cid, status: .invalidOpcode)
        }
    }

    /// What the next R2T asks for: the rest of the write.
    private func r2tLength(from offset: Int, of total: Int) -> Int {
        total - offset
    }

    private func sendR2T(cid: UInt16, ttag: UInt16, offset: Int, length: Int) async throws {
        await subsystem.noteR2T()
        try await send(NVMeR2TPDU(cccid: cid, ttag: ttag, offset: UInt32(offset), length: UInt32(length)).encode())
    }

    /// nvmet_tcp_handle_h2c_data_pdu, and the parts of NVMe/TCP 1.1 §3.3.2.2
    /// it leaves unchecked: data for the outstanding R2T only, contiguous
    /// from its offset, never past it, no PDU empty or larger than
    /// MAXH2CDATA, and LAST_PDU on the PDU that completes the R2T and on no
    /// other. Any of these is a fatal transport error.
    private func handleH2CData(_ pdu: H2CDataPDU, raw: RawNVMeTCPPDU) async throws {
        let cid = pdu.cccid
        guard var state = writes[cid] else {
            try await refuse(.invalidPDUHeader, fei: 8, raw, "H2CData for CID \(cid), which has no R2T outstanding")
        }
        guard state.ttag == pdu.ttag else {
            try await refuse(.invalidPDUHeader, fei: 10, raw,
                             "H2CData for CID \(cid) with TTAG \(pdu.ttag), the R2T said \(state.ttag)")
        }
        if faults.stallAfterR2T { return }
        await subsystem.noteH2CData()
        let offset = Int(pdu.dataOffset)
        let count = pdu.data.count
        guard count > 0 else {
            try await refuse(.invalidPDUHeader, fei: 16, raw, "empty H2CData for CID \(cid)")
        }
        guard count <= Int(config.maxH2CData) else {
            try await refuse(.dataTransferLimitExceeded, raw,
                             "H2CData of \(count) bytes for CID \(cid), MAXH2CDATA is \(config.maxH2CData)")
        }
        guard offset == state.nextOffset else {
            try await refuse(.pduSequenceError, fei: 12, raw,
                             "non-contiguous H2CData for CID \(cid): DATAO \(offset), expected \(state.nextOffset)")
        }
        guard offset + count <= state.r2tEnd, offset + count <= state.buffer.count else {
            try await refuse(.dataTransferOutOfRange, raw,
                             "H2CData for CID \(cid) runs to \(offset + count), past the R2T's \(state.r2tEnd)")
        }
        state.buffer.setSub(pdu.data, offset)
        state.nextOffset = offset + count
        state.received += count
        let r2tDone = state.nextOffset == state.r2tEnd
        // nvmet ignores LAST_PDU; the spec defines it, and so does every
        // controller that pipelines R2Ts.
        guard pdu.last == r2tDone else {
            try await refuse(.pduSequenceError, fei: 1, raw, pdu.last
                ? "H2CData for CID \(cid) has LAST_PDU at \(state.nextOffset), before the R2T's end \(state.r2tEnd)"
                : "H2CData for CID \(cid) completes its R2T without LAST_PDU")
        }
        writes[cid] = state
        guard r2tDone else { return }
        if state.nextOffset < state.buffer.count {
            let length = r2tLength(from: state.nextOffset, of: state.buffer.count)
            state.r2tEnd = state.nextOffset + length
            writes[cid] = state
            try await sendR2T(cid: cid, ttag: state.ttag, offset: state.nextOffset, length: length)
            return
        }
        writes.removeValue(forKey: cid)
        guard state.received == state.buffer.count else {
            try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x04, dnr: true))   // data transfer error
            return
        }
        await disk.write(lba: state.slba, data: state.buffer, fua: state.fua)
        try await respond(cid: cid)
    }
}
