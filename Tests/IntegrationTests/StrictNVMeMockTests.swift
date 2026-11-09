import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// The host side of a MemoryPipe speaking raw NVMe/TCP, for the rules the
/// real initiator never breaks — the only way to show the mock refuses
/// them, and refuses them the way nvmet does.
///
/// @unchecked Sendable: each test drives it from one task at a time.
final class RawNVMeHost: @unchecked Sendable {
    enum ScriptError: Error { case unexpected(String) }

    let pipe: any ConnectionTransport
    private var serializer = NVMeTCPSerializer()
    private var deframer = NVMeTCPDeframer(maxPDUBytes: 4 << 20)

    init(_ pipe: any ConnectionTransport) {
        self.pipe = pipe
    }

    func send(_ raw: RawNVMeTCPPDU) async throws {
        try await pipe.send(serializer.serialize(raw))
    }

    /// Several PDUs in one write, so the controller has them all at once.
    func sendTogether(_ raws: [RawNVMeTCPPDU]) async throws {
        try await pipe.send(raws.reduce(into: Data()) { $0.append(serializer.serialize($1)) })
    }

    /// Next PDU from the controller; nil on EOF. Bounded, so a script that
    /// never gets what it waits for fails rather than hangs.
    func next() async throws -> AnyNVMeTCPPDU? {
        try await withDeadline(.seconds(5)) { [self] in
            while true {
                if let raw = try deframer.next() { return try AnyNVMeTCPPDU.decode(raw) }
                guard let chunk = try await pipe.receive() else { return nil }
                deframer.append(chunk)
            }
        }
    }

    func expectClosed() async throws -> Bool {
        try await next() == nil
    }

    /// The completion for `cid`, with any C2HData before it.
    func completion(_ cid: UInt16) async throws -> (cqe: CQE, data: Data) {
        var data = Data()
        while let pdu = try await next() {
            switch pdu {
            case .c2hData(let c2h) where c2h.cccid == cid:
                data.append(c2h.data)
            case .capsuleResp(let resp):
                let cqe = try CQE(bytes: resp.cqe)
                guard cqe.commandID == cid else { throw ScriptError.unexpected("completion for CID \(cqe.commandID)") }
                return (cqe, data)
            default:
                throw ScriptError.unexpected("\(pdu.pduType) while waiting for CID \(cid)")
            }
        }
        throw ScriptError.unexpected("EOF while waiting for CID \(cid)")
    }

    func icExchange() async throws {
        try await send(ICReqPDU().encode())
        guard case .icResp = try await next() else { throw ScriptError.unexpected("no ICResp") }
    }

    func command(_ sqe: SQE, data: Data = Data()) async throws {
        try await send(CapsuleCmdPDU(sqe: sqe.bytes, inCapsuleData: data).encode())
    }

    func connect(cid: UInt16 = 1, qid: UInt16, entries: UInt16 = 32, controllerID: UInt16 = 0xFFFF,
                 subsystemNQN: String = MockNVMeConfig().subsystemNQN) async throws -> CQE {
        let (sqe, data) = NVMeCommands.connect(
            commandID: cid, queueID: qid, queueEntries: entries, keepAliveMS: 0,
            hostID: testHost.hostID, controllerID: controllerID,
            subsystemNQN: subsystemNQN, hostNQN: testHost.nqn)
        try await command(sqe, data: data)
        return try await completion(cid).cqe
    }

    func enable(cid: UInt16 = 2) async throws {
        try await command(NVMeCommands.propertySet(
            commandID: cid, offset: NVMeProperty.cc, value: NVMeCommands.controllerConfigurationEnable))
        _ = try await completion(cid)
    }

    /// IC exchange and Connect for `qid`; the admin queue is also enabled.
    static func up(_ fleet: NVMeFleet, qid: UInt16 = 0, entries: UInt16 = 32,
                   controllerID: UInt16 = 0xFFFF) async throws -> (RawNVMeHost, UInt16) {
        let host = RawNVMeHost(await fleet.makeTransport())
        try await host.icExchange()
        let cqe = try await host.connect(qid: qid, entries: entries, controllerID: controllerID)
        #expect(cqe.status.isSuccess)
        if qid == 0 { try await host.enable() }
        return (host, UInt16(cqe.dw0 & 0xFFFF))
    }
}

private func status(_ cqe: CQE) -> (UInt8, UInt8, Bool) {
    (cqe.status.sct, cqe.status.sc, cqe.status.dnr)
}

private func violations(_ fleet: NVMeFleet) async -> [String] {
    await fleet.subsystem.protocolViolations
}

/// The NVMe mock refuses what nvmet refuses. Each test commits one
/// violation by hand and checks the refusal; the integration suites then
/// rely on `NVMeFleet.shutdown()` finding no violation from the real host.
@Suite("Strict NVMe/TCP mock: what it refuses", .timeLimit(.minutes(1)))
struct StrictNVMeMockTests {
    // MARK: Nothing but Fabrics before CC.EN

    @Test func adminCommandsBeforeCCENAreACommandSequenceError() async throws {
        let fleet = NVMeFleet()
        let host = RawNVMeHost(await fleet.makeTransport())
        try await host.icExchange()
        #expect(try await host.connect(qid: 0).status.isSuccess)

        try await host.command(NVMeCommands.identify(commandID: 5, cns: IdentifyCNS.controller))
        let refused = try await host.completion(5)
        #expect(status(refused.cqe) == (0, 0x0C, true))
        #expect(refused.data.isEmpty)

        // Property Get and Set are how a host gets to CC.EN, so they pass.
        try await host.command(NVMeCommands.propertyGet(commandID: 6, offset: NVMeProperty.cap, wide: true))
        #expect(try await host.completion(6).cqe.status.isSuccess)
        try await host.enable(cid: 7)
        try await host.command(NVMeCommands.identify(commandID: 8, cns: IdentifyCNS.controller))
        let served = try await host.completion(8)
        #expect(served.cqe.status.isSuccess)
        #expect(served.data.count == 4096)
        #expect(await violations(fleet).count == 1)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func ioCommandsOnAControllerNotEnabledAreACommandSequenceError() async throws {
        let fleet = NVMeFleet()
        let admin = RawNVMeHost(await fleet.makeTransport())
        try await admin.icExchange()
        let cntlid = UInt16(try await admin.connect(qid: 0).dw0 & 0xFFFF)
        let (io, _) = try await RawNVMeHost.up(fleet, qid: 1, controllerID: cntlid)
        try await io.command(NVMeCommands.read(commandID: 9, nsid: 1, slba: 0, blocks: 1, blockSize: 4096))
        #expect(status(try await io.completion(9).cqe) == (0, 0x0C, true))
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func aShutDownControllerTakesNoMoreCommands() async throws {
        let fleet = NVMeFleet()
        let (admin, _) = try await RawNVMeHost.up(fleet)
        try await admin.command(NVMeCommands.propertySet(
            commandID: 3, offset: NVMeProperty.cc,
            value: NVMeCommands.controllerConfigurationEnable | NVMeCommands.shutdownNormal))
        #expect(try await admin.completion(3).cqe.status.isSuccess)
        try await admin.command(NVMeCommands.propertyGet(commandID: 4, offset: NVMeProperty.csts, wide: false))
        let csts = ControllerStatus(raw: try await admin.completion(4).cqe.dw0)
        #expect(csts.shutdownComplete && !csts.ready)
        try await admin.command(NVMeCommands.keepAlive(commandID: 5))
        #expect(status(try await admin.completion(5).cqe) == (0, 0x0C, true))
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func anythingButConnectBeforeConnectIsAnInvalidOpcode() async throws {
        let fleet = NVMeFleet()
        let host = RawNVMeHost(await fleet.makeTransport())
        try await host.icExchange()
        try await host.command(NVMeCommands.propertyGet(commandID: 1, offset: NVMeProperty.cap, wide: true))
        #expect(status(try await host.completion(1).cqe) == (0, 0x01, true))
        await fleet.shutdown(expectingViolations: true)
    }

    // MARK: Connect names the controller

    @Test func anAdminConnectMustAskForAnyController() async throws {
        let fleet = NVMeFleet()
        let host = RawNVMeHost(await fleet.makeTransport())
        try await host.icExchange()
        let cqe = try await host.connect(qid: 0, controllerID: 1)
        #expect(status(cqe) == (1, 0x82, true))
        #expect(cqe.dw0 == 0x1_0010)                  // IATTR 1 (data), IPO 16 (CNTLID)
        #expect(try await host.expectClosed())
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func anIOConnectMustNameTheControllerTheAdminConnectReturned() async throws {
        let fleet = NVMeFleet()
        let (_, cntlid) = try await RawNVMeHost.up(fleet)

        let stranger = RawNVMeHost(await fleet.makeTransport())
        try await stranger.icExchange()
        #expect(status(try await stranger.connect(qid: 1, controllerID: cntlid &+ 1)) == (1, 0x82, true))

        let anyController = RawNVMeHost(await fleet.makeTransport())
        try await anyController.icExchange()
        #expect(status(try await anyController.connect(qid: 1, controllerID: 0xFFFF)) == (1, 0x82, true))

        let otherSubsystem = RawNVMeHost(await fleet.makeTransport())
        try await otherSubsystem.icExchange()
        #expect(status(try await otherSubsystem.connect(
            qid: 1, controllerID: cntlid, subsystemNQN: "nqn.2026-08.test.example:other")) == (1, 0x82, true))

        let (_, ioID) = try await RawNVMeHost.up(fleet, qid: 1, controllerID: cntlid)
        #expect(ioID == cntlid)

        // The same QID twice on one controller: nvmet's "qid already created".
        let again = RawNVMeHost(await fleet.makeTransport())
        try await again.icExchange()
        #expect(status(try await again.connect(qid: 1, controllerID: cntlid)) == (0, 0x0C, true))
        #expect(await violations(fleet).count == 4)
        await fleet.shutdown(expectingViolations: true)
    }

    // MARK: SQSIZE

    @Test func sqsizeZeroAndSQSIZEPastMQESAreRefused() async throws {
        var config = MockNVMeConfig()
        config.maxQueueEntries = 16
        let fleet = NVMeFleet(config: config)
        let (_, cntlid) = try await RawNVMeHost.up(fleet)
        let deep = RawNVMeHost(await fleet.makeTransport())
        try await deep.icExchange()
        let refused = try await deep.connect(qid: 1, entries: 17, controllerID: cntlid)
        #expect(status(refused) == (1, 0x82, true))
        #expect(refused.dw0 == 44)                    // IATTR 0 (command), IPO 44 (SQSIZE)
        let empty = RawNVMeHost(await fleet.makeTransport())
        try await empty.icExchange()
        #expect(status(try await empty.connect(qid: 1, entries: 1, controllerID: cntlid)) == (1, 0x82, true))
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func moreCommandsThanTheQueueHoldsTearTheQueueDown() async throws {
        var config = MockNVMeConfig()
        config.faults.stallCommands = true
        let fleet = NVMeFleet(config: config)
        // Stalled, so nothing completes: what is outstanding stays outstanding.
        let (admin, _) = try await RawNVMeHost.up(fleet, entries: 2)   // SQSIZE 1: two entries
        try await admin.sendTogether([
            CapsuleCmdPDU(sqe: NVMeCommands.keepAlive(commandID: 10).bytes).encode(),
            CapsuleCmdPDU(sqe: NVMeCommands.keepAlive(commandID: 11).bytes).encode(),
        ])
        #expect(await eventually { await fleet.subsystem.stalledCIDs == [10, 11] })
        #expect(await violations(fleet).isEmpty)
        try await admin.command(NVMeCommands.keepAlive(commandID: 12))
        #expect(try await admin.expectClosed())
        #expect(await violations(fleet) == ["QID 0: 3 commands outstanding on a queue of 2 entries"])
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func aCIDStillOutstandingCannotBeReused() async throws {
        var config = MockNVMeConfig()
        config.faults.stallCommands = true
        let fleet = NVMeFleet(config: config)
        let (admin, _) = try await RawNVMeHost.up(fleet)
        try await admin.command(NVMeCommands.keepAlive(commandID: 10))
        try await admin.command(NVMeCommands.keepAlive(commandID: 10))
        #expect(try await admin.expectClosed())
        #expect(await violations(fleet).first?.contains("CID 10 submitted while") == true)
        await fleet.shutdown(expectingViolations: true)
    }

    // MARK: The data SGL

    /// An enabled controller with its I/O queue connected over `fleet`.
    private func ioQueue(_ fleet: NVMeFleet) async throws -> RawNVMeHost {
        let (_, cntlid) = try await RawNVMeHost.up(fleet)
        return try await RawNVMeHost.up(fleet, qid: 1, controllerID: cntlid).0
    }

    @Test func aReadSGLMustDescribeExactlyTheBlocksRead() async throws {
        let fleet = NVMeFleet()
        let io = try await ioQueue(fleet)
        var read = NVMeCommands.read(commandID: 20, nsid: 1, slba: 0, blocks: 2, blockSize: 4096)

        read.sgl = .transport(length: 4096)            // one block's worth for two
        try await io.command(read)
        #expect(status(try await io.completion(20).cqe) == (0, 0x0F, true))

        read.commandID = 21
        read.sgl = .inCapsule(length: 8192)            // in-capsule on a read: nvmet's Invalid Field
        try await io.command(read)
        #expect(status(try await io.completion(21).cqe) == (0, 0x02, true))

        read.commandID = 22
        read.sgl = SGLDescriptor(address: 0, length: 8192, typeByte: 0x00)   // a plain Data Block
        try await io.command(read)
        #expect(status(try await io.completion(22).cqe) == (0, 0x11, true))

        read.commandID = 23
        read.sgl = .transport(length: 8192)
        try await io.command(read)
        let served = try await io.completion(23)
        #expect(served.cqe.status.isSuccess)
        #expect(served.data.count == 8192)
        #expect(await violations(fleet).count == 3)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func aWriteSGLMustDescribeExactlyTheBlocksWritten() async throws {
        let fleet = NVMeFleet()
        let io = try await ioQueue(fleet)

        // Solicited: SGL length one block, NLB two.
        var write = NVMeCommands.write(commandID: 30, nsid: 1, slba: 0, blocks: 2, blockSize: 4096,
                                       fua: false, inCapsule: false)
        write.sgl = .transport(length: 4096)
        try await io.command(write)
        #expect(status(try await io.completion(30).cqe) == (0, 0x0F, true))

        // In-capsule: the SGL and the capsule disagree.
        write = NVMeCommands.write(commandID: 31, nsid: 1, slba: 0, blocks: 1, blockSize: 4096,
                                   fua: false, inCapsule: true)
        try await io.command(write, data: Data(count: 2048))
        #expect(status(try await io.completion(31).cqe) == (0, 0x0F, true))

        // In-capsule past IOCCSZ (16 KiB here): nvmet's SGL Offset Invalid.
        write = NVMeCommands.write(commandID: 32, nsid: 1, slba: 0, blocks: 8, blockSize: 4096,
                                   fua: false, inCapsule: true)
        try await io.command(write, data: Data(count: 32768))
        #expect(status(try await io.completion(32).cqe) == (0, 0x16, true))
        #expect(await violations(fleet).count == 3)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func anAdminTransferMustMatchItsCommand() async throws {
        let fleet = NVMeFleet()
        let (admin, _) = try await RawNVMeHost.up(fleet)
        var identify = NVMeCommands.identify(commandID: 40, cns: IdentifyCNS.controller)
        identify.sgl = .transport(length: 1024)
        try await admin.command(identify)
        #expect(status(try await admin.completion(40).cqe) == (0, 0x0F, true))
        await fleet.shutdown(expectingViolations: true)
    }

    // MARK: H2CData

    /// A two-block write solicited by one R2T for all 8 KiB; returns the TTAG.
    private func solicitedWrite(_ io: RawNVMeHost, cid: UInt16) async throws -> UInt16 {
        try await io.command(NVMeCommands.write(commandID: cid, nsid: 1, slba: 0, blocks: 2, blockSize: 4096,
                                                fua: false, inCapsule: false))
        guard case .r2t(let r2t) = try await io.next() else {
            throw RawNVMeHost.ScriptError.unexpected("no R2T")
        }
        #expect(r2t.cccid == cid && r2t.offset == 0 && r2t.length == 8192)
        return r2t.ttag
    }

    private func solicitingFleet() -> NVMeFleet {
        var config = MockNVMeConfig()
        config.inCapsuleDataBytes = 0
        return NVMeFleet(config: config)
    }

    private func expectTermination(_ io: RawNVMeHost, _ fes: NVMeTCPFatalErrorStatus) async throws {
        guard case .c2hTermReq(let term) = try await io.next() else {
            Issue.record("expected a C2HTermReq")
            return
        }
        #expect(term.fes == fes)
        #expect(try await io.expectClosed())
    }

    @Test func h2cDataThatSkipsAheadIsAPDUSequenceError() async throws {
        let fleet = solicitingFleet()
        let io = try await ioQueue(fleet)
        let ttag = try await solicitedWrite(io, cid: 50)
        try await io.send(H2CDataPDU(cccid: 50, ttag: ttag, dataOffset: 4096,
                                     data: Data(count: 4096), last: true).encode())
        try await expectTermination(io, .pduSequenceError)
        #expect(await violations(fleet).first?.contains("non-contiguous H2CData") == true)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func h2cDataThatRepeatsARangeIsAPDUSequenceError() async throws {
        let fleet = solicitingFleet()
        let io = try await ioQueue(fleet)
        let ttag = try await solicitedWrite(io, cid: 51)
        // The byte count comes out right — 8 KiB — but block 1 never arrives.
        try await io.sendTogether([
            H2CDataPDU(cccid: 51, ttag: ttag, dataOffset: 0, data: Data(count: 4096), last: false).encode(),
            H2CDataPDU(cccid: 51, ttag: ttag, dataOffset: 0, data: Data(count: 4096), last: true).encode(),
        ])
        try await expectTermination(io, .pduSequenceError)
        #expect(await fleet.disk.read(lba: 0, blocks: 2) == Data(count: 8192))
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func lastPDUBeforeTheR2TsEndIsAPDUSequenceError() async throws {
        let fleet = solicitingFleet()
        let io = try await ioQueue(fleet)
        let ttag = try await solicitedWrite(io, cid: 52)
        try await io.send(H2CDataPDU(cccid: 52, ttag: ttag, dataOffset: 0,
                                     data: Data(count: 4096), last: true).encode())
        try await expectTermination(io, .pduSequenceError)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func h2cDataPastTheR2TIsOutOfRange() async throws {
        let fleet = solicitingFleet()
        let io = try await ioQueue(fleet)
        let ttag = try await solicitedWrite(io, cid: 53)
        try await io.send(H2CDataPDU(cccid: 53, ttag: ttag, dataOffset: 0,
                                     data: Data(count: 12288), last: true).encode())
        try await expectTermination(io, .dataTransferOutOfRange)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func h2cDataWithTheWrongTTAGIsRefused() async throws {
        let fleet = solicitingFleet()
        let io = try await ioQueue(fleet)
        let ttag = try await solicitedWrite(io, cid: 54)
        try await io.send(H2CDataPDU(cccid: 54, ttag: ttag &+ 1, dataOffset: 0,
                                     data: Data(count: 8192), last: true).encode())
        try await expectTermination(io, .invalidPDUHeader)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func h2cDataLargerThanMAXH2CDATAIsRefused() async throws {
        var config = MockNVMeConfig()
        config.inCapsuleDataBytes = 0
        config.maxH2CData = 4096
        let fleet = NVMeFleet(config: config)
        let io = try await ioQueue(fleet)
        let ttag = try await solicitedWrite(io, cid: 55)
        try await io.send(H2CDataPDU(cccid: 55, ttag: ttag, dataOffset: 0,
                                     data: Data(count: 8192), last: true).encode())
        try await expectTermination(io, .dataTransferLimitExceeded)
        await fleet.shutdown(expectingViolations: true)
    }

    @Test func wellFormedH2CDataInTwoPDUsIsWritten() async throws {
        let fleet = solicitingFleet()
        let io = try await ioQueue(fleet)
        let ttag = try await solicitedWrite(io, cid: 56)
        let payload = Data((0 ..< 8192).map { UInt8($0 % 251) })
        try await io.sendTogether([
            H2CDataPDU(cccid: 56, ttag: ttag, dataOffset: 0, data: payload.prefix(4096), last: false).encode(),
            H2CDataPDU(cccid: 56, ttag: ttag, dataOffset: 4096, data: payload.suffix(4096), last: true).encode(),
        ])
        #expect(try await io.completion(56).cqe.status.isSuccess)
        #expect(await fleet.disk.read(lba: 0, blocks: 2) == payload)
        await fleet.shutdown()
    }
}
