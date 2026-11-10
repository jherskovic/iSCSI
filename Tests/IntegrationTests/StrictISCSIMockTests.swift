import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// The initiator side of a MemoryPipe speaking raw iSCSI, for the rules the
/// real initiator never breaks — the only way to show the mock refuses
/// them, and refuses them the way LIO does. The `ScriptedTarget` mirror.
///
/// @unchecked Sendable: each test drives it from one task at a time.
final class RawISCSIInitiator: @unchecked Sendable {
    enum ScriptError: Error { case unexpected(String) }

    let harness: TargetHarness
    private let serializer = PDUSerializer()
    private var deframer = PDUDeframer()
    /// The next CmdSN a non-immediate command takes.
    var cmdSN: UInt32 = 1
    private(set) var expStatSN: UInt32 = 0
    private var nextITT: UInt32 = 1

    init(config: MockTargetConfig = MockTargetConfig(), disk: RAMDisk? = nil) {
        harness = TargetHarness.start(config: config, disk: disk)
    }

    var target: MockTarget { harness.target }

    func send(_ pdu: some ProtocolDataUnit) async throws {
        try await harness.transport.send(serializer.serialize(pdu))
    }

    /// Next PDU from the target; nil on EOF. Bounded, so a script that
    /// never gets what it waits for fails rather than hangs.
    func next() async throws -> AnyPDU? {
        try await withDeadline(.seconds(5)) { [self] in
            while true {
                if let raw = try deframer.next() { return try AnyPDU.decode(raw) }
                guard let chunk = try await harness.transport.receive() else { return nil }
                deframer.append(chunk)
            }
        }
    }

    func expectClosed() async throws -> Bool {
        try await next() == nil
    }

    /// Security stage straight through with AuthMethod=None, then the
    /// operational stage with `keys`, into full-feature phase.
    func login(_ keys: [(String, String)]) async throws {
        var text = TextParameters()
        text.append("InitiatorName", "iqn.2026-08.com.example:raw")
        text.append("SessionType", "Normal")
        text.append("TargetName", MockTargetConfig().targetName)
        text.append("AuthMethod", "None")
        var req = LoginRequestPDU()
        req.transit = true
        req.currentStage = .securityNegotiation
        req.nextStage = .loginOperationalNegotiation
        req.cmdSN = cmdSN
        req.dataSegment = text.encode()
        try await send(req)
        guard case .loginResponse(let first) = try await next(), first.statusClass == 0 else {
            throw ScriptError.unexpected("security stage refused")
        }
        expStatSN = first.statSN &+ 1

        text = TextParameters()
        for (key, value) in keys { text.append(key, value) }
        req.currentStage = .loginOperationalNegotiation
        req.nextStage = .fullFeaturePhase
        req.expStatSN = expStatSN
        req.dataSegment = text.encode()
        try await send(req)
        guard case .loginResponse(let second) = try await next(), second.statusClass == 0,
              second.nextStage == .fullFeaturePhase else {
            throw ScriptError.unexpected("operational stage refused")
        }
        expStatSN = second.statSN &+ 1
    }

    /// RFC 7143 defaults except as `overrides` say: no digests, ERL 0.
    func login(initialR2T: Bool, immediateData: Bool, firstBurst: Int = 65536,
               maxBurst: Int = 262_144) async throws {
        try await login([
            ("HeaderDigest", "None"), ("DataDigest", "None"),
            ("MaxRecvDataSegmentLength", "262144"), ("ErrorRecoveryLevel", "0"),
            ("InitialR2T", initialR2T ? "Yes" : "No"), ("ImmediateData", immediateData ? "Yes" : "No"),
            ("FirstBurstLength", String(firstBurst)), ("MaxBurstLength", String(maxBurst)),
            ("MaxOutstandingR2T", "1"), ("DataPDUInOrder", "Yes"), ("DataSequenceInOrder", "Yes"),
        ])
    }

    /// A WRITE(16) of `blocks` 512-byte blocks at LBA 0. Returns its ITT.
    @discardableResult
    func write(blocks: UInt32, immediate: Data = Data(), final: Bool = true,
               cmdSN explicitCmdSN: UInt32? = nil) async throws -> UInt32 {
        let itt = nextITT
        nextITT &+= 1
        var command = SCSICommandPDU()
        command.write = true
        command.final = final
        command.initiatorTaskTag = itt
        command.cdb = CDB.write16(lba: 0, blocks: blocks)
        command.expectedDataTransferLength = blocks * 512
        command.cmdSN = explicitCmdSN ?? cmdSN
        if explicitCmdSN == nil { cmdSN &+= 1 }
        command.expStatSN = expStatSN
        command.dataSegment = immediate
        try await send(command)
        return itt
    }

    /// TEST UNIT READY with `sn` (default: the next CmdSN). Returns its ITT.
    @discardableResult
    func testUnitReady(cmdSN sn: UInt32? = nil) async throws -> UInt32 {
        let itt = nextITT
        nextITT &+= 1
        var command = SCSICommandPDU()
        command.initiatorTaskTag = itt
        command.cdb = CDB.testUnitReady()
        command.cmdSN = sn ?? cmdSN
        if sn == nil { cmdSN &+= 1 }
        command.expStatSN = expStatSN
        try await send(command)
        return itt
    }

    func dataOut(itt: UInt32, ttt: UInt32 = 0xFFFF_FFFF, dataSN: UInt32, offset: Int, bytes: Int,
                 final: Bool, fill: UInt8 = 0xA5) async throws {
        var out = DataOutPDU()
        out.initiatorTaskTag = itt
        out.targetTransferTag = ttt
        out.dataSN = dataSN
        out.bufferOffset = UInt32(offset)
        out.dataSegment = Data(repeating: fill, count: bytes)
        out.final = final
        out.expStatSN = expStatSN
        try await send(out)
    }

    func r2t() async throws -> R2TPDU {
        guard case .r2t(let r2t) = try await next() else { throw ScriptError.unexpected("no R2T") }
        return r2t
    }

    func response() async throws -> SCSIResponsePDU {
        guard case .scsiResponse(let resp) = try await next() else { throw ScriptError.unexpected("no SCSI response") }
        expStatSN = resp.statSN &+ 1
        return resp
    }

    func reject() async throws -> RejectPDU {
        guard case .reject(let reject) = try await next() else { throw ScriptError.unexpected("no Reject") }
        expStatSN = reject.statSN &+ 1
        return reject
    }

    func violations() async -> [String] {
        await target.protocolViolations
    }
}

/// The iSCSI mock holds the initiator to what login negotiated and refuses
/// the rest the way LIO does. Each test breaks one rule by hand; the
/// integration suites then rely on `TargetHarness.finish()` and
/// `TargetFleet.shutdown()` finding no violation from the real initiator.
@Suite("Strict iSCSI mock: what it refuses", .timeLimit(.minutes(1)))
struct StrictISCSIMockTests {
    // MARK: The command PDU — a Reject, as iscsit_setup_scsi_cmd answers

    @Test func immediateDataWithImmediateDataNoIsRejected() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false)
        try await raw.write(blocks: 1, immediate: Data(count: 512))
        #expect(try await raw.reject().reason == .protocolError)
        #expect(await raw.violations() == ["immediate data (512 bytes) with ImmediateData=No"])
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func immediateDataPastFirstBurstLengthIsRejected() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: false, immediateData: true, firstBurst: 4096)
        try await raw.write(blocks: 16, immediate: Data(count: 8192))
        #expect(try await raw.reject().reason == .protocolError)
        #expect(await raw.violations().first?.contains("past FirstBurstLength 4096") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func announcingUnsolicitedDataWhileInitialR2TIsYesIsRejected() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: true)
        try await raw.write(blocks: 4, immediate: Data(count: 512), final: false)
        #expect(try await raw.reject().reason == .protocolError)
        #expect(await raw.violations().first?.contains("while InitialR2T=Yes") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func aDataSegmentPastMaxRecvDataSegmentLengthDropsTheConnection() async throws {
        // 8 KiB is the mock's declared MRDSL. The deframer used to allow
        // 4 KiB more than that, so this 9 KiB segment went through.
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: false, immediateData: true)
        try await raw.write(blocks: 18, immediate: Data(count: 9216))
        #expect(try await raw.expectClosed())
        #expect(await raw.violations() == ["data segment of 9216 bytes, MaxRecvDataSegmentLength is 8192"])
        await raw.harness.finish(expectingViolations: true)
    }

    // MARK: Data-Out sequences — a dropped connection, as at ERL 0

    @Test func unsolicitedDataOutWhileInitialR2TIsYesDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false)
        let itt = try await raw.write(blocks: 4)
        let r2t = try await raw.r2t()                  // the target solicits it all
        #expect(r2t.bufferOffset == 0 && r2t.desiredDataTransferLength == 2048)
        try await raw.dataOut(itt: itt, dataSN: 0, offset: 0, bytes: 2048, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations() == ["ITT \(itt): unsolicited Data-Out while InitialR2T=Yes"])
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func unsolicitedDataPastFirstBurstLengthDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: false, immediateData: true, firstBurst: 4096)
        let itt = try await raw.write(blocks: 32, immediate: Data(count: 2048), final: false)
        try await raw.dataOut(itt: itt, dataSN: 0, offset: 2048, bytes: 4096, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations().first?.contains("past the first burst's 4096") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func endingTheFirstBurstEarlyDropsTheConnection() async throws {
        // LIO: unsolicited data must run to min(FirstBurstLength, EDTL).
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: false, immediateData: true, firstBurst: 4096)
        let itt = try await raw.write(blocks: 32, immediate: Data(count: 1024), final: false)
        try await raw.dataOut(itt: itt, dataSN: 0, offset: 1024, bytes: 1024, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations().first?.contains("F bit at 2048, before the sequence's end 4096") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    /// The bug the old `received = max(received, offset + count)` let
    /// through: the byte count comes out right, block 1 never arrives.
    @Test func aDataOutThatRepeatsARangeDropsTheConnection() async throws {
        let disk = RAMDisk()
        let raw = RawISCSIInitiator(disk: disk)
        try await raw.login(initialR2T: true, immediateData: false)
        let itt = try await raw.write(blocks: 2)
        let r2t = try await raw.r2t()
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 0, offset: 0, bytes: 512, final: false)
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 1, offset: 0, bytes: 512, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations() == ["ITT \(itt): Data-Out at offset 0, expected 512"])
        #expect(await disk.read(lba: 0, blocks: 2) == Data(count: 1024))
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func aDataOutThatSkipsARangeDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false)
        let itt = try await raw.write(blocks: 2)
        let r2t = try await raw.r2t()
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 0, offset: 512, bytes: 512, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations() == ["ITT \(itt): Data-Out at offset 512, expected 0"])
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func aDataOutPastTheR2TsDesiredLengthDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false, firstBurst: 4096, maxBurst: 4096)
        let itt = try await raw.write(blocks: 16)
        let r2t = try await raw.r2t()
        #expect(r2t.desiredDataTransferLength == 4096)     // MaxBurstLength
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 0, offset: 0, bytes: 8192, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations().first?.contains("past the R2T's desired length") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func aDataOutWithTheWrongTTTDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false)
        let itt = try await raw.write(blocks: 1)
        let r2t = try await raw.r2t()
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag &+ 1, dataSN: 0, offset: 0, bytes: 512, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations().first?.contains("Data-Out with TTT") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func aDataOutWithTheWrongDataSNDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false)
        let itt = try await raw.write(blocks: 2)
        let r2t = try await raw.r2t()
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 0, offset: 0, bytes: 512, final: false)
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 2, offset: 512, bytes: 512, final: true)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations() == ["ITT \(itt): Data-Out DataSN 2, expected 1"])
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func aSequenceCompleteWithoutTheFBitDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false)
        let itt = try await raw.write(blocks: 1)
        let r2t = try await raw.r2t()
        try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 0, offset: 0, bytes: 512, final: false)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations().first?.contains("without the F bit") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func dataOutForAnUnknownTaskIsDumpedNotAnswered() async throws {
        // What a task aborted with its data in flight looks like: LIO drops
        // the payload and carries on.
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: false)
        try await raw.dataOut(itt: 0x7777, ttt: 0x1234, dataSN: 0, offset: 0, bytes: 512, final: true)
        let itt = try await raw.testUnitReady()
        let resp = try await raw.response()
        #expect(resp.initiatorTaskTag == itt && resp.status == 0)
        await raw.harness.finish()
    }

    /// Immediate data, an unsolicited burst to FirstBurstLength, then R2Ts
    /// for the rest at MaxBurstLength each — every rule followed.
    @Test func aWriteThatFollowsEveryRuleLandsWhole() async throws {
        let disk = RAMDisk()
        let raw = RawISCSIInitiator(disk: disk)
        try await raw.login(initialR2T: false, immediateData: true, firstBurst: 4096, maxBurst: 8192)
        let itt = try await raw.write(blocks: 32, immediate: Data(repeating: 0xA5, count: 1024), final: false)
        try await raw.dataOut(itt: itt, dataSN: 0, offset: 1024, bytes: 2048, final: false)
        try await raw.dataOut(itt: itt, dataSN: 1, offset: 3072, bytes: 1024, final: true)
        var offset = 4096
        var r2tSN: UInt32 = 0
        while offset < 16384 {
            let r2t = try await raw.r2t()
            #expect(r2t.r2tSN == r2tSN && Int(r2t.bufferOffset) == offset)
            let length = Int(r2t.desiredDataTransferLength)
            #expect(length == min(8192, 16384 - offset))
            try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 0, offset: offset,
                                  bytes: length / 2, final: false)
            try await raw.dataOut(itt: itt, ttt: r2t.targetTransferTag, dataSN: 1, offset: offset + length / 2,
                                  bytes: length / 2, final: true)
            offset += length
            r2tSN += 1
        }
        let resp = try await raw.response()
        #expect(resp.initiatorTaskTag == itt && resp.status == 0)
        #expect(await disk.read(lba: 0, blocks: 32) == Data(repeating: 0xA5, count: 16384))
        await raw.harness.finish()
    }

    // MARK: The command window

    @Test func aCmdSNPastMaxCmdSNDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: true)
        try await raw.testUnitReady(cmdSN: raw.cmdSN &+ 32)      // window is 32 wide
        #expect(try await raw.expectClosed())
        #expect(await raw.violations().first?.contains("outside the window") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    @Test func aRepeatedCmdSNDropsTheConnection() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: true)
        let sn = raw.cmdSN
        try await raw.testUnitReady()
        _ = try await raw.response()
        try await raw.testUnitReady(cmdSN: sn)
        #expect(try await raw.expectClosed())
        #expect(await raw.violations().first?.contains("CmdSN \(sn) outside the window") == true)
        await raw.harness.finish(expectingViolations: true)
    }

    /// A command ahead of a hole is served, but ExpCmdSN stays at the hole,
    /// and so does the window, until the missing one arrives.
    @Test func aCmdSNGapHoldsTheWindowUntilItFills() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: true)
        let hole = raw.cmdSN
        try await raw.testUnitReady(cmdSN: hole &+ 1)
        let ahead = try await raw.response()
        #expect(ahead.expCmdSN == hole)
        #expect(ahead.maxCmdSN == hole &+ 31)
        try await raw.testUnitReady(cmdSN: hole)
        let filled = try await raw.response()
        #expect(filled.expCmdSN == hole &+ 2)
        await raw.harness.target.stop()
        await raw.harness.finish()
    }

    @Test func aCmdSNGapThatNeverFillsIsRecorded() async throws {
        let raw = RawISCSIInitiator()
        try await raw.login(initialR2T: true, immediateData: true)
        let hole = raw.cmdSN
        try await raw.testUnitReady(cmdSN: hole &+ 1)
        _ = try await raw.response()
        await raw.harness.transport.close()
        #expect(await eventually { await raw.violations() == ["CmdSN \(hole) never arrived; received past it: \(hole &+ 1)"] })
        await raw.harness.finish(expectingViolations: true)
    }
}
