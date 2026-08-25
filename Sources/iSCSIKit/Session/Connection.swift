import Foundation

public enum ConnectionError: Error, Sendable {
    case closed
    case connectionLost(String)
    case protocolError(String)
    case loginFailed(NegotiationError)
    case redirected(address: String, permanent: Bool)
    case taskRejected(RejectPDU.Reason)
    case targetRequestedLogout
}

/// One iSCSI connection in one session: login, then full-feature-phase task
/// execution. Free of retry/recovery policy — that lives in `ISCSISession`.
public actor ISCSIConnection {
    private enum State: Equatable {
        case idle
        case fullFeature
        case closed
    }

    /// Completion holder: the responder side may complete before the
    /// requester suspends, so results are buffered. @unchecked Sendable is
    /// sound because every access happens on this actor — cancellation
    /// handlers hop back via `Task { await self... }`.
    private final class Awaitable<Value: Sendable>: @unchecked Sendable {
        var buffered: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?

        func complete(_ result: Result<Value, any Error>) {
            if let c = continuation {
                continuation = nil
                c.resume(with: result)
            } else if buffered == nil {
                buffered = result
            }
        }
    }

    private final class PendingTask {
        let task: SCSITask
        /// CmdSN the command went out with — ABORT TASK must quote it as
        /// RefCmdSN (§11.5.5).
        let cmdSN: UInt32
        var readBuffer: Data
        /// Data-In bytes accepted so far; a GOOD completion must account for
        /// every byte or the read has silent zero-filled holes.
        var receivedBytes = 0
        /// Data-In DataSN numbering is sequential for the task (§11.7.6).
        var nextDataSN: UInt32 = 0
        /// R2TSN numbering is likewise sequential (§11.8.3).
        var nextR2TSN: UInt32 = 0
        /// Completed early (cancelled or rejected); the entry stays so the
        /// target's late PDUs for this ITT — legal until the TMF response
        /// (§11.5) or post-Reject CHECK CONDITION (§11.17.1) — are absorbed.
        var terminated = false
        let completion = Awaitable<SCSITaskResult>()

        init(task: SCSITask, cmdSN: UInt32) {
            self.task = task
            self.cmdSN = cmdSN
            if case .read(let expected) = task.direction {
                readBuffer = Data(count: Int(expected))
            } else {
                readBuffer = Data()
            }
        }
    }

    private let transport: any ConnectionTransport
    private let loginConfig: LoginConfig
    private var serializer = PDUSerializer()
    /// Pre-login framer cap: the peer is unauthenticated, so keep the
    /// per-PDU allocation small (8× RFC 7143 §6.3's 8192-byte login text
    /// limit). Rebuilt at the negotiated MRDSL on the `.fullFeature`
    /// transition.
    static let loginPhaseSegmentLimit = 64 * 1024
    /// Upper bound on login round trips before we give up on the target.
    static let maxLoginRounds = 64
    /// Upper bound on a reassembled Text response. SendTargets replies are the
    /// large case and run to kilobytes on a big array, not megabytes.
    static let maxTextResponseBytes = 1 << 20
    private var deframer = PDUDeframer(maxDataSegmentLength: ISCSIConnection.loginPhaseSegmentLimit)
    public private(set) var parameters = OperationalParameters()

    private var state: State = .idle
    private var closeReason: ConnectionError?

    // Sequence numbers (RFC 7143 §10.1)
    private var cmdSN: UInt32
    private var maxCmdSN: UInt32
    private var expCmdSNSeen: UInt32 = 0
    private var expStatSN: UInt32 = 0

    // Outstanding operations by ITT
    private var pendingTasks: [UInt32: PendingTask] = [:]
    private var pendingPings: [UInt32: Awaitable<Void>] = [:]
    private var pendingTMFs: [UInt32: Awaitable<TMFResponsePDU.Response>] = [:]
    private var pendingText: [UInt32: (buffer: Data, completion: Awaitable<TextParameters>)] = [:]
    private var pendingLogout: Awaitable<LogoutResponsePDU>?
    /// ITTs of pings cancelled locally: the echo already on the wire is a
    /// conforming PDU and is absorbed instead of tearing the connection down.
    private var retiredPings: Set<UInt32> = []
    private var nextITT: UInt32 = 1
    private var windowWaiters: [Awaitable<Void>] = []
    private var closeWaiters: [CheckedContinuation<ConnectionError, Never>] = []

    private var readLoop: Task<Void, Never>?

    public init(transport: any ConnectionTransport, login: LoginConfig, initialCmdSN: UInt32 = 1) {
        self.transport = transport
        self.loginConfig = login
        self.cmdSN = initialCmdSN
        self.maxCmdSN = initialCmdSN
    }

    // MARK: - Login

    /// Run the login exchange. On success the connection enters full-feature
    /// phase and the receive loop starts.
    public func login() async throws -> LoginResult {
        guard state == .idle else { throw ConnectionError.protocolError("login on used connection") }
        guard !(loginConfig.requiresAuthentication && loginConfig.chap == nil) else {
            throw ConnectionError.protocolError(
                "authentication required but no CHAP credentials were supplied")
        }

        var machine = LoginStateMachine(config: loginConfig, cmdSN: cmdSN)
        var request = machine.start()
        var rounds = 0
        while true {
            // Bounded: the unauthenticated peer decides when login ends, and
            // empty C-bit continuations spin forever without ever hitting the
            // text-buffer cap. A round count, not a clock — deterministic on
            // slow links, and this actor has no timeout policy.
            rounds += 1
            guard rounds <= Self.maxLoginRounds else {
                let error = NegotiationError.protocolViolation(
                    "login did not complete within \(Self.maxLoginRounds) round trips")
                await close(reason: .loginFailed(error))
                throw ConnectionError.loginFailed(error)
            }
            try await sendRaw(serializer.serialize(request))
            let response = try await receiveLoginResponse()
            let outcome: LoginStateMachine.Outcome
            do {
                outcome = try machine.receive(response)
            } catch let error as NegotiationError {
                await close(reason: .loginFailed(error))
                throw ConnectionError.loginFailed(error)
            }
            switch outcome {
            case .send(let next):
                request = next
            case .redirect(let address, let permanent):
                await close(reason: .redirected(address: address, permanent: permanent))
                throw ConnectionError.redirected(address: address, permanent: permanent)
            case .success(let result):
                parameters = result.parameters
                expStatSN = result.expStatSN
                maxCmdSN = result.maxCmdSN
                expCmdSNSeen = result.expCmdSN
                // Login is always digest-free; digests turn on now.
                let digests = DigestConfig(
                    headerDigest: parameters.headerDigest,
                    dataDigest: parameters.dataDigest
                )
                serializer = PDUSerializer(digests: digests)
                deframer = PDUDeframer(
                    digests: digests,
                    maxDataSegmentLength: Int(parameters.initiatorMaxRecvDataSegmentLength)
                )
                state = .fullFeature
                startReadLoop()
                return result
            }
        }
    }

    /// Synchronous-style PDU pull used only during login (no read loop yet).
    private func receiveLoginResponse() async throws -> LoginResponsePDU {
        while true {
            if let raw = try deframer.next() {
                guard case .loginResponse(let resp) = try AnyPDU.decode(raw) else {
                    throw ConnectionError.protocolError("non-login PDU during login")
                }
                return resp
            }
            guard let chunk = try await transport.receive() else {
                await close(reason: .connectionLost("EOF during login"))
                throw ConnectionError.connectionLost("EOF during login")
            }
            deframer.append(chunk)
        }
    }

    // MARK: - Full-feature phase API

    /// Execute one SCSI task to completion.
    public func execute(_ task: SCSITask) async throws -> SCSITaskResult {
        try ensureOpen()
        try await waitForWindow()

        let itt = allocateITT()
        let pending = PendingTask(task: task, cmdSN: cmdSN)
        pendingTasks[itt] = pending

        var command = SCSICommandPDU()
        command.lun = task.lun
        command.initiatorTaskTag = itt
        command.cdb = task.cdb
        command.attribute = task.attribute
        command.cmdSN = cmdSN
        command.expStatSN = expStatSN

        var unsolicitedTail = Data()
        switch task.direction {
        case .none:
            break
        case .read(let expected):
            command.read = expected > 0
            command.expectedDataTransferLength = expected
        case .write(let data):
            command.write = true
            command.expectedDataTransferLength = UInt32(data.count)
            // Unsolicited data: immediate payload in the command PDU, then
            // Data-Out PDUs, together capped at FirstBurstLength.
            let firstBurst = Int(parameters.firstBurstLength)
            let targetMRDSL = Int(parameters.targetMaxRecvDataSegmentLength)
            var offset = 0
            if parameters.immediateData && !data.isEmpty {
                let n = min(firstBurst, targetMRDSL, data.count)
                command.dataSegment = data.prefix(n)
                offset = n
            }
            if parameters.canSendUnsolicitedDataOut && offset < min(firstBurst, data.count) {
                unsolicitedTail = data.subdata(in: offset ..< min(firstBurst, data.count))
            }
            command.final = unsolicitedTail.isEmpty
        }

        cmdSN &+= 1
        try await sendRaw(serializer.serialize(command))

        if !unsolicitedTail.isEmpty {
            try await sendDataOutSequence(
                itt: itt,
                lun: task.lun,
                ttt: 0xFFFF_FFFF,
                data: unsolicitedTail,
                bufferOffsetBase: UInt32(command.dataSegment.count)
            )
        }

        return try await withTaskCancellationHandler {
            try await suspend(pending.completion)
        } onCancel: {
            Task { await self.abortOnCancel(itt: itt) }
        }
    }

    /// Execute a task and require GOOD status, else throw with sense attached.
    public func executeChecked(_ task: SCSITask) async throws -> SCSITaskResult {
        let result = try await execute(task)
        guard result.isGood else { throw SessionError.taskFailed(result) }
        return result
    }

    /// NOP-Out ping; resolves when the echo NOP-In arrives.
    public func ping(payload: Data = Data()) async throws {
        try ensureOpen()
        let itt = allocateITT()
        let completion = Awaitable<Void>()
        pendingPings[itt] = completion

        var nop = NopOutPDU()
        nop.immediate = true
        nop.initiatorTaskTag = itt
        nop.targetTransferTag = 0xFFFF_FFFF
        nop.cmdSN = cmdSN // immediate: window not consumed
        nop.expStatSN = expStatSN
        nop.dataSegment = payload
        try await sendRaw(serializer.serialize(nop))
        try await withTaskCancellationHandler {
            try await suspend(completion)
        } onCancel: {
            Task { await self.cancelPing(itt: itt) }
        }
    }

    private func cancelPing(itt: UInt32) {
        guard let completion = pendingPings.removeValue(forKey: itt) else { return }
        retiredPings.insert(itt)
        completion.complete(.failure(CancellationError()))
    }

    /// Issue a task management function and await the target's response.
    /// For ABORT TASK, `refCmdSN` 0 resolves to the outstanding command's
    /// CmdSN; pass it explicitly for a task no longer tracked (§11.5.5).
    public func taskManagement(
        _ function: TMFRequestPDU.Function,
        lun: UInt64,
        referencedTaskTag: UInt32 = 0xFFFF_FFFF,
        refCmdSN: UInt32 = 0
    ) async throws -> TMFResponsePDU.Response {
        try ensureOpen()
        let itt = allocateITT()
        let completion = Awaitable<TMFResponsePDU.Response>()
        pendingTMFs[itt] = completion

        var tmf = TMFRequestPDU()
        tmf.immediate = true
        tmf.function = function
        tmf.lun = lun
        tmf.initiatorTaskTag = itt
        tmf.referencedTaskTag = referencedTaskTag
        // Callers aborting a still-outstanding command can't know its CmdSN;
        // resolve it here (§11.5.5) rather than sending the reserved 0.
        if function == .abortTask && refCmdSN == 0,
           let pending = pendingTasks[referencedTaskTag] {
            tmf.refCmdSN = pending.cmdSN
        } else {
            tmf.refCmdSN = refCmdSN
        }
        tmf.cmdSN = cmdSN
        tmf.expStatSN = expStatSN
        try await sendRaw(serializer.serialize(tmf))
        return try await suspend(completion)
    }

    /// Text negotiation exchange (SendTargets etc.), reassembling multi-PDU
    /// responses (F=0 and C=1 continuations) from the target.
    public func textExchange(_ params: TextParameters) async throws -> TextParameters {
        try ensureOpen()
        try await waitForWindow()
        let itt = allocateITT()
        let completion = Awaitable<TextParameters>()
        pendingText[itt] = (Data(), completion)

        var req = TextRequestPDU()
        req.initiatorTaskTag = itt
        req.targetTransferTag = 0xFFFF_FFFF
        req.cmdSN = cmdSN
        req.expStatSN = expStatSN
        req.dataSegment = params.encode()
        cmdSN &+= 1
        try await sendRaw(serializer.serialize(req))
        return try await suspend(completion)
    }

    /// Clean logout. Returns Time2Wait/Time2Retain from the target.
    public func logout(reason: LogoutRequestPDU.Reason = .closeSession) async throws -> LogoutResponsePDU {
        try ensureOpen()
        let completion = Awaitable<LogoutResponsePDU>()
        pendingLogout = completion

        var req = LogoutRequestPDU()
        req.immediate = true
        req.reason = reason
        req.initiatorTaskTag = allocateITT()
        req.cid = loginConfig.cid
        req.cmdSN = cmdSN
        req.expStatSN = expStatSN
        try await sendRaw(serializer.serialize(req))
        let response = try await suspend(completion)
        await close(reason: .closed)
        return response
    }

    /// Await connection teardown (the session layer's recovery trigger).
    public func waitClosed() async -> ConnectionError {
        if state == .closed { return closeReason ?? .closed }
        return await withCheckedContinuation { c in
            closeWaiters.append(c)
        }
    }

    public func close() async {
        await close(reason: .closed)
    }

    // MARK: - Internals

    private func suspend<V: Sendable>(_ box: Awaitable<V>) async throws -> V {
        if let buffered = box.buffered {
            box.buffered = nil
            return try buffered.get()
        }
        return try await withCheckedThrowingContinuation { box.continuation = $0 }
    }

    private func ensureOpen() throws {
        guard state == .fullFeature else {
            throw closeReason ?? ConnectionError.closed
        }
    }

    private func allocateITT() -> UInt32 {
        defer {
            nextITT &+= 1
            if nextITT == 0xFFFF_FFFF { nextITT = 1 }
        }
        return nextITT
    }

    /// Block until the CmdSN window admits a new non-immediate command.
    /// Cancellation-aware: a cancelled waiter unblocks with CancellationError.
    private func waitForWindow() async throws {
        while state == .fullFeature && Serial.lt(maxCmdSN, cmdSN) {
            let waiter = Awaitable<Void>()
            windowWaiters.append(waiter)
            try await withTaskCancellationHandler {
                try await suspend(waiter)
            } onCancel: {
                Task { await self.cancelWindowWaiter(waiter) }
            }
        }
        try ensureOpen()
    }

    private func cancelWindowWaiter(_ waiter: Awaitable<Void>) {
        windowWaiters.removeAll { $0 === waiter }
        waiter.complete(.failure(CancellationError()))
    }

    private func sendRaw(_ bytes: Data) async throws {
        do {
            try await transport.send(bytes)
        } catch {
            await close(reason: .connectionLost("send failed: \(error)"))
            throw closeReason ?? ConnectionError.closed
        }
    }

    private func startReadLoop() {
        readLoop = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    private func runReadLoop() async {
        do {
            while state == .fullFeature {
                guard let chunk = try await transport.receive() else {
                    await close(reason: .connectionLost("EOF"))
                    return
                }
                deframer.append(chunk)
                while let raw = try deframer.next() {
                    try await handle(raw)
                }
            }
        } catch let error as PDUError {
            await close(reason: .protocolError("\(error)"))
        } catch let error as ConnectionError {
            await close(reason: error)
        } catch {
            await close(reason: .connectionLost("\(error)"))
        }
    }

    private func handle(_ raw: RawPDU) async throws {
        let pdu = try AnyPDU.decode(raw)
        switch pdu {
        case .scsiResponse(let resp):
            try advanceStatSN(resp.statSN)
            updateWindow(expCmdSN: resp.expCmdSN, maxCmdSN: resp.maxCmdSN)
            try completeTask(resp)
        case .scsiDataIn(let dataIn):
            updateWindow(expCmdSN: dataIn.expCmdSN, maxCmdSN: dataIn.maxCmdSN)
            if dataIn.statusPresent { try advanceStatSN(dataIn.statSN) }
            try handleDataIn(dataIn)
        case .r2t(let r2t):
            updateWindow(expCmdSN: r2t.expCmdSN, maxCmdSN: r2t.maxCmdSN)
            try await handleR2T(r2t)
        case .nopIn(let nop):
            updateWindow(expCmdSN: nop.expCmdSN, maxCmdSN: nop.maxCmdSN)
            try await handleNopIn(nop)
        case .tmfResponse(let resp):
            try advanceStatSN(resp.statSN)
            updateWindow(expCmdSN: resp.expCmdSN, maxCmdSN: resp.maxCmdSN)
            guard let completion = pendingTMFs.removeValue(forKey: resp.initiatorTaskTag) else {
                throw ConnectionError.protocolError("TMF response for unknown ITT")
            }
            completion.complete(.success(resp.response))
        case .textResponse(let resp):
            try advanceStatSN(resp.statSN)
            updateWindow(expCmdSN: resp.expCmdSN, maxCmdSN: resp.maxCmdSN)
            try await handleTextResponse(resp)
        case .logoutResponse(let resp):
            try advanceStatSN(resp.statSN)
            updateWindow(expCmdSN: resp.expCmdSN, maxCmdSN: resp.maxCmdSN)
            guard let completion = pendingLogout else {
                throw ConnectionError.protocolError("unsolicited logout response")
            }
            pendingLogout = nil
            completion.complete(.success(resp))
        case .asyncMessage(let msg):
            try advanceStatSN(msg.statSN)
            updateWindow(expCmdSN: msg.expCmdSN, maxCmdSN: msg.maxCmdSN)
            switch msg.event {
            case .logoutRequest:
                // §11.9.1 event 1: the initiator MUST honor the demand by
                // issuing a Logout (within Parameter3 seconds), not by
                // silently dropping TCP.
                try await honorTargetLogoutRequest(deadlineSeconds: msg.parameter3)
            case .sessionDropNotification, .connectionDropNotification:
                // The target is dropping us either way; nothing to send.
                throw ConnectionError.targetRequestedLogout
            default:
                break
            }
        case .reject(let reject):
            try advanceStatSN(reject.statSN)
            updateWindow(expCmdSN: reject.expCmdSN, maxCmdSN: reject.maxCmdSN)
            try handleReject(reject)
        case .loginResponse:
            throw ConnectionError.protocolError("login response in full-feature phase")
        default:
            throw ConnectionError.protocolError("unexpected initiator-opcode PDU from target")
        }
    }

    /// Status-bearing PDUs must carry exactly the next StatSN (at ERL0 a gap
    /// or regression means lost/replayed status — fatal for the connection).
    private func advanceStatSN(_ statSN: UInt32) throws {
        guard statSN == expStatSN else {
            throw ConnectionError.protocolError("StatSN \(statSN), expected \(expStatSN)")
        }
        expStatSN &+= 1
    }

    private func updateWindow(expCmdSN: UInt32, maxCmdSN newMax: UInt32) {
        if Serial.lt(expCmdSNSeen, expCmdSN) { expCmdSNSeen = expCmdSN }
        if Serial.lt(maxCmdSN, newMax) {
            maxCmdSN = newMax
            let waiters = windowWaiters
            windowWaiters = []
            for w in waiters { w.complete(.success(())) }
        }
    }

    private func completeTask(_ resp: SCSIResponsePDU) throws {
        guard let pending = pendingTasks.removeValue(forKey: resp.initiatorTaskTag) else {
            throw ConnectionError.protocolError("SCSI response for unknown ITT \(resp.initiatorTaskTag)")
        }
        if pending.terminated { return } // final word on an abandoned task
        guard resp.response == .commandCompleted else {
            pending.completion.complete(.failure(ConnectionError.protocolError("target failure response")))
            return
        }
        var result = SCSITaskResult(status: resp.status)
        result.data = pending.readBuffer
        result.residualCount = resp.residualCount
        result.residualIsOverflow = resp.residualOverflow
        if case .read = pending.task.direction {
            var valid = pending.readBuffer.count
            if resp.residualUnderflow {
                valid -= Int(min(resp.residualCount, UInt32(pending.readBuffer.count)))
                result.data = pending.readBuffer.prefix(valid)
            }
            // GOOD promises the data phase delivered everything the residual
            // accounting claims; anything less is a hole the pre-zeroed
            // buffer would silently paper over.
            if resp.status == 0x00 && pending.receivedBytes != valid {
                throw ConnectionError.protocolError(
                    "read completed GOOD with \(pending.receivedBytes) of \(valid) bytes delivered")
            }
        }
        if resp.status == 0x02 { result.sense = resp.senseData }
        pending.completion.complete(.success(result))
    }

    private func handleDataIn(_ dataIn: DataInPDU) throws {
        guard let pending = pendingTasks[dataIn.initiatorTaskTag] else {
            throw ConnectionError.protocolError("Data-In for unknown ITT \(dataIn.initiatorTaskTag)")
        }
        if pending.terminated {
            // Abandoned task: absorb its data phase; status retires the ITT.
            if dataIn.statusPresent { pendingTasks.removeValue(forKey: dataIn.initiatorTaskTag) }
            return
        }
        guard case .read(let expected) = pending.task.direction else {
            throw ConnectionError.protocolError("Data-In for non-read task")
        }
        // §11.7.6: DataSN is sequential for the task; with DataPDUInOrder in
        // force the offsets are contiguous too. At ERL0 a gap is data the
        // target will never resend — fail now, not with a zero-filled buffer.
        guard dataIn.dataSN == pending.nextDataSN else {
            throw ConnectionError.protocolError(
                "Data-In DataSN \(dataIn.dataSN), expected \(pending.nextDataSN)")
        }
        pending.nextDataSN &+= 1
        let offset = Int(dataIn.bufferOffset)
        guard offset == pending.receivedBytes else {
            throw ConnectionError.protocolError(
                "Data-In at offset \(offset), expected \(pending.receivedBytes)")
        }
        let end = offset + dataIn.dataSegment.count
        guard end <= Int(expected) else {
            throw ConnectionError.protocolError(
                "Data-In outside read buffer (offset \(offset), \(dataIn.dataSegment.count) bytes)"
            )
        }
        pending.readBuffer.setSub(dataIn.dataSegment, offset)
        pending.receivedBytes = end

        if dataIn.statusPresent {
            // Phase-collapsed completion: no separate SCSI Response follows.
            pendingTasks.removeValue(forKey: dataIn.initiatorTaskTag)
            var result = SCSITaskResult(status: dataIn.status)
            result.data = pending.readBuffer
            result.residualCount = dataIn.residualCount
            result.residualIsOverflow = dataIn.residualOverflow
            var valid = pending.readBuffer.count
            if dataIn.residualUnderflow {
                valid -= Int(min(dataIn.residualCount, UInt32(pending.readBuffer.count)))
                result.data = pending.readBuffer.prefix(valid)
            }
            if dataIn.status == 0x00 && pending.receivedBytes != valid {
                throw ConnectionError.protocolError(
                    "read completed GOOD with \(pending.receivedBytes) of \(valid) bytes delivered")
            }
            pending.completion.complete(.success(result))
        }
    }

    private func handleR2T(_ r2t: R2TPDU) async throws {
        guard let pending = pendingTasks[r2t.initiatorTaskTag] else {
            throw ConnectionError.protocolError("R2T for unknown ITT \(r2t.initiatorTaskTag)")
        }
        guard case .write(let data) = pending.task.direction else {
            throw ConnectionError.protocolError("R2T for non-write task")
        }
        // §11.8.3: R2TSN numbering is sequential for the task.
        guard r2t.r2tSN == pending.nextR2TSN else {
            throw ConnectionError.protocolError(
                "R2T R2TSN \(r2t.r2tSN), expected \(pending.nextR2TSN)")
        }
        pending.nextR2TSN &+= 1
        let start = Int(r2t.bufferOffset)
        let length = Int(r2t.desiredDataTransferLength)
        // §11.8: an R2T must not solicit more than MaxBurstLength, and
        // honoring one would make us violate the send-side MUST of §13.12.
        guard length <= Int(parameters.maxBurstLength) else {
            throw ConnectionError.protocolError(
                "R2T requests \(length) bytes, MaxBurstLength is \(parameters.maxBurstLength)")
        }
        guard start + length <= data.count else {
            throw ConnectionError.protocolError("R2T requests bytes beyond write buffer")
        }
        // A terminated task still answers its R2Ts: the target must collect
        // the solicited data before it can complete the abort (§11.5).
        try await sendDataOutSequence(
            itt: r2t.initiatorTaskTag,
            lun: pending.task.lun,
            ttt: r2t.targetTransferTag,
            data: data.subdata(in: start ..< start + length),
            bufferOffsetBase: r2t.bufferOffset
        )
    }

    /// One Data-Out sequence (unsolicited tail or an R2T answer), chunked to
    /// the target's MaxRecvDataSegmentLength, DataSN starting at 0.
    private func sendDataOutSequence(
        itt: UInt32,
        lun: UInt64,
        ttt: UInt32,
        data: Data,
        bufferOffsetBase: UInt32
    ) async throws {
        let chunkSize = max(1, Int(parameters.targetMaxRecvDataSegmentLength))
        var dataSN: UInt32 = 0
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            var out = DataOutPDU()
            out.lun = lun
            out.initiatorTaskTag = itt
            out.targetTransferTag = ttt
            out.expStatSN = expStatSN
            out.dataSN = dataSN
            out.bufferOffset = bufferOffsetBase + UInt32(offset)
            out.dataSegment = data.subdata(in: offset ..< end)
            out.final = end == data.count
            try await sendRaw(serializer.serialize(out))
            dataSN &+= 1
            offset = end
        }
    }

    private func handleNopIn(_ nop: NopInPDU) async throws {
        if nop.initiatorTaskTag != 0xFFFF_FFFF {
            // Echo of one of our pings — but only if we actually sent one.
            if let completion = pendingPings.removeValue(forKey: nop.initiatorTaskTag) {
                try advanceStatSN(nop.statSN)
                completion.complete(.success(()))
            } else if retiredPings.remove(nop.initiatorTaskTag) != nil {
                // Ping cancelled locally; the echo is conforming — absorb it.
                try advanceStatSN(nop.statSN)
            } else {
                throw ConnectionError.protocolError("NOP-In echo for unknown ITT")
            }
        } else if nop.isPing {
            // Target-initiated ping: MUST echo the TTT, LUN, and payload —
            // the payload clipped to what the target can receive (§11.18.3).
            var reply = NopOutPDU()
            reply.immediate = true
            reply.initiatorTaskTag = 0xFFFF_FFFF
            reply.targetTransferTag = nop.targetTransferTag
            reply.lun = nop.lun
            reply.cmdSN = cmdSN
            reply.expStatSN = expStatSN
            reply.dataSegment = Data(
                nop.dataSegment.prefix(Int(parameters.targetMaxRecvDataSegmentLength)))
            try await sendRaw(serializer.serialize(reply))
        }
        // Else: both tags reserved — a pure ExpCmdSN/MaxCmdSN update
        // (§11.19.1); the window was already folded in by handle().
    }

    private func handleTextResponse(_ resp: TextResponsePDU) async throws {
        guard var entry = pendingText[resp.initiatorTaskTag] else {
            throw ConnectionError.protocolError("text response for unknown ITT")
        }
        entry.buffer.append(resp.dataSegment)
        // Bounded: the target decides when a continued sequence ends.
        guard entry.buffer.count <= Self.maxTextResponseBytes else {
            pendingText.removeValue(forKey: resp.initiatorTaskTag)
            let error = ConnectionError.protocolError(
                "text response exceeded \(Self.maxTextResponseBytes) bytes")
            entry.completion.complete(.failure(error))
            throw error
        }
        if !resp.final {
            // F=0 continues the exchange, with or without C=1. §11.11.4:
            // a non-final response carries a valid TTT, and the empty F=1
            // follow-up copies the TTT and the LUN.
            guard resp.targetTransferTag != 0xFFFF_FFFF else {
                throw ConnectionError.protocolError("non-final text response with reserved TTT")
            }
            pendingText[resp.initiatorTaskTag] = entry
            // Through the command window: bumping CmdSN past MaxCmdSN would
            // wedge the session, since the target ignores everything outside
            // the window.
            try await waitForWindow()
            var req = TextRequestPDU()
            req.initiatorTaskTag = resp.initiatorTaskTag
            req.targetTransferTag = resp.targetTransferTag
            req.lun = resp.lun
            req.cmdSN = cmdSN
            req.expStatSN = expStatSN
            cmdSN &+= 1
            try await sendRaw(serializer.serialize(req))
        } else {
            pendingText.removeValue(forKey: resp.initiatorTaskTag)
            do {
                let params = try TextParameters.decode(entry.buffer)
                entry.completion.complete(.success(params))
            } catch {
                entry.completion.complete(.failure(error))
            }
        }
    }

    /// §11.9.1 event 1: send a Logout Request in answer to the target's
    /// demand, then close once the Logout Response arrives (or the target's
    /// own deadline passes without one). The read loop keeps running so the
    /// response can actually be received.
    private func honorTargetLogoutRequest(deadlineSeconds: UInt16) async throws {
        guard pendingLogout == nil else { return } // a logout is already in flight
        let completion = Awaitable<LogoutResponsePDU>()
        pendingLogout = completion

        var req = LogoutRequestPDU()
        req.immediate = true
        req.reason = .closeSession
        req.initiatorTaskTag = allocateITT()
        req.cid = loginConfig.cid
        req.cmdSN = cmdSN
        req.expStatSN = expStatSN
        try await sendRaw(serializer.serialize(req))

        let seconds = deadlineSeconds == 0 ? 5 : Int(min(deadlineSeconds, 30))
        let limit = Duration.seconds(seconds)
        Task { [weak self] in
            await self?.awaitLogoutThenClose(completion, within: limit)
        }
    }

    private func awaitLogoutThenClose(
        _ completion: Awaitable<LogoutResponsePDU>, within limit: Duration
    ) async {
        _ = try? await withDeadline(limit) { [weak self] in
            guard let self else { throw ConnectionError.closed }
            _ = try await self.suspend(completion)
        }
        await close(reason: .targetRequestedLogout)
    }

    private func handleReject(_ reject: RejectPDU) throws {
        // The rejected PDU's header rides in the data segment; fail that
        // operation if identifiable, otherwise the connection is unusable.
        if reject.dataSegment.count >= 48 {
            let itt = reject.dataSegment.beU32(16)
            if let pending = pendingTasks[itt] {
                if !pending.terminated {
                    pending.terminated = true
                    pending.completion.complete(.failure(ConnectionError.taskRejected(reject.reason)))
                }
                // The entry stays: §11.17.1 obliges the target to follow with
                // a CHECK CONDITION response for the terminated task, and
                // that response retires the ITT.
                return
            }
            if let ping = pendingPings.removeValue(forKey: itt) {
                ping.complete(.failure(ConnectionError.taskRejected(reject.reason)))
                return
            }
            if let completion = pendingTMFs.removeValue(forKey: itt) {
                completion.complete(.failure(ConnectionError.taskRejected(reject.reason)))
                return
            }
            if let entry = pendingText.removeValue(forKey: itt) {
                entry.completion.complete(.failure(ConnectionError.taskRejected(reject.reason)))
                return
            }
        }
        throw ConnectionError.protocolError("Reject (\(reject.reason)) for unidentifiable PDU")
    }

    private func abortOnCancel(itt: UInt32) async {
        guard state == .fullFeature, let pending = pendingTasks[itt], !pending.terminated else { return }
        // Unblock the caller first: waiting on the TMF response would turn a
        // bounded cancellation into an unbounded hang on a dead target. The
        // entry stays, flagged — the target may legally deliver the task's
        // response or data until it answers the TMF (§11.5).
        pending.terminated = true
        pending.completion.complete(.failure(CancellationError()))
        let lun = pending.task.lun
        let refCmdSN = pending.cmdSN
        Task { await self.sendBestEffortAbort(itt: itt, lun: lun, refCmdSN: refCmdSN) }
    }

    /// Tell the target to drop a task we have stopped waiting for. Bounded,
    /// because this runs detached and a stuck TMF would leak the task forever.
    private func sendBestEffortAbort(itt: UInt32, lun: UInt64, refCmdSN: UInt32) async {
        _ = try? await withDeadline(.seconds(5)) { [weak self] in
            guard let self else { return }
            _ = try? await self.taskManagement(
                .abortTask, lun: lun, referencedTaskTag: itt, refCmdSN: refCmdSN)
        }
        // §11.5: after the TMF response (or our deadline) no further response
        // for the aborted task may be delivered; drop the tombstone.
        retireTerminatedTask(itt: itt)
    }

    private func retireTerminatedTask(itt: UInt32) {
        if let pending = pendingTasks[itt], pending.terminated {
            pendingTasks.removeValue(forKey: itt)
        }
    }

    private func close(reason: ConnectionError) async {
        guard state != .closed else { return }
        state = .closed
        closeReason = reason
        readLoop?.cancel()
        await transport.close()

        for (_, pending) in pendingTasks {
            pending.completion.complete(.failure(reason))
        }
        pendingTasks = [:]
        for (_, c) in pendingPings { c.complete(.failure(reason)) }
        pendingPings = [:]
        for (_, c) in pendingTMFs { c.complete(.failure(reason)) }
        pendingTMFs = [:]
        for (_, entry) in pendingText { entry.completion.complete(.failure(reason)) }
        pendingText = [:]
        pendingLogout?.complete(.failure(reason))
        pendingLogout = nil
        retiredPings = []
        for w in windowWaiters { w.complete(.failure(reason)) }
        windowWaiters = []
        for w in closeWaiters { w.resume(returning: reason) }
        closeWaiters = []
    }
}
