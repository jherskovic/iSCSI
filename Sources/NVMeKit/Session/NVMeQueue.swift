import Foundation
import iSCSIKit

/// A command's completion: the CQE and, for reads, the bytes the C2HData
/// PDUs delivered.
public struct NVMeCompletion: Sendable {
    public let cqe: CQE
    public let data: Data
}

/// One NVMe/TCP connection, which is one queue pair: ICReq/ICResp, then a
/// Fabrics Connect, then command capsules with their data transfers. Free
/// of retry and recovery policy — that lives in `NVMeController`, exactly
/// as `ISCSIConnection` leaves it to `ISCSISession`.
public actor NVMeQueue {
    private enum State: Equatable {
        case idle
        case connected
        case closed
    }

    /// Completion holder: the responder side may complete before the
    /// requester suspends, so results are buffered. @unchecked Sendable is
    /// sound because every access happens on this actor.
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

    private final class PendingCommand {
        let opcode: UInt8
        /// Write data, kept so R2Ts can be answered from it.
        let writeData: Data
        var readBuffer: Data
        /// C2HData bytes accepted so far; a successful completion must
        /// account for every byte or the read has silent zero-filled holes.
        var receivedBytes = 0
        /// Cancelled locally; the entry stays so the controller's completion
        /// for this CID is absorbed rather than mistaken for a stray.
        var terminated = false
        let completion = Awaitable<NVMeCompletion>()

        init(opcode: UInt8, writeData: Data, expectedRead: Int) {
            self.opcode = opcode
            self.writeData = writeData
            self.readBuffer = Data(count: expectedRead)
        }
    }

    private let transport: any ConnectionTransport
    public let queueID: UInt16
    /// SQ entries as sent in Connect. The controller is told SQSIZE−1 and
    /// may have at most that many commands outstanding, so that is the
    /// in-flight bound here too.
    public let entries: UInt16
    private let requestDigests: Bool
    private let maxPDUBytes: Int

    private var serializer = NVMeTCPSerializer()
    private var deframer: NVMeTCPDeframer
    public private(set) var digests = NVMeTCPDigests()
    /// From ICResp: the largest H2CData PDU the controller accepts.
    public private(set) var maxH2CData: UInt32 = 0
    /// Bytes of write data allowed in a command capsule. 8 KiB on the admin
    /// queue (the Linux host's `NVME_TCP_ADMIN_CCSZ`); the controller sets
    /// it from IOCCSZ on the I/O queue once Identify Controller is in.
    public private(set) var inCapsuleLimit: Int

    private var state: State = .idle
    private var closeReason: ConnectionError?
    private var pending: [UInt16: PendingCommand] = [:]
    private var nextCID: UInt16 = 1
    private var slotWaiters: [Awaitable<Void>] = []
    private var closeWaiters: [CheckedContinuation<ConnectionError, Never>] = []
    private var readLoop: Task<Void, Never>?

    public init(transport: any ConnectionTransport, queueID: UInt16, entries: UInt16,
                requestDigests: Bool, maxPDUBytes: Int, inCapsuleLimit: Int = 8192) {
        precondition(entries >= 2, "a queue needs room for at least one command")
        self.transport = transport
        self.queueID = queueID
        self.entries = entries
        self.requestDigests = requestDigests
        self.maxPDUBytes = maxPDUBytes
        self.inCapsuleLimit = inCapsuleLimit
        self.deframer = NVMeTCPDeframer(maxPDUBytes: maxPDUBytes)
    }

    public func setInCapsuleLimit(_ bytes: Int) {
        inCapsuleLimit = max(0, bytes)
    }

    // MARK: - Connection initialization

    /// ICReq/ICResp, then the Fabrics Connect for this queue. Returns the
    /// controller ID the Connect answered with and whether the controller
    /// demands in-band authentication (AUTHREQ), which this initiator does
    /// not implement.
    public func connect(host: NVMeHostIdentity, subsystemNQN: String, controllerID: UInt16,
                        keepAliveMS: UInt32) async throws -> (controllerID: UInt16, authRequired: Bool) {
        guard state == .idle else { throw ConnectionError.protocolError("connect on a used queue") }

        var icreq = ICReqPDU()
        icreq.digests = requestDigests ? NVMeTCPDigests(header: true, data: true) : NVMeTCPDigests()
        icreq.maxR2T = 0
        try await sendRaw(serializer.serialize(icreq.encode()))
        let icresp = try await receiveICResp()
        guard icresp.pfv == 0 else {
            throw await fail(.protocolError("controller wants PDU format version \(icresp.pfv), only 0 is supported"))
        }
        // We asked for HPDA 0; a controller that pads its own data (CPDA) is
        // conformant but not one this deframer handles beyond PDO, and the
        // Linux host refuses it too.
        guard icresp.cpda == 0 else {
            throw await fail(.protocolError("controller requires CPDA \(icresp.cpda); only unaligned data is supported"))
        }
        if !requestDigests, icresp.digests != NVMeTCPDigests() {
            throw await fail(.protocolError("controller enabled digests that were not offered"))
        }
        guard icresp.maxH2CData >= 4096 else {
            throw await fail(.protocolError("MAXH2CDATA \(icresp.maxH2CData) is below the 4096-byte minimum"))
        }
        digests = icresp.digests
        maxH2CData = icresp.maxH2CData
        // Digests apply from the first PDU after the IC exchange.
        serializer = NVMeTCPSerializer(digests: digests)
        deframer = NVMeTCPDeframer(digests: digests, maxPDUBytes: maxPDUBytes)
        state = .connected
        startReadLoop()

        let (sqe, data) = NVMeCommands.connect(
            commandID: 0, queueID: queueID, queueEntries: entries, keepAliveMS: keepAliveMS,
            hostID: host.hostID, controllerID: controllerID,
            subsystemNQN: subsystemNQN, hostNQN: host.nqn)
        let completion = try await submit(sqe, data: data, expectedRead: 0, forceInCapsule: true)
        let status = completion.cqe.status
        guard status.isSuccess else {
            throw BlockDeviceError.nvmeStatus(sct: status.sct, sc: status.sc, opcode: NVMeOpcode.Admin.fabrics)
        }
        return (UInt16(completion.cqe.dw0 & 0xFFFF), completion.cqe.dw0 >> 16 != 0)
    }

    /// Synchronous-style PDU pull used only before the read loop starts.
    private func receiveICResp() async throws -> ICRespPDU {
        while true {
            do {
                if let raw = try deframer.next() {
                    guard case .icResp(let resp) = try AnyNVMeTCPPDU.decode(raw) else {
                        throw ConnectionError.protocolError("expected ICResp, got PDU type \(raw.type)")
                    }
                    return resp
                }
            } catch let error as NVMeTCPError {
                throw await fail(.protocolError("\(error)"))
            }
            guard let chunk = try await transport.receive() else {
                throw await fail(.connectionLost("EOF before ICResp"))
            }
            deframer.append(chunk)
        }
    }

    // MARK: - Commands

    /// Submit a command capsule and await its completion. `data` is write
    /// data — in the capsule when it fits `inCapsuleLimit`, otherwise sent
    /// as H2CData when the controller's R2T asks; `expectedRead` bytes are
    /// collected from C2HData PDUs. The queue assigns the CID and the SGL.
    public func submit(_ sqe: SQE, data: Data = Data(), expectedRead: Int = 0) async throws -> NVMeCompletion {
        try await submit(sqe, data: data, expectedRead: expectedRead, forceInCapsule: false)
    }

    /// `submit`, requiring a successful status.
    public func submitChecked(_ sqe: SQE, data: Data = Data(), expectedRead: Int = 0) async throws -> NVMeCompletion {
        let completion = try await submit(sqe, data: data, expectedRead: expectedRead)
        let status = completion.cqe.status
        guard status.isSuccess else {
            throw BlockDeviceError.nvmeStatus(sct: status.sct, sc: status.sc, opcode: sqe.opcode)
        }
        return completion
    }

    private func submit(_ sqe: SQE, data: Data, expectedRead: Int, forceInCapsule: Bool) async throws -> NVMeCompletion {
        try ensureOpen()
        try await waitForSlot()

        let cid = allocateCID()
        var sqe = sqe
        sqe.commandID = cid
        let inCapsule = !data.isEmpty && (forceInCapsule || data.count <= inCapsuleLimit)
        if !data.isEmpty {
            sqe.sgl = inCapsule ? .inCapsule(length: UInt32(data.count)) : .transport(length: UInt32(data.count))
        } else if expectedRead > 0 {
            sqe.sgl = .transport(length: UInt32(expectedRead))
        }
        let command = PendingCommand(opcode: sqe.opcode, writeData: data, expectedRead: expectedRead)
        pending[cid] = command

        let capsule = CapsuleCmdPDU(sqe: sqe.bytes, inCapsuleData: inCapsule ? data : Data())
        try await sendRaw(serializer.serialize(capsule.encode()))

        return try await withTaskCancellationHandler {
            try await suspend(command.completion)
        } onCancel: {
            Task { await self.tombstone(cid: cid) }
        }
    }

    /// Await connection teardown (the controller's recovery trigger).
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
        guard state == .connected else {
            throw closeReason ?? ConnectionError.closed
        }
    }

    /// Close with `reason` and hand it back, so a failed step can `throw`
    /// the very error the connection now carries.
    private func fail(_ reason: ConnectionError) async -> ConnectionError {
        await close(reason: reason)
        return reason
    }

    private func allocateCID() -> UInt16 {
        var cid = nextCID
        while cid == 0xFFFF || pending[cid] != nil {
            cid &+= 1
            if cid == 0 { cid = 1 }
        }
        nextCID = cid &+ 1
        if nextCID == 0 { nextCID = 1 }
        return cid
    }

    /// Block until the queue can take another command: never more than
    /// SQSIZE−1 outstanding, or the controller tears the connection down.
    private func waitForSlot() async throws {
        while state == .connected && pending.count >= Int(entries) - 1 {
            let waiter = Awaitable<Void>()
            slotWaiters.append(waiter)
            try await withTaskCancellationHandler {
                try await suspend(waiter)
            } onCancel: {
                Task { await self.cancelSlotWaiter(waiter) }
            }
        }
        try ensureOpen()
    }

    private func cancelSlotWaiter(_ waiter: Awaitable<Void>) {
        slotWaiters.removeAll { $0 === waiter }
        waiter.complete(.failure(CancellationError()))
    }

    private func releaseSlot() {
        guard !slotWaiters.isEmpty else { return }
        let waiter = slotWaiters.removeFirst()
        waiter.complete(.success(()))
    }

    private func tombstone(cid: UInt16) {
        guard state == .connected, let command = pending[cid], !command.terminated else { return }
        // Unblock the caller now; there is no cheap Abort on NVMe-oF, and the
        // entry stays so the eventual completion is absorbed, not mistaken.
        command.terminated = true
        command.completion.complete(.failure(CancellationError()))
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
            while state == .connected {
                guard let chunk = try await transport.receive() else {
                    await close(reason: .connectionLost("EOF"))
                    return
                }
                deframer.append(chunk)
                while let raw = try deframer.next() {
                    try await handle(raw)
                }
            }
        } catch let error as NVMeTCPError {
            await close(reason: .protocolError("\(error)"))
        } catch let error as ConnectionError {
            await close(reason: error)
        } catch {
            await close(reason: .connectionLost("\(error)"))
        }
    }

    private func handle(_ raw: RawNVMeTCPPDU) async throws {
        switch try AnyNVMeTCPPDU.decode(raw) {
        case .capsuleResp(let resp):
            try complete(try CQE(bytes: resp.cqe))
        case .c2hData(let pdu):
            try handleC2HData(pdu)
        case .r2t(let r2t):
            try await handleR2T(r2t)
        case .c2hTermReq(let term):
            throw ConnectionError.protocolError(
                "controller terminated the connection: FES 0x\(String(term.fes.rawValue, radix: 16)) FEI \(term.fei)")
        case .icResp:
            throw ConnectionError.protocolError("ICResp after the connection was initialized")
        case .icReq, .h2cTermReq, .capsuleCmd, .h2cData:
            throw ConnectionError.protocolError("host-to-controller PDU type \(raw.type) received from the controller")
        }
    }

    private func complete(_ cqe: CQE) throws {
        guard let command = pending.removeValue(forKey: cqe.commandID) else {
            throw ConnectionError.protocolError("completion for unknown CID \(cqe.commandID)")
        }
        releaseSlot()
        if command.terminated { return }
        // Success promises the data phase delivered everything; anything
        // less is a hole the pre-zeroed buffer would silently paper over.
        if cqe.status.isSuccess, command.receivedBytes != command.readBuffer.count {
            let error = ConnectionError.protocolError(
                "read completed successfully with \(command.receivedBytes) of \(command.readBuffer.count) bytes delivered")
            command.completion.complete(.failure(error))
            throw error
        }
        command.completion.complete(.success(NVMeCompletion(cqe: cqe, data: command.readBuffer)))
    }

    private func handleC2HData(_ pdu: C2HDataPDU) throws {
        guard let command = pending[pdu.cccid] else {
            throw ConnectionError.protocolError("C2HData for unknown CID \(pdu.cccid)")
        }
        let offset = Int(pdu.dataOffset)
        let end = offset + pdu.data.count
        guard end <= command.readBuffer.count else {
            throw ConnectionError.protocolError(
                "C2HData outside the read buffer (offset \(offset), \(pdu.data.count) bytes of \(command.readBuffer.count))")
        }
        if !command.terminated {
            command.readBuffer.setSub(pdu.data, offset)
        }
        command.receivedBytes += pdu.data.count
        if pdu.success {
            // No CapsuleResp follows: this PDU is the completion.
            try complete(CQE(sqID: queueID, commandID: pdu.cccid, status: .success))
        }
    }

    /// Answer an R2T with H2CData PDUs, each at most MAXH2CDATA, LAST_PDU on
    /// the final one for this R2T. A cancelled command still answers: the
    /// controller must collect the solicited data before it can complete.
    private func handleR2T(_ r2t: NVMeR2TPDU) async throws {
        guard let command = pending[r2t.cccid] else {
            throw ConnectionError.protocolError("R2T for unknown CID \(r2t.cccid)")
        }
        let start = Int(r2t.offset)
        let length = Int(r2t.length)
        guard length > 0, start + length <= command.writeData.count else {
            throw ConnectionError.protocolError(
                "R2T requests bytes beyond the write buffer (offset \(start), \(length) of \(command.writeData.count))")
        }
        let chunk = max(1, Int(maxH2CData))
        var offset = start
        let end = start + length
        while offset < end {
            let next = min(offset + chunk, end)
            let pdu = H2CDataPDU(cccid: r2t.cccid, ttag: r2t.ttag, dataOffset: UInt32(offset),
                                 data: Data(command.writeData.sub(offset, next - offset)),
                                 last: next == end)
            try await sendRaw(serializer.serialize(pdu.encode()))
            offset = next
        }
    }

    private func close(reason: ConnectionError) async {
        guard state != .closed else { return }
        state = .closed
        closeReason = reason
        readLoop?.cancel()
        await transport.close()

        for (_, command) in pending {
            command.completion.complete(.failure(reason))
        }
        pending = [:]
        for w in slotWaiters { w.complete(.failure(reason)) }
        slotWaiters = []
        for w in closeWaiters { w.resume(returning: reason) }
        closeWaiters = []
    }
}
