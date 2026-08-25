import Foundation
import iSCSIKit

/// Scripted misbehavior. Every fault is off by default; tests switch on the
/// hostility they want to probe.
public struct MockTargetFaults: Sendable {
    /// Fail login with this status class/detail.
    public var rejectLoginStatus: (class: UInt8, detail: UInt8)?
    /// Answer login with a redirect (status class 1) to this address.
    public var redirectTo: String?
    /// Hard-drop the connection after N PDUs sent (post-login).
    public var dropAfterSentPDUs: Int?
    /// Drop mid-read after N Data-In PDUs of a burst.
    public var dropDuringDataInAt: Int?
    /// Flip a byte in the data segment of Data-In PDUs (digest must catch it
    /// when DataDigest=CRC32C, otherwise it silently corrupts).
    public var corruptDataInPayload = false
    /// Flip a byte inside the BHS after the header digest is computed.
    public var corruptHeaderDigestOnce = false
    /// Skip this many StatSN values after login (lost-status simulation).
    public var statSNJump: UInt32 = 0
    /// Repeat the previous StatSN on the next status PDU.
    public var duplicateStatSN = false
    /// Send an R2T for a *read* task (protocol violation).
    public var unsolicitedR2T = false
    /// Ignore the initiator's declared MaxRecvDataSegmentLength on Data-In.
    public var oversizeDataIn = false
    /// Issue the R2T for writes, then never accept the data / respond.
    public var stallAfterR2T = false
    /// Accept commands and never respond at all.
    public var stallCommands = false
    /// Respond to every command with a Reject PDU.
    public var rejectAllCommands = false
    /// Respond to every command with CHECK CONDITION.
    public var checkConditionAll = false
    /// Delay before each response PDU.
    public var responseDelay: Duration?
    /// Send a target-initiated NOP-In ping right after login.
    public var nopPingOnConnect = false
    /// Ignore initiator NOP-Out pings (dead-peer simulation while the TCP
    /// connection stays up).
    public var swallowNops = false
    /// Ignore task management requests. A target this sick is the reason an
    /// abort cannot be a precondition for giving up on a task.
    public var swallowTMF = false
    /// Freeze MaxCmdSN at login value (command window never reopens).
    public var freezeWindow = false
    /// Split text responses into C-bit continuations of this size.
    public var splitTextResponsesAt: Int?

    public init() {}
}

public struct MockTargetConfig: Sendable {
    public var targetName = "iqn.2026-08.test.example:disk0"
    /// CHAP account the initiator must present when `requireChap`.
    public var chapUser: String?
    public var chapSecret: String?
    /// Secret this target uses to answer mutual CHAP.
    public var mutualSecret: String?
    public var mutualName = "mock-target"
    public var requireChap = false
    /// Our declared MaxRecvDataSegmentLength (caps initiator Data-Out size).
    public var maxRecvDataSegmentLength: UInt32 = 8192
    /// Negotiation preferences.
    public var preferInitialR2T = false
    public var preferImmediateData = true
    public var maxBurstLength: UInt32 = 262_144
    public var firstBurstLength: UInt32 = 65536
    /// Digest pick when the initiator offers a list (nil = prefer None).
    public var digestPick: String?
    /// Command window size (MaxCmdSN - ExpCmdSN + 1).
    public var commandWindow: UInt32 = 32
    public var tsih: UInt16 = 0x0BAD
    /// Targets advertised by SendTargets.
    public var discoveryTargets: [(name: String, addresses: [String])] = []
    public var faults = MockTargetFaults()

    public init() {}
}

/// In-process iSCSI target serving one connection over a `ConnectionTransport`.
/// Spawn a fresh instance per connection; share the `RAMDisk` to survive
/// simulated reboots.
public actor MockTarget {
    public let config: MockTargetConfig
    let disk: RAMDisk
    let transport: any ConnectionTransport

    private var serializer = PDUSerializer()
    private var deframer = PDUDeframer()

    // Connection state
    private var statSN: UInt32 = 0x1000
    private var expCmdSN: UInt32 = 0
    private var initiatorMRDSL: UInt32 = 8192
    private var negotiated = OperationalParameters()
    private var sentPDUs = 0
    private var loggedIn = false
    private var running = true

    /// Writes in flight: ITT → state.
    private struct WriteState {
        var lun: UInt64
        var lba: UInt64
        var total: Int
        var buffer: Data
        var received: Int
        var awaitingUnsolicited: Bool
        var currentTTT: UInt32?
        /// Next R2TSN for this task — sequential per RFC 7143 §11.8.3.
        var nextR2TSN: UInt32 = 0
        /// FUA from the command's CDB: decides whether the data is committed
        /// or merely cached when the write completes.
        var fua: Bool
    }

    private var writes: [UInt32: WriteState] = [:]
    private var nextTTT: UInt32 = 0x100
    /// NOP-Out echoes received for our target-initiated pings.
    public private(set) var pingEchoes: [Data] = []
    /// Commands swallowed by stallCommands (for TMF assertions).
    public private(set) var stalledITTs: [UInt32] = []

    /// Live fault script. Tests that set faults once at init get a private box
    /// holding `config.faults`; the simulator passes a shared one so faults can
    /// be flipped mid-run.
    private let faultBox: FaultBox
    private var faults: MockTargetFaults { faultBox.value }

    public init(
        config: MockTargetConfig = MockTargetConfig(),
        disk: RAMDisk? = nil,
        faultBox: FaultBox? = nil,
        transport: any ConnectionTransport
    ) {
        self.config = config
        self.disk = disk ?? RAMDisk()
        self.faultBox = faultBox ?? FaultBox(config.faults)
        self.transport = transport
    }

    /// Serve until the connection closes. Run as `Task { await target.run() }`.
    public func run() async {
        do {
            try await loginPhase()
            guard loggedIn else { return }
            if faults.nopPingOnConnect {
                try await sendTargetPing()
            }
            try await fullFeaturePhase()
        } catch {
            // Connection torn down (by fault script or peer) — fine.
        }
        await transport.close()
    }

    public func stop() async {
        running = false
        await transport.close()
    }

    // MARK: - PDU plumbing

    private func nextPDU() async throws -> AnyPDU? {
        while true {
            if let raw = try deframer.next() {
                return try AnyPDU.decode(raw)
            }
            guard let chunk = try await transport.receive() else { return nil }
            deframer.append(chunk)
        }
    }

    private func send(_ pdu: some ProtocolDataUnit) async throws {
        if let delay = faults.responseDelay {
            try await Task.sleep(for: delay)
        }
        var bytes = serializer.serialize(pdu)
        if faults.corruptHeaderDigestOnce && negotiated.headerDigest && loggedIn {
            bytes.setU8(bytes.u8(20) ^ 0xFF, 20) // corrupt ITT after digest computed
        }
        if faults.corruptDataInPayload && loggedIn && pdu is DataInPDU {
            // Flip a payload byte *after* serialization so any negotiated
            // digest no longer matches — simulating on-the-wire corruption.
            let dataOffset = 48 + (negotiated.headerDigest ? 4 : 0)
            if bytes.count > dataOffset {
                bytes.setU8(bytes.u8(dataOffset) ^ 0x01, dataOffset)
            }
        }
        try await transport.send(bytes)
        sentPDUs += 1
        if let limit = faults.dropAfterSentPDUs, loggedIn, sentPDUs >= limit {
            await transport.close()
            throw TransportError.closed
        }
    }

    private func takeStatSN() -> UInt32 {
        if faults.duplicateStatSN && loggedIn {
            return statSN &- 1
        }
        defer { statSN &+= 1 }
        return statSN
    }

    private func window() -> (expCmdSN: UInt32, maxCmdSN: UInt32) {
        if faults.freezeWindow {
            return (expCmdSN, expCmdSN &- 1) // permanently closed window
        }
        return (expCmdSN, expCmdSN &+ config.commandWindow &- 1)
    }

    private func noteCmdSN(_ sn: UInt32, immediate: Bool) {
        if !immediate && sn == expCmdSN {
            expCmdSN &+= 1
        } else if !immediate && Serial.lt(expCmdSN, sn) {
            expCmdSN = sn &+ 1
        }
    }

    // MARK: - Login phase

    private func loginPhase() async throws {
        var securityDone = !config.requireChap
        var chapState = 0 // 0: awaiting CHAP_A, 1: awaiting response
        // Per connection, from the system CSPRNG. These were compile-time
        // constants — `0x2A` and `00 07 0e 15 …` — identical on every run, which
        // makes a captured CHAP_R replay forever. Harmless while this is only a
        // unit-test fixture, but `iscsi-target-sim` wraps it as a real
        // executable that binds a port and accepts `--require-chap`, so anyone
        // pointing it at a non-loopback interface had a target whose challenge
        // never changed.
        //
        // Fixed challenges also make the tests weaker in a subtle way: they
        // cannot catch an initiator that caches or precomputes a response.
        let chapID = UInt8.random(in: 0 ... 255)
        let chapChallenge = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })

        while running {
            guard let pdu = try await nextPDU() else { throw TransportError.closed }
            guard case .loginRequest(let request) = pdu else {
                throw PDUError.malformed("expected login request")
            }
            expCmdSN = request.cmdSN
            let text = try TextParameters.decode(request.dataSegment)

            if let status = faults.rejectLoginStatus {
                try await sendLoginResponse(
                    to: request, text: TextParameters(),
                    transit: false, statusClass: status.class, statusDetail: status.detail
                )
                throw TransportError.closed
            }
            if let address = faults.redirectTo {
                var reply = TextParameters()
                reply.append("TargetAddress", address)
                try await sendLoginResponse(
                    to: request, text: reply,
                    transit: false, statusClass: 1, statusDetail: 2
                )
                throw TransportError.closed
            }

            // Validate target name on the leading PDU of normal sessions.
            if let requestedTarget = text["TargetName"], text["SessionType"] != "Discovery" {
                guard requestedTarget == config.targetName else {
                    try await sendLoginResponse(
                        to: request, text: TextParameters(),
                        transit: false, statusClass: 2, statusDetail: 3 // target not found
                    )
                    throw TransportError.closed
                }
            }

            switch request.currentStage {
            case .securityNegotiation:
                if let method = text["AuthMethod"] {
                    if config.requireChap {
                        guard method.split(separator: ",").contains("CHAP") else {
                            try await sendLoginResponse(
                                to: request, text: TextParameters(),
                                transit: false, statusClass: 2, statusDetail: 1
                            )
                            throw TransportError.closed
                        }
                        var reply = TextParameters()
                        reply.append("AuthMethod", "CHAP")
                        try await sendLoginResponse(to: request, text: reply, transit: false)
                        continue
                    } else {
                        var reply = TextParameters()
                        reply.append("AuthMethod", "None")
                        reply.append("TargetPortalGroupTag", "1")
                        securityDone = true
                        try await sendLoginResponse(
                            to: request, text: reply,
                            transit: request.transit,
                            nsg: request.nextStage
                        )
                        continue
                    }
                }
                if config.requireChap && chapState == 0 && text["CHAP_A"] != nil {
                    guard text["CHAP_A"]!.split(separator: ",").contains("5") else {
                        try await sendLoginResponse(
                            to: request, text: TextParameters(),
                            transit: false, statusClass: 2, statusDetail: 1
                        )
                        throw TransportError.closed
                    }
                    var reply = TextParameters()
                    reply.append("CHAP_A", "5")
                    reply.append("CHAP_I", String(chapID))
                    reply.append("CHAP_C", CHAP.encodeHex(chapChallenge))
                    chapState = 1
                    try await sendLoginResponse(to: request, text: reply, transit: false)
                    continue
                }
                if config.requireChap && chapState == 1 {
                    guard
                        let name = text["CHAP_N"], name == config.chapUser,
                        let rStr = text["CHAP_R"],
                        let secret = config.chapSecret,
                        try CHAP.decodeValue(rStr) == CHAP.response(id: chapID, secret: secret, challenge: chapChallenge)
                    else {
                        try await sendLoginResponse(
                            to: request, text: TextParameters(),
                            transit: false, statusClass: 2, statusDetail: 1
                        )
                        throw TransportError.closed
                    }
                    var reply = TextParameters()
                    reply.append("TargetPortalGroupTag", "1")
                    // Mutual CHAP if the initiator challenged us.
                    if let iStr = text["CHAP_I"], let cStr = text["CHAP_C"] {
                        guard let mutual = config.mutualSecret else {
                            try await sendLoginResponse(
                                to: request, text: TextParameters(),
                                transit: false, statusClass: 2, statusDetail: 1
                            )
                            throw TransportError.closed
                        }
                        let theirID = try CHAP.decodeID(iStr)
                        let theirChallenge = try CHAP.decodeValue(cStr)
                        reply.append("CHAP_N", config.mutualName)
                        reply.append(
                            "CHAP_R",
                            CHAP.encodeHex(CHAP.response(id: theirID, secret: mutual, challenge: theirChallenge))
                        )
                    }
                    securityDone = true
                    try await sendLoginResponse(
                        to: request, text: reply,
                        transit: true, nsg: .loginOperationalNegotiation
                    )
                    continue
                }
                // Security stage content we don't expect.
                try await sendLoginResponse(
                    to: request, text: TextParameters(),
                    transit: false, statusClass: 2, statusDetail: 0
                )
                throw TransportError.closed

            case .loginOperationalNegotiation:
                guard securityDone else {
                    try await sendLoginResponse(
                        to: request, text: TextParameters(),
                        transit: false, statusClass: 2, statusDetail: 1
                    )
                    throw TransportError.closed
                }
                let answers = negotiate(text)
                let transit = request.transit
                try await sendLoginResponse(
                    to: request, text: answers,
                    transit: transit,
                    nsg: transit ? .fullFeaturePhase : .loginOperationalNegotiation,
                    tsih: text["SessionType"] == "Discovery" ? 0 : config.tsih
                )
                if transit {
                    finishLogin()
                    return
                }

            case .fullFeaturePhase:
                throw PDUError.malformed("CSG=3 is not a login stage")
            }
        }
    }

    private func sendLoginResponse(
        to request: LoginRequestPDU,
        text: TextParameters,
        transit: Bool,
        nsg: LoginStage? = nil,
        tsih: UInt16 = 0,
        statusClass: UInt8 = 0,
        statusDetail: UInt8 = 0
    ) async throws {
        var resp = LoginResponsePDU()
        resp.transit = transit
        resp.currentStage = request.currentStage
        resp.nextStage = transit ? (nsg ?? request.nextStage) : request.currentStage
        resp.isid = request.isid
        resp.tsih = tsih
        resp.initiatorTaskTag = request.initiatorTaskTag
        resp.statSN = takeStatSN()
        let w = window()
        resp.expCmdSN = w.expCmdSN
        resp.maxCmdSN = w.maxCmdSN
        resp.statusClass = statusClass
        resp.statusDetail = statusDetail
        resp.dataSegment = text.encode()
        try await send(resp)
    }

    /// Answer the initiator's operational proposal with correct result folds.
    private func negotiate(_ text: TextParameters) -> TextParameters {
        var answers = TextParameters()
        answers.append("TargetPortalGroupTag", "1")
        for (key, value) in text.pairs {
            switch key {
            case "HeaderDigest", "DataDigest":
                let offers = value.split(separator: ",").map(String.init)
                let pick: String
                if let preferred = config.digestPick, offers.contains(preferred) {
                    pick = preferred
                } else if offers.contains("None") {
                    pick = "None"
                } else {
                    pick = offers[0]
                }
                answers.append(key, pick)
                if key == "HeaderDigest" { negotiated.headerDigest = pick == "CRC32C" }
                if key == "DataDigest" { negotiated.dataDigest = pick == "CRC32C" }
            case "MaxRecvDataSegmentLength":
                initiatorMRDSL = UInt32(value) ?? 8192
                answers.append(key, String(config.maxRecvDataSegmentLength))
            case "InitialR2T":
                let result = (value == "Yes" || config.preferInitialR2T) ? "Yes" : "No"
                negotiated.initialR2T = result == "Yes"
                answers.append(key, result)
            case "ImmediateData":
                let result = (value == "Yes" && config.preferImmediateData) ? "Yes" : "No"
                negotiated.immediateData = result == "Yes"
                answers.append(key, result)
            case "MaxBurstLength":
                let result = min(UInt32(value) ?? 262_144, config.maxBurstLength)
                negotiated.maxBurstLength = result
                answers.append(key, String(result))
            case "FirstBurstLength":
                let result = min(UInt32(value) ?? 65536, config.firstBurstLength)
                negotiated.firstBurstLength = result
                answers.append(key, String(result))
            case "MaxConnections", "MaxOutstandingR2T", "ErrorRecoveryLevel", "DefaultTime2Retain":
                answers.append(key, value) // accept theirs (min fold, theirs ≤ ours)
            case "DefaultTime2Wait":
                answers.append(key, value)
            case "DataPDUInOrder", "DataSequenceInOrder":
                answers.append(key, "Yes")
            case "OFMarker", "IFMarker":
                answers.append(key, "No")
            case "InitiatorName", "SessionType", "TargetName", "AuthMethod":
                break
            default:
                answers.append(key, "NotUnderstood")
            }
        }
        return answers
    }

    private func finishLogin() {
        loggedIn = true
        sentPDUs = 0 // drop-after-N faults count full-feature-phase PDUs only
        statSN &+= faults.statSNJump
        let digests = DigestConfig(
            headerDigest: negotiated.headerDigest,
            dataDigest: negotiated.dataDigest
        )
        serializer = PDUSerializer(digests: digests)
        deframer = PDUDeframer(
            digests: digests,
            maxDataSegmentLength: Int(config.maxRecvDataSegmentLength) + 4096
        )
    }

    // MARK: - Full-feature phase

    private func fullFeaturePhase() async throws {
        while running {
            guard let pdu = try await nextPDU() else { return }
            switch pdu {
            case .scsiCommand(let command):
                noteCmdSN(command.cmdSN, immediate: command.immediate)
                try await handleCommand(command)
            case .scsiDataOut(let dataOut):
                try await handleDataOut(dataOut)
            case .nopOut(let nop):
                noteCmdSN(nop.cmdSN, immediate: nop.immediate)
                try await handleNopOut(nop)
            case .tmfRequest(let tmf):
                noteCmdSN(tmf.cmdSN, immediate: tmf.immediate)
                try await handleTMF(tmf)
            case .textRequest(let request):
                noteCmdSN(request.cmdSN, immediate: request.immediate)
                try await handleText(request)
            case .logoutRequest(let request):
                noteCmdSN(request.cmdSN, immediate: request.immediate)
                var resp = LogoutResponsePDU()
                resp.response = .success
                resp.initiatorTaskTag = request.initiatorTaskTag
                resp.statSN = takeStatSN()
                let w = window()
                resp.expCmdSN = w.expCmdSN
                resp.maxCmdSN = w.maxCmdSN
                resp.time2Wait = 2
                resp.time2Retain = 0
                try await send(resp)
                return
            default:
                try await sendReject(.protocolError, offending: pdu.encode())
            }
        }
    }

    private func handleCommand(_ command: SCSICommandPDU) async throws {
        if faults.stallCommands {
            stalledITTs.append(command.initiatorTaskTag)
            return
        }
        if faults.rejectAllCommands {
            try await sendReject(.commandNotSupported, offending: command.encode())
            return
        }
        if faults.checkConditionAll {
            try await sendCheckCondition(itt: command.initiatorTaskTag, key: 0x05, asc: 0x20, ascq: 0x00)
            return
        }

        let opcode = command.cdb.isEmpty ? 0 : command.cdb.u8(0)
        switch opcode {
        case 0x00: // TEST UNIT READY
            try await sendGoodResponse(itt: command.initiatorTaskTag)
        case 0x12: // INQUIRY
            var inquiry = Data(count: 36)
            inquiry.setU8(0x00, 0) // direct-access block device
            inquiry.setU8(0x05, 2) // SPC-3
            inquiry.setU8(0x02, 3)
            inquiry.setU8(31, 4) // additional length
            inquiry.setSub(Data("MOCKTGT ".utf8), 8)
            inquiry.setSub(Data("iSCSI-RAM-DISK  ".utf8), 16)
            inquiry.setSub(Data("0001".utf8), 32)
            let wanted = command.cdb.count >= 5 ? Int(command.cdb.beU16(3)) : 36
            try await sendReadResult(for: command, data: inquiry.prefix(wanted))
        case 0x25: // READ CAPACITY (10)
            var data = Data(count: 8)
            let lastLBA = min(disk.capacityBlocks - 1, 0xFFFF_FFFF)
            data.setBE32(UInt32(lastLBA), 0)
            data.setBE32(UInt32(disk.blockSize), 4)
            try await sendReadResult(for: command, data: data)
        case 0x9E where command.cdb.count >= 2 && command.cdb.u8(1) & 0x1F == 0x10: // READ CAPACITY (16)
            var data = Data(count: 32)
            data.setBE64(disk.capacityBlocks - 1, 0)
            data.setBE32(UInt32(disk.blockSize), 8)
            try await sendReadResult(for: command, data: data)
        case 0xA0: // REPORT LUNS
            var data = Data(count: 16)
            data.setBE32(8, 0) // one 8-byte LUN entry
            try await sendReadResult(for: command, data: data)
        case 0x28, 0x88: // READ (10) / READ (16)
            let (lba, blocks) = parseReadWrite(command.cdb)
            guard let payload = await disk.read(lba: lba, blocks: blocks) else {
                try await sendCheckCondition(itt: command.initiatorTaskTag, key: 0x05, asc: 0x21, ascq: 0x00)
                return
            }
            if faults.unsolicitedR2T {
                var r2t = R2TPDU()
                r2t.lun = command.lun
                r2t.initiatorTaskTag = command.initiatorTaskTag
                r2t.targetTransferTag = 0xDEAD
                r2t.statSN = statSN
                let w = window()
                r2t.expCmdSN = w.expCmdSN
                r2t.maxCmdSN = w.maxCmdSN
                r2t.desiredDataTransferLength = 512
                try await send(r2t)
                return
            }
            try await sendReadResult(for: command, data: payload)
        case 0x2A, 0x8A: // WRITE (10) / WRITE (16)
            let (lba, blocks) = parseReadWrite(command.cdb)
            let total = Int(blocks) * disk.blockSize
            var state = WriteState(
                lun: command.lun,
                lba: lba,
                total: total,
                buffer: Data(count: total),
                received: 0,
                awaitingUnsolicited: false,
                currentTTT: nil,
                fua: fuaBit(command.cdb)
            )
            if !command.dataSegment.isEmpty {
                state.buffer.setSub(command.dataSegment, 0)
                state.received = command.dataSegment.count
            }
            state.awaitingUnsolicited = !command.final
            writes[command.initiatorTaskTag] = state
            if !state.awaitingUnsolicited {
                try await progressWrite(itt: command.initiatorTaskTag)
            }
        case 0x35, 0x91: // SYNCHRONIZE CACHE (10) / (16)
            await disk.flush()
            try await sendGoodResponse(itt: command.initiatorTaskTag)
        case 0x5A: // MODE SENSE (10)
            try await sendReadResult(for: command, data: modeSense10(command.cdb))
        case 0x1A: // MODE SENSE (6)
            try await sendReadResult(for: command, data: modeSense6(command.cdb))
        default:
            try await sendCheckCondition(itt: command.initiatorTaskTag, key: 0x05, asc: 0x20, ascq: 0x00)
        }
    }

    /// Caching mode page (0x08). WCE=1 is the truth of this model: writes are
    /// acknowledged from a volatile cache unless they carry FUA. The daemon
    /// reads this at login to decide whether its durability assumptions hold,
    /// so answering it is not optional decoration.
    private func cachingPage() -> Data {
        var page = Data(count: 20)
        page.setU8(0x08, 0) // page code
        page.setU8(18, 1) // page length (rest of the page)
        page.setU8(0x04, 2) // WCE = 1
        return page
    }

    /// MODE SENSE(10): 8-byte header, no block descriptors, one page.
    private func modeSense10(_ cdb: Data) -> Data {
        let page = requestedPages(cdb)
        var data = Data(count: 8)
        data.setBE16(UInt16(6 + page.count), 0) // mode data length, excluding itself
        data.setBE16(0, 6) // block descriptor length
        data.append(page)
        return data
    }

    /// MODE SENSE(6): same content behind a 4-byte header. Our daemon uses the
    /// 10-byte form, but plenty of initiators still send this one.
    private func modeSense6(_ cdb: Data) -> Data {
        let page = requestedPages(cdb)
        var data = Data(count: 4)
        data.setU8(UInt8(truncatingIfNeeded: 3 + page.count), 0)
        data.setU8(0, 3) // block descriptor length
        data.append(page)
        return data
    }

    /// Page code lives in the low 6 bits of CDB byte 2; 0x3F means "all pages",
    /// which for this target is the same single page.
    private func requestedPages(_ cdb: Data) -> Data {
        let code = cdb.count >= 3 ? cdb.u8(2) & 0x3F : 0x3F
        return (code == 0x08 || code == 0x3F) ? cachingPage() : Data()
    }

    /// Force Unit Access: CDB byte 1 bit 3, same position in READ/WRITE(10)
    /// and (16). Without reading this the target cannot model a write cache,
    /// and a crash test cannot tell a durable write from a cached one.
    private func fuaBit(_ cdb: Data) -> Bool {
        cdb.count >= 2 && (cdb.u8(1) & 0x08) != 0
    }

    private func parseReadWrite(_ cdb: Data) -> (UInt64, UInt32) {
        if cdb.u8(0) == 0x28 || cdb.u8(0) == 0x2A { // 10-byte
            return (UInt64(cdb.beU32(2)), UInt32(cdb.beU16(7)))
        }
        return (cdb.beU64(2), cdb.beU32(10)) // 16-byte
    }

    /// Advance a write: issue R2T for missing data or complete it.
    private func progressWrite(itt: UInt32) async throws {
        guard var state = writes[itt] else { return }
        if state.received < state.total {
            if faults.stallAfterR2T && state.currentTTT != nil {
                return // solicited once, now stall forever
            }
            let remaining = state.total - state.received
            let desired = min(remaining, Int(negotiated.maxBurstLength))
            let ttt = nextTTT
            nextTTT &+= 1
            state.currentTTT = ttt
            writes[itt] = state
            var r2t = R2TPDU()
            r2t.lun = state.lun
            r2t.initiatorTaskTag = itt
            r2t.targetTransferTag = ttt
            r2t.statSN = statSN
            let w = window()
            r2t.expCmdSN = w.expCmdSN
            r2t.maxCmdSN = w.maxCmdSN
            r2t.r2tSN = state.nextR2TSN
            state.nextR2TSN &+= 1
            writes[itt] = state
            r2t.bufferOffset = UInt32(state.received)
            r2t.desiredDataTransferLength = UInt32(desired)
            try await send(r2t)
            if faults.stallAfterR2T {
                writes[itt] = state
            }
            return
        }
        writes.removeValue(forKey: itt)
        let ok = await disk.write(lba: state.lba, data: state.buffer, fua: state.fua)
        if ok {
            try await sendGoodResponse(itt: itt)
        } else {
            try await sendCheckCondition(itt: itt, key: 0x05, asc: 0x21, ascq: 0x00)
        }
    }

    private func handleDataOut(_ dataOut: DataOutPDU) async throws {
        guard var state = writes[dataOut.initiatorTaskTag] else {
            try await sendReject(.invalidPDUField, offending: dataOut.encode())
            return
        }
        if faults.stallAfterR2T && state.currentTTT != nil {
            return // swallow the data
        }
        let offset = Int(dataOut.bufferOffset)
        guard offset + dataOut.dataSegment.count <= state.total else {
            try await sendReject(.invalidPDUField, offending: dataOut.encode())
            return
        }
        state.buffer.setSub(dataOut.dataSegment, offset)
        state.received = max(state.received, offset + dataOut.dataSegment.count)
        writes[dataOut.initiatorTaskTag] = state
        if dataOut.final {
            if state.awaitingUnsolicited && dataOut.targetTransferTag == 0xFFFF_FFFF {
                state.awaitingUnsolicited = false
                writes[dataOut.initiatorTaskTag] = state
            }
            try await progressWrite(itt: dataOut.initiatorTaskTag)
        }
    }

    /// Send read payload as Data-In sequence + status.
    private func sendReadResult(for command: SCSICommandPDU, data: Data) async throws {
        let expected = Int(command.expectedDataTransferLength)
        let payload = data.prefix(expected)
        let underflow = payload.count < expected
        let chunkLimit = faults.oversizeDataIn
            ? payload.count
            : max(1, Int(initiatorMRDSL))
        var offset = 0
        var dataSN: UInt32 = 0
        var sent = 0
        while offset < payload.count || payload.isEmpty {
            let end = min(offset + chunkLimit, payload.count)
            let isLast = end == payload.count
            var pdu = DataInPDU()
            pdu.final = isLast
            pdu.initiatorTaskTag = command.initiatorTaskTag
            pdu.dataSN = dataSN
            pdu.bufferOffset = UInt32(offset)
            pdu.dataSegment = payload.isEmpty ? Data() : Data(payload.sub(offset, end - offset))
            let w = window()
            pdu.expCmdSN = w.expCmdSN
            pdu.maxCmdSN = w.maxCmdSN
            if isLast {
                pdu.statusPresent = true
                pdu.status = 0x00
                pdu.statSN = takeStatSN()
                if underflow {
                    pdu.residualUnderflow = true
                    pdu.residualCount = UInt32(expected - payload.count)
                }
            }
            try await send(pdu)
            sent += 1
            if let dropAt = faults.dropDuringDataInAt, sent >= dropAt {
                await transport.close()
                throw TransportError.closed
            }
            dataSN &+= 1
            offset = end
            if payload.isEmpty { break }
        }
    }

    private func sendGoodResponse(itt: UInt32) async throws {
        var resp = SCSIResponsePDU()
        resp.response = .commandCompleted
        resp.status = 0x00
        resp.initiatorTaskTag = itt
        resp.statSN = takeStatSN()
        let w = window()
        resp.expCmdSN = w.expCmdSN
        resp.maxCmdSN = w.maxCmdSN
        try await send(resp)
    }

    private func sendCheckCondition(itt: UInt32, key: UInt8, asc: UInt8, ascq: UInt8) async throws {
        var resp = SCSIResponsePDU()
        resp.response = .commandCompleted
        resp.status = 0x02
        resp.initiatorTaskTag = itt
        resp.statSN = takeStatSN()
        let w = window()
        resp.expCmdSN = w.expCmdSN
        resp.maxCmdSN = w.maxCmdSN
        var sense = Data(count: 18)
        sense.setU8(0x70, 0)
        sense.setU8(key, 2)
        sense.setU8(10, 7)
        sense.setU8(asc, 12)
        sense.setU8(ascq, 13)
        var segment = Data(count: 2)
        segment.setBE16(UInt16(sense.count), 0)
        segment.append(sense)
        resp.dataSegment = segment
        try await send(resp)
    }

    private func sendReject(_ reason: RejectPDU.Reason, offending: RawPDU) async throws {
        var reject = RejectPDU()
        reject.reason = reason
        reject.statSN = takeStatSN()
        let w = window()
        reject.expCmdSN = w.expCmdSN
        reject.maxCmdSN = w.maxCmdSN
        reject.dataSegment = offending.bhs
        try await send(reject)
    }

    private func handleNopOut(_ nop: NopOutPDU) async throws {
        if faults.swallowNops { return }
        if nop.initiatorTaskTag != 0xFFFF_FFFF {
            // Initiator ping → echo.
            var reply = NopInPDU()
            reply.initiatorTaskTag = nop.initiatorTaskTag
            reply.targetTransferTag = 0xFFFF_FFFF
            reply.statSN = takeStatSN()
            let w = window()
            reply.expCmdSN = w.expCmdSN
            reply.maxCmdSN = w.maxCmdSN
            reply.dataSegment = nop.dataSegment
            try await send(reply)
        } else {
            // Echo of our target-initiated ping.
            pingEchoes.append(nop.dataSegment)
        }
    }

    private func sendTargetPing() async throws {
        var ping = NopInPDU()
        ping.initiatorTaskTag = 0xFFFF_FFFF
        ping.targetTransferTag = 0xBEEF
        ping.statSN = statSN // not advanced for target pings
        let w = window()
        ping.expCmdSN = w.expCmdSN
        ping.maxCmdSN = w.maxCmdSN
        ping.dataSegment = Data("mock-ping".utf8)
        try await send(ping)
    }

    private func handleTMF(_ tmf: TMFRequestPDU) async throws {
        if faults.swallowTMF { return }
        // Aborts clear stalled/pending writes for that task.
        if tmf.function == .abortTask {
            writes.removeValue(forKey: tmf.referencedTaskTag)
            stalledITTs.removeAll { $0 == tmf.referencedTaskTag }
        }
        if tmf.function == .lunReset {
            writes.removeAll()
            stalledITTs.removeAll()
        }
        var resp = TMFResponsePDU()
        resp.response = .functionComplete
        resp.initiatorTaskTag = tmf.initiatorTaskTag
        resp.statSN = takeStatSN()
        let w = window()
        resp.expCmdSN = w.expCmdSN
        resp.maxCmdSN = w.maxCmdSN
        try await send(resp)
    }

    private func handleText(_ request: TextRequestPDU) async throws {
        let text = try TextParameters.decode(request.dataSegment)
        var reply = TextParameters()
        if text["SendTargets"] != nil {
            for target in config.discoveryTargets {
                reply.append("TargetName", target.name)
                for address in target.addresses {
                    reply.append("TargetAddress", address)
                }
            }
        }
        let encoded = reply.encode()
        if let splitAt = faults.splitTextResponsesAt, encoded.count > splitAt {
            // C-bit continuation: first chunk now; remainder after the empty
            // follow-up text request.
            var first = TextResponsePDU()
            first.final = false
            first.continued = true
            first.initiatorTaskTag = request.initiatorTaskTag
            first.targetTransferTag = 0x7777
            first.statSN = takeStatSN()
            var w = window()
            first.expCmdSN = w.expCmdSN
            first.maxCmdSN = w.maxCmdSN
            first.dataSegment = encoded.prefix(splitAt)
            try await send(first)

            guard let next = try await nextPDU(), case .textRequest(let followUp) = next else {
                throw PDUError.malformed("expected continuation text request")
            }
            noteCmdSN(followUp.cmdSN, immediate: followUp.immediate)
            var second = TextResponsePDU()
            second.final = true
            second.initiatorTaskTag = followUp.initiatorTaskTag
            second.statSN = takeStatSN()
            w = window()
            second.expCmdSN = w.expCmdSN
            second.maxCmdSN = w.maxCmdSN
            second.dataSegment = encoded.suffix(encoded.count - splitAt)
            try await send(second)
            return
        }
        var resp = TextResponsePDU()
        resp.final = true
        resp.initiatorTaskTag = request.initiatorTaskTag
        resp.statSN = takeStatSN()
        let w = window()
        resp.expCmdSN = w.expCmdSN
        resp.maxCmdSN = w.maxCmdSN
        resp.dataSegment = encoded
        try await send(resp)
    }
}
