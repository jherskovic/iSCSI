import Foundation
import Testing
@testable import iSCSIKit

/// Target side of a MemoryPipe speaking raw PDUs, for wire-level compliance
/// scripts that MockTarget's fault switches can't express. Performs a minimal
/// conforming no-auth login and then lets each test drive PDUs by hand.
///
/// @unchecked Sendable: each test drives it from one task at a time; the only
/// concurrency is withDeadline's abandoned loser after a timeout, at which
/// point the test has already failed.
final class ScriptedTarget: @unchecked Sendable {
    enum ScriptError: Error { case unexpectedPDU(String), closed }

    let pipe: MemoryPipe
    private let serializer = PDUSerializer()
    private var deframer = PDUDeframer()
    private(set) var statSN: UInt32 = 0x100
    private(set) var expCmdSN: UInt32 = 0
    private(set) var maxCmdSN: UInt32 = 0

    init(pipe: MemoryPipe) {
        self.pipe = pipe
    }

    /// Bounded so a script that never receives what it expects fails the
    /// test instead of hanging it.
    func nextPDU() async throws -> AnyPDU {
        try await withDeadline(.seconds(5)) { [self] in
            while true {
                if let raw = try deframer.next() { return try AnyPDU.decode(raw) }
                guard let chunk = try await pipe.receive() else { throw ScriptError.closed }
                deframer.append(chunk)
            }
        }
    }

    func send(_ pdu: some ProtocolDataUnit) async throws {
        try await pipe.send(serializer.serialize(pdu.encode()))
    }

    /// Current StatSN, advancing it (for status-bearing PDUs).
    func takeStatSN() -> UInt32 {
        defer { statSN &+= 1 }
        return statSN
    }

    /// Minimal conforming login: security-stage transit, then straight to
    /// full-feature phase with every operational key left at its RFC default
    /// (target MRDSL 8192, MaxBurstLength 262144, InitialR2T=Yes).
    func performLogin() async throws {
        guard case .loginRequest(let req1) = try await nextPDU() else {
            throw ScriptError.unexpectedPDU("expected first login request")
        }
        expCmdSN = req1.cmdSN
        maxCmdSN = req1.cmdSN &+ 100
        var r1 = LoginResponsePDU()
        r1.transit = true
        r1.currentStage = .securityNegotiation
        r1.nextStage = .loginOperationalNegotiation
        r1.isid = req1.isid
        r1.tsih = 1
        r1.statSN = takeStatSN()
        r1.expCmdSN = expCmdSN
        r1.maxCmdSN = maxCmdSN
        try await send(r1)

        guard case .loginRequest(let req2) = try await nextPDU() else {
            throw ScriptError.unexpectedPDU("expected operational login request")
        }
        var r2 = LoginResponsePDU()
        r2.transit = true
        r2.currentStage = .loginOperationalNegotiation
        r2.nextStage = .fullFeaturePhase
        r2.isid = req2.isid
        r2.tsih = 1
        r2.statSN = takeStatSN()
        r2.expCmdSN = expCmdSN
        r2.maxCmdSN = maxCmdSN
        try await send(r2)
    }

    /// Serve one initiator ping: NOP-Out in, echo NOP-In out.
    func servePing() async throws {
        guard case .nopOut(let nop) = try await nextPDU() else {
            throw ScriptError.unexpectedPDU("expected NOP-Out ping")
        }
        var echo = NopInPDU()
        echo.initiatorTaskTag = nop.initiatorTaskTag
        echo.targetTransferTag = 0xFFFF_FFFF
        echo.statSN = takeStatSN()
        echo.expCmdSN = expCmdSN
        echo.maxCmdSN = maxCmdSN
        echo.dataSegment = nop.dataSegment
        try await send(echo)
    }

    func goodResponse(itt: UInt32) -> SCSIResponsePDU {
        var resp = SCSIResponsePDU()
        resp.response = .commandCompleted
        resp.status = 0x00
        resp.initiatorTaskTag = itt
        resp.statSN = takeStatSN()
        resp.expCmdSN = expCmdSN
        resp.maxCmdSN = maxCmdSN
        return resp
    }
}

private func scriptedSession(
    tune: (inout LoginConfig) -> Void = { _ in }
) async throws -> (ISCSIConnection, ScriptedTarget) {
    let (initiatorSide, targetSide) = MemoryPipe.pair()
    let script = ScriptedTarget(pipe: targetSide)
    var config = LoginConfig(
        initiatorName: "iqn.2026-08.me.herko:test",
        sessionType: .normal,
        targetName: "iqn.2026-08.test.example:disk0"
    )
    config.desired.offerDigests = false
    tune(&config)
    let connection = ISCSIConnection(transport: initiatorSide, login: config)
    async let loginResult = connection.login()
    try await script.performLogin()
    _ = try await loginResult
    return (connection, script)
}

@Suite("Wire compliance", .timeLimit(.minutes(1)))
struct WireComplianceTests {
    // MARK: NOP rules

    /// §11.19.1: a NOP-In with both tags reserved is a legal window update;
    /// it must not tear the connection down, and it must not advance StatSN.
    @Test func windowUpdateNopInIsAccepted() async throws {
        let (connection, script) = try await scriptedSession()
        var update = NopInPDU()
        update.initiatorTaskTag = 0xFFFF_FFFF
        update.targetTransferTag = 0xFFFF_FFFF
        update.statSN = script.statSN // next StatSN, not advanced
        update.expCmdSN = script.expCmdSN
        update.maxCmdSN = script.maxCmdSN &+ 8
        try await script.send(update)

        async let ping: Void = connection.ping()
        try await script.servePing()
        try await ping
        await connection.close()
    }

    /// §11.7.1: DataSegmentLength must not exceed the MRDSL for the direction
    /// sent — the echo of a target ping is clipped to the target's MRDSL.
    @Test func nopEchoClippedToTargetMRDSL() async throws {
        let (connection, script) = try await scriptedSession()
        var pingIn = NopInPDU()
        pingIn.initiatorTaskTag = 0xFFFF_FFFF
        pingIn.targetTransferTag = 7
        pingIn.lun = 2 << 48
        pingIn.statSN = script.statSN
        pingIn.expCmdSN = script.expCmdSN
        pingIn.maxCmdSN = script.maxCmdSN
        pingIn.dataSegment = Data(repeating: 0xAB, count: 9000)
        try await script.send(pingIn)

        guard case .nopOut(let reply) = try await script.nextPDU() else {
            Issue.record("expected NOP-Out reply")
            return
        }
        #expect(reply.targetTransferTag == 7)
        #expect(reply.lun == 2 << 48)
        #expect(reply.dataSegment.count == 8192) // default target MRDSL
        await connection.close()
    }

    // MARK: Text negotiation

    /// §11.10.4/§6.2: a Text Response with F=0 (C=0) continues the exchange —
    /// the initiator answers with an empty F=1 request copying TTT and LUN,
    /// and the reassembled text spans all parts.
    @Test func multiPDUTextResponseIsReassembled() async throws {
        let (connection, script) = try await scriptedSession()
        async let exchange = connection.textExchange(
            TextParameters([(key: "SendTargets", value: "All")]))

        guard case .textRequest(let req) = try await script.nextPDU() else {
            Issue.record("expected text request")
            return
        }
        #expect(req.final)

        var part1 = TextResponsePDU()
        part1.final = false
        part1.initiatorTaskTag = req.initiatorTaskTag
        part1.targetTransferTag = 0x1234
        part1.lun = 3 << 48
        part1.statSN = script.takeStatSN()
        part1.expCmdSN = script.expCmdSN
        part1.maxCmdSN = script.maxCmdSN
        part1.dataSegment = TextParameters(
            [(key: "TargetName", value: "iqn.2026-08.test.example:disk0")]).encode()
        try await script.send(part1)

        guard case .textRequest(let cont) = try await script.nextPDU() else {
            Issue.record("expected continuation text request")
            return
        }
        #expect(cont.final)
        #expect(cont.dataSegment.isEmpty)
        #expect(cont.initiatorTaskTag == req.initiatorTaskTag)
        #expect(cont.targetTransferTag == 0x1234)
        #expect(cont.lun == 3 << 48)

        var part2 = TextResponsePDU()
        part2.final = true
        part2.initiatorTaskTag = req.initiatorTaskTag
        part2.targetTransferTag = 0xFFFF_FFFF
        part2.statSN = script.takeStatSN()
        part2.expCmdSN = script.expCmdSN
        part2.maxCmdSN = script.maxCmdSN
        part2.dataSegment = TextParameters(
            [(key: "TargetAddress", value: "10.0.0.9:3260,1")]).encode()
        try await script.send(part2)

        let result = try await exchange
        #expect(result["TargetName"] == "iqn.2026-08.test.example:disk0")
        #expect(result["TargetAddress"] == "10.0.0.9:3260,1")
        await connection.close()
    }

    // MARK: ITT lifecycle

    /// §11.17.1: a task terminated by Reject is followed by a CHECK CONDITION
    /// SCSI Response for the same ITT; the late response must be absorbed,
    /// not treated as an unknown-ITT protocol error.
    @Test func rejectedTaskToleratesFollowupResponse() async throws {
        let (connection, script) = try await scriptedSession()
        let task = Task { try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady())) }

        guard case .scsiCommand(let cmd) = try await script.nextPDU() else {
            Issue.record("expected SCSI command")
            return
        }
        var reject = RejectPDU()
        reject.reason = .invalidPDUField
        reject.statSN = script.takeStatSN()
        reject.expCmdSN = script.expCmdSN
        reject.maxCmdSN = script.maxCmdSN
        reject.dataSegment = cmd.encode().bhs
        try await script.send(reject)

        await #expect(throws: ConnectionError.self) { _ = try await task.value }

        // The follow-up CHECK CONDITION for the rejected task (§11.17.1).
        var late = script.goodResponse(itt: cmd.initiatorTaskTag)
        late.status = 0x02
        try await script.send(late)

        async let ping: Void = connection.ping()
        try await script.servePing()
        try await ping
        await connection.close()
    }

    /// A ping cancelled locally has still been sent; the echo that arrives
    /// afterwards is a conforming PDU and must not kill the connection.
    @Test func cancelledPingToleratesLateEcho() async throws {
        let (connection, script) = try await scriptedSession()
        let pingTask = Task { try await connection.ping() }

        guard case .nopOut(let nop) = try await script.nextPDU() else {
            Issue.record("expected NOP-Out")
            return
        }
        pingTask.cancel()
        _ = await pingTask.result

        var echo = NopInPDU()
        echo.initiatorTaskTag = nop.initiatorTaskTag
        echo.targetTransferTag = 0xFFFF_FFFF
        echo.statSN = script.takeStatSN()
        echo.expCmdSN = script.expCmdSN
        echo.maxCmdSN = script.maxCmdSN
        try await script.send(echo)

        async let ping: Void = connection.ping()
        try await script.servePing()
        try await ping
        await connection.close()
    }

    /// §11.5: after ABORT TASK is issued the target may still deliver the
    /// task's response; §11.5.5: the abort must carry the aborted command's
    /// CmdSN as RefCmdSN.
    @Test func cancelledTaskAbortsWithRefCmdSNAndToleratesLateResponse() async throws {
        let (connection, script) = try await scriptedSession()
        let read = Task {
            try await connection.execute(SCSITask(
                lun: 0, cdb: CDB.read16(lba: 0, blocks: 2),
                direction: .read(expectedLength: 1024)))
        }
        guard case .scsiCommand(let cmd) = try await script.nextPDU() else {
            Issue.record("expected SCSI command")
            return
        }
        read.cancel()
        _ = await read.result

        guard case .tmfRequest(let tmf) = try await script.nextPDU() else {
            Issue.record("expected ABORT TASK")
            return
        }
        #expect(tmf.function == .abortTask)
        #expect(tmf.referencedTaskTag == cmd.initiatorTaskTag)
        #expect(tmf.refCmdSN == cmd.cmdSN)

        // Target completes the original task before answering the abort.
        try await script.send(script.goodResponse(itt: cmd.initiatorTaskTag))
        var tmfResp = TMFResponsePDU()
        tmfResp.response = .taskDoesNotExist
        tmfResp.initiatorTaskTag = tmf.initiatorTaskTag
        tmfResp.statSN = script.takeStatSN()
        tmfResp.expCmdSN = script.expCmdSN
        tmfResp.maxCmdSN = script.maxCmdSN
        try await script.send(tmfResp)

        async let ping: Void = connection.ping()
        try await script.servePing()
        try await ping
        await connection.close()
    }

    /// §11.5.5 via the public TMF API: an ABORT TASK for a still-outstanding
    /// command must carry that command's CmdSN as RefCmdSN even when the
    /// caller could not know it.
    @Test func explicitAbortResolvesRefCmdSN() async throws {
        let (connection, script) = try await scriptedSession()
        let read = Task {
            try await connection.execute(SCSITask(
                lun: 0, cdb: CDB.read16(lba: 0, blocks: 2),
                direction: .read(expectedLength: 1024)))
        }
        guard case .scsiCommand(let cmd) = try await script.nextPDU() else {
            Issue.record("expected SCSI command")
            return
        }
        let abort = Task {
            try await connection.taskManagement(
                .abortTask, lun: 0, referencedTaskTag: cmd.initiatorTaskTag)
        }
        guard case .tmfRequest(let tmf) = try await script.nextPDU() else {
            Issue.record("expected ABORT TASK")
            return
        }
        #expect(tmf.refCmdSN == cmd.cmdSN)

        var tmfResp = TMFResponsePDU()
        tmfResp.response = .functionComplete
        tmfResp.initiatorTaskTag = tmf.initiatorTaskTag
        tmfResp.statSN = script.takeStatSN()
        tmfResp.expCmdSN = script.expCmdSN
        tmfResp.maxCmdSN = script.maxCmdSN
        try await script.send(tmfResp)
        _ = try? await abort.value
        await connection.close()
        _ = await read.result
    }

    // MARK: Async logout

    /// §11.9.1 event 1: "The initiator MUST honor this request by issuing a
    /// Logout" — not by silently dropping the TCP connection.
    @Test func asyncLogoutRequestAnsweredWithLogout() async throws {
        let (connection, script) = try await scriptedSession()
        var async1 = AsyncMessagePDU()
        async1.event = .logoutRequest
        async1.parameter3 = 10
        async1.statSN = script.takeStatSN()
        async1.expCmdSN = script.expCmdSN
        async1.maxCmdSN = script.maxCmdSN
        try await script.send(async1)

        guard case .logoutRequest(let logout) = try await script.nextPDU() else {
            Issue.record("expected Logout Request after async logout demand")
            return
        }
        var resp = LogoutResponsePDU()
        resp.response = .success
        resp.initiatorTaskTag = logout.initiatorTaskTag
        resp.statSN = script.takeStatSN()
        resp.expCmdSN = script.expCmdSN
        resp.maxCmdSN = script.maxCmdSN
        try await script.send(resp)

        let reason = await connection.waitClosed()
        guard case .targetRequestedLogout = reason else {
            Issue.record("closed with \(reason), expected targetRequestedLogout")
            return
        }
    }

    // MARK: Data transfer limits

    /// §11.8/§13.12: an R2T must not request more than MaxBurstLength, and
    /// honoring one would make the initiator violate its own send-side MUST.
    @Test func oversizedR2TIsRejected() async throws {
        let (connection, script) = try await scriptedSession()
        let payload = Data(repeating: 0x55, count: 300_000)
        let task = Task { try await connection.execute(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 0, blocks: 586),
            direction: .write(payload))) }

        guard case .scsiCommand(let cmd) = try await script.nextPDU() else {
            Issue.record("expected SCSI command")
            return
        }
        var r2t = R2TPDU()
        r2t.initiatorTaskTag = cmd.initiatorTaskTag
        r2t.targetTransferTag = 1
        r2t.statSN = script.statSN
        r2t.expCmdSN = script.expCmdSN
        r2t.maxCmdSN = script.maxCmdSN
        r2t.r2tSN = 0
        r2t.bufferOffset = UInt32(cmd.dataSegment.count)
        r2t.desiredDataTransferLength = 262_145 // MaxBurstLength default + 1
        try await script.send(r2t)

        await #expect(throws: (any Error).self) {
            _ = try await withDeadline(.seconds(5)) { try await task.value }
        }
        // No Data-Out may be sent for that R2T; the connection goes down.
        await #expect(throws: (any Error).self) {
            while true {
                if case .scsiDataOut = try await script.nextPDU() {
                    Issue.record("initiator honored an oversized R2T")
                    break
                }
            }
        }
    }

    /// A target that skips a chunk of read data and still returns GOOD must
    /// not produce a silently zero-filled buffer.
    @Test func dataInGapIsDetected() async throws {
        let (connection, script) = try await scriptedSession()
        let task = Task { try await connection.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 0, blocks: 6),
            direction: .read(expectedLength: 3072))) }

        guard case .scsiCommand(let cmd) = try await script.nextPDU() else {
            Issue.record("expected SCSI command")
            return
        }
        for (sn, offset) in [(UInt32(0), UInt32(0)), (1, 2048)] { // 1024..2047 missing
            var dataIn = DataInPDU()
            dataIn.final = sn == 1
            dataIn.initiatorTaskTag = cmd.initiatorTaskTag
            dataIn.dataSN = sn
            dataIn.bufferOffset = offset
            dataIn.dataSegment = Data(repeating: 0x11, count: 1024)
            dataIn.expCmdSN = script.expCmdSN
            dataIn.maxCmdSN = script.maxCmdSN
            try await script.send(dataIn)
        }
        try await script.send(script.goodResponse(itt: cmd.initiatorTaskTag))

        await #expect(throws: ConnectionError.self) { _ = try await task.value }
    }

    /// §11.7.6: Data-In DataSN numbering is sequential for the task; a target
    /// jumping ahead has lost a PDU it will never resend at ERL0.
    @Test func outOfOrderDataSNIsRejected() async throws {
        let (connection, script) = try await scriptedSession()
        let task = Task { try await connection.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 0, blocks: 2),
            direction: .read(expectedLength: 1024))) }

        guard case .scsiCommand(let cmd) = try await script.nextPDU() else {
            Issue.record("expected SCSI command")
            return
        }
        var dataIn = DataInPDU()
        dataIn.final = true
        dataIn.initiatorTaskTag = cmd.initiatorTaskTag
        dataIn.dataSN = 1 // must start at 0
        dataIn.bufferOffset = 0
        dataIn.dataSegment = Data(repeating: 0x22, count: 1024)
        dataIn.expCmdSN = script.expCmdSN
        dataIn.maxCmdSN = script.maxCmdSN
        try await script.send(dataIn)

        // Bounded: before the fix nothing ever completed this task.
        await #expect(throws: ConnectionError.self) {
            _ = try await withDeadline(.seconds(5)) { try await task.value }
        }
    }

    /// §11.7.5: the O (overflow) residual bits are valid on a Data-In with
    /// the S bit and must survive into the task result.
    @Test func phaseCollapsedOverflowResidualSurfaces() async throws {
        let (connection, script) = try await scriptedSession()
        async let result = connection.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 0, blocks: 2),
            direction: .read(expectedLength: 1024)))

        guard case .scsiCommand(let cmd) = try await script.nextPDU() else {
            Issue.record("expected SCSI command")
            return
        }
        var dataIn = DataInPDU()
        dataIn.final = true
        dataIn.statusPresent = true
        dataIn.status = 0x00
        dataIn.residualOverflow = true
        dataIn.residualCount = 512
        dataIn.initiatorTaskTag = cmd.initiatorTaskTag
        dataIn.dataSN = 0
        dataIn.bufferOffset = 0
        dataIn.dataSegment = Data(repeating: 0x33, count: 1024)
        dataIn.statSN = script.takeStatSN()
        dataIn.expCmdSN = script.expCmdSN
        dataIn.maxCmdSN = script.maxCmdSN
        try await script.send(dataIn)

        let outcome = try await result
        #expect(outcome.residualIsOverflow)
        #expect(outcome.residualCount == 512)
        #expect(outcome.data.count == 1024)
        await connection.close()
    }
}
