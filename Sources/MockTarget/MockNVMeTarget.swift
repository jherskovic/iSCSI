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
    /// Entries for the discovery log page served to the discovery NQN.
    public var discoveryEntries: [(subnqn: String, traddr: String, trsvcid: String)] = []
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
    /// Send one C2HData past the end of the read buffer.
    public var c2hDataOverrun = false
    /// Ask, by R2T, for more bytes than the write carries.
    public var r2tOverrun = false

    public init() {}
}

/// In-process NVMe/TCP subsystem. One instance serves any number of
/// connections, because a controller is two of them (admin queue and I/O
/// queue) and the I/O Connect must name the CNTLID the admin Connect
/// returned — so the controller registry lives here, and each connection is
/// a `MockNVMeQueue`. The `RAMDisk` is shared for the same reason
/// `MockTarget` shares it: state must survive a simulated reboot.
public actor MockNVMeSubsystem {
    public let config: MockNVMeConfig
    public let disk: RAMDisk
    /// The shared fault script for the simulator; tests hand each connection
    /// its own box via `serve(_:faultBox:)`.
    public let faultBox: FaultBox

    struct ControllerState {
        let id: UInt16
        let hostNQN: String
        let isDiscovery: Bool
        var cc: UInt32 = 0
        let kato: UInt32
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
        case invalidParameter
    }

    func connectAdmin(hostNQN: String, subsystemNQN: String, kato: UInt32) -> ConnectOutcome {
        let isDiscovery = subsystemNQN == NQN.discovery
        guard isDiscovery || subsystemNQN == config.subsystemNQN else { return .invalidParameter }
        if let allowed = config.allowedHosts, !allowed.contains(hostNQN) { return .invalidHost }
        let id = nextControllerID
        nextControllerID &+= 1
        controllers[id] = ControllerState(id: id, hostNQN: hostNQN, isDiscovery: isDiscovery, kato: kato)
        return .accepted(id)
    }

    func connectIO(controllerID: UInt16, hostNQN: String) -> ConnectOutcome {
        guard let state = controllers[controllerID], state.hostNQN == hostNQN, !state.isDiscovery else {
            return .invalidParameter
        }
        return .accepted(controllerID)
    }

    func controllerConfiguration(_ id: UInt16) -> UInt32 { controllers[id]?.cc ?? 0 }

    func setControllerConfiguration(_ id: UInt16, _ cc: UInt32) { controllers[id]?.cc = cc }

    func isDiscoveryController(_ id: UInt16) -> Bool { controllers[id]?.isDiscovery ?? false }

    // MARK: Counters

    func noteKeepAlive() { keepAlivesReceived += 1 }
    func noteR2T() { r2tsSent += 1 }
    func noteH2CData() { h2cDataPDUsReceived += 1 }
    func noteInCapsuleWrite() { inCapsuleWrites += 1 }
    func noteStalled(_ cid: UInt16) { stalledCIDs.append(cid) }
}

/// One NVMe/TCP connection = one queue pair, served to completion.
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

    private struct PendingWrite {
        let nsid: UInt32
        let slba: UInt64
        let fua: Bool
        var buffer: Data
        var received = 0
        let ttag: UInt16
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
            while running {
                guard let raw = try await nextPDU() else { break }
                try await handle(raw)
            }
        } catch {
            // Connection torn down by the fault script or the peer.
        }
        await transport.close()
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
        if faults.corruptDataInPayload && connected && queueID != 0
            && raw.pduType == .c2hData && !raw.data.isEmpty {
            let dataOffset = Int(bytes.u8(3))
            bytes.setU8(bytes.u8(dataOffset) ^ 0x01, dataOffset)
        }
        try await transport.send(bytes)
        sentPDUs += 1
        if let limit = faults.dropAfterSentPDUs, connected, sentPDUs >= limit {
            await transport.close()
            throw TransportError.closed
        }
    }

    private func respond(cid: UInt16, status: NVMeStatus = .success, dw0: UInt32 = 0, dw1: UInt32 = 0) async throws {
        let cqe = CQE(dw0: dw0, dw1: dw1, sqHead: 0, sqID: queueID, commandID: cid, status: status)
        try await send(CapsuleRespPDU(cqe: cqe.encoded).encode())
    }

    /// Read data as C2HData PDUs, then the completion — unless SUCCESS on the
    /// last data PDU stood in for it.
    private func sendReadData(cid: UInt16, data: Data) async throws {
        let chunk = max(1, config.c2hChunkBytes)
        var offset = 0
        var completed = false
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let last = end == data.count
            let success = last && config.emitSuccessFlag
            try await send(C2HDataPDU(cccid: cid, dataOffset: UInt32(offset),
                                      data: Data(data.sub(offset, end - offset)),
                                      last: last, success: success).encode())
            completed = success
            offset = end
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
            try await handleH2CData(pdu)
        case .h2cTermReq:
            throw TransportError.closed
        default:
            throw NVMeTCPError.malformed("unexpected PDU type \(raw.type) from host")
        }
    }

    private func handleCommand(_ cmd: CapsuleCmdPDU) async throws {
        let sqe = try SQE(bytes: cmd.sqe)
        let cid = sqe.commandID
        if sqe.opcode == NVMeOpcode.Admin.fabrics {
            try await handleFabrics(sqe, data: cmd.inCapsuleData)
            return
        }
        guard connected, let controllerID else {
            try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x01, dnr: true))   // invalid opcode
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

    // MARK: Fabrics

    private func handleFabrics(_ sqe: SQE, data: Data) async throws {
        let cid = sqe.commandID
        switch sqe.fabricsType {
        case FabricsCommandType.connect:
            guard data.count == NVMeCommands.connectDataSize else {
                try await respond(cid: cid, status: NVMeStatus(sct: 1, sc: 0x82, dnr: true))
                return
            }
            let qid = sqe.bytes.leU16(42)
            let kato = sqe.bytes.leU32(48)
            let requestedController = data.leU16(16)
            let subnqn = asciiField(data, 256, 256)
            let hostnqn = asciiField(data, 512, 256)
            if faults.rejectLoginStatus != nil {
                try await respond(cid: cid, status: NVMeStatus(sct: 1, sc: 0x84, dnr: true))
                throw TransportError.closed
            }
            let outcome: MockNVMeSubsystem.ConnectOutcome
            if qid == 0 {
                outcome = await subsystem.connectAdmin(hostNQN: hostnqn, subsystemNQN: subnqn, kato: kato)
            } else {
                outcome = await subsystem.connectIO(controllerID: requestedController, hostNQN: hostnqn)
            }
            switch outcome {
            case .invalidHost:
                try await respond(cid: cid, status: NVMeStatus(sct: 1, sc: 0x84, dnr: true))
                throw TransportError.closed
            case .invalidParameter:
                try await respond(cid: cid, status: NVMeStatus(sct: 1, sc: 0x82, dnr: true))
                throw TransportError.closed
            case .accepted(let id):
                controllerID = id
                queueID = qid
                // AUTHREQ: bit 17 (ATR) of DW0 says in-band authentication is required.
                let authreq: UInt32 = (config.requireAuth && qid == 0) ? 1 << 17 : 0
                try await respond(cid: cid, dw0: UInt32(id) | authreq)
                // Drop-after-N faults count post-connect PDUs only, like the
                // iSCSI mock counts full-feature-phase PDUs.
                connected = true
                sentPDUs = 0
            }
        case FabricsCommandType.propertyGet:
            guard let controllerID else { throw TransportError.closed }
            let offset = sqe.bytes.leU32(44)
            let value: UInt64
            switch offset {
            case NVMeProperty.cap:
                value = UInt64(config.maxQueueEntries - 1) | UInt64(30) << 24 | 1 << 37
            case NVMeProperty.vs:
                value = 0x0002_0000
            case NVMeProperty.cc:
                value = UInt64(await subsystem.controllerConfiguration(controllerID))
            case NVMeProperty.csts:
                value = UInt64(await subsystem.controllerConfiguration(controllerID) & 1)
            default:
                try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x02, dnr: true))
                return
            }
            try await respond(cid: cid, dw0: UInt32(value & 0xFFFF_FFFF), dw1: UInt32(value >> 32))
        case FabricsCommandType.propertySet:
            guard let controllerID else { throw TransportError.closed }
            let offset = sqe.bytes.leU32(44)
            guard offset == NVMeProperty.cc, sqe.bytes.u8(40) & 1 == 0 else {
                try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x02, dnr: true))
                return
            }
            await subsystem.setControllerConfiguration(controllerID, sqe.bytes.leU32(48))
            try await respond(cid: cid)
        default:
            try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x01, dnr: true))
        }
    }

    // MARK: Admin

    private func handleAdmin(_ sqe: SQE, controllerID: UInt16) async throws {
        let cid = sqe.commandID
        let wanted = Int(sqe.sgl.length)
        switch sqe.opcode {
        case NVMeOpcode.Admin.identify:
            let cns = sqe.bytes.u8(40)
            switch cns {
            case IdentifyCNS.controller:
                try await sendReadData(cid: cid, data: identifyController(controllerID).prefix(wanted))
            case IdentifyCNS.namespace:
                guard sqe.nsid == config.nsid, await !subsystem.isDiscoveryController(controllerID) else {
                    try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x0B, dnr: true))
                    return
                }
                try await sendReadData(cid: cid, data: identifyNamespace().prefix(wanted))
            case IdentifyCNS.activeNamespaces:
                var list = Data(count: 4096)
                if config.nsid > sqe.nsid { list.setLE32(config.nsid, 0) }
                try await sendReadData(cid: cid, data: list.prefix(wanted))
            default:
                try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x02, dnr: true))
            }
        case NVMeOpcode.Admin.setFeatures:
            // Number of Queues answers with the allocation (0's based): one each.
            try await respond(cid: cid, dw0: 0)
        case NVMeOpcode.Admin.keepAlive:
            if faults.swallowNops { return }
            await subsystem.noteKeepAlive()
            try await respond(cid: cid)
        case NVMeOpcode.Admin.getLogPage:
            let lid = sqe.bytes.u8(40)
            guard lid == NVMeLogPage.discovery else {
                try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x02, dnr: true))
                return
            }
            let numd = UInt32(sqe.bytes.leU16(42)) | UInt32(sqe.bytes.leU16(44)) << 16
            let length = Int(numd + 1) * 4
            let offset = Int(sqe.bytes.leU64(48))
            let page = discoveryLogPage()
            var slice = Data(count: length)
            if offset < page.count {
                let n = min(length, page.count - offset)
                slice.setSub(page.sub(offset, n), 0)
            }
            try await sendReadData(cid: cid, data: slice)
        default:
            try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x01, dnr: true))
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
        d.setLE16(config.maxQueueEntries, 514)               // MAXCMD
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
            try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x0B, dnr: true))
            return
        }
        switch sqe.opcode {
        case NVMeOpcode.NVM.flush:
            await disk.flush()
            try await respond(cid: cid)
        case NVMeOpcode.NVM.read:
            let slba = sqe.bytes.leU64(40)
            let blocks = UInt32(sqe.bytes.leU16(48)) + 1
            guard let payload = await disk.read(lba: slba, blocks: blocks) else {
                try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x80, dnr: true))   // LBA out of range
                return
            }
            if config.hostility.c2hDataOverrun {
                try await send(C2HDataPDU(cccid: cid, dataOffset: UInt32(payload.count),
                                          data: Data(count: 512), last: false, success: false).encode())
            }
            try await sendReadData(cid: cid, data: payload)
        case NVMeOpcode.NVM.write:
            let slba = sqe.bytes.leU64(40)
            let blocks = Int(sqe.bytes.leU16(48)) + 1
            let fua = sqe.bytes.leU16(50) & 0x4000 != 0
            let total = blocks * disk.blockSize
            guard slba + UInt64(blocks) <= disk.capacityBlocks else {
                try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x80, dnr: true))
                return
            }
            if !inCapsule.isEmpty {
                guard sqe.sgl.isInCapsule, inCapsule.count == total,
                      inCapsule.count <= config.inCapsuleDataBytes else {
                    try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x02, dnr: true))
                    return
                }
                await subsystem.noteInCapsuleWrite()
                await disk.write(lba: slba, data: inCapsule, fua: fua)
                try await respond(cid: cid)
                return
            }
            let ttag = nextTTag
            nextTTag &+= 1
            writes[cid] = PendingWrite(nsid: sqe.nsid, slba: slba, fua: fua,
                                       buffer: Data(count: total), ttag: ttag)
            await subsystem.noteR2T()
            let solicited = config.hostility.r2tOverrun ? total + disk.blockSize : total
            try await send(NVMeR2TPDU(cccid: cid, ttag: ttag, offset: 0, length: UInt32(solicited)).encode())
        default:
            try await respond(cid: cid, status: NVMeStatus(sct: 0, sc: 0x01, dnr: true))
        }
    }

    private func handleH2CData(_ pdu: H2CDataPDU) async throws {
        guard var state = writes[pdu.cccid], state.ttag == pdu.ttag else {
            throw NVMeTCPError.malformed("H2CData for unknown command/TTAG")
        }
        if faults.stallAfterR2T { return }
        await subsystem.noteH2CData()
        let offset = Int(pdu.dataOffset)
        guard offset + pdu.data.count <= state.buffer.count else {
            throw NVMeTCPError.malformed("H2CData past the write buffer")
        }
        state.buffer.setSub(pdu.data, offset)
        state.received += pdu.data.count
        writes[pdu.cccid] = state
        if pdu.last {
            writes.removeValue(forKey: pdu.cccid)
            guard state.received == state.buffer.count else {
                try await respond(cid: pdu.cccid, status: NVMeStatus(sct: 0, sc: 0x04, dnr: true))   // data transfer error
                return
            }
            await disk.write(lba: state.slba, data: state.buffer, fua: state.fua)
            try await respond(cid: pdu.cccid)
        }
    }
}
