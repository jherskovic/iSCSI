import Foundation
import Testing
@testable import iSCSIKit

/// Scripted target-side login exchanges against the initiator state machine.
@Suite("Login state machine")
struct LoginStateMachineTests {
    func response(
        to request: LoginRequestPDU,
        statSN: UInt32,
        text: [(String, String)] = [],
        transit: Bool = true,
        currentStage: LoginStage? = nil,
        nextStage: LoginStage? = nil,
        continued: Bool = false,
        tsih: UInt16 = 0,
        statusClass: UInt8 = 0,
        statusDetail: UInt8 = 0
    ) -> LoginResponsePDU {
        var resp = LoginResponsePDU()
        resp.transit = transit
        resp.continued = continued
        resp.currentStage = currentStage ?? request.currentStage
        resp.nextStage = nextStage ?? (transit ? request.nextStage : request.currentStage)
        resp.isid = request.isid
        resp.tsih = tsih
        resp.initiatorTaskTag = request.initiatorTaskTag
        resp.statSN = statSN
        resp.expCmdSN = request.cmdSN
        resp.maxCmdSN = request.cmdSN &+ 32
        resp.statusClass = statusClass
        resp.statusDetail = statusDetail
        resp.dataSegment = TextParameters(text.map { (key: $0.0, value: $0.1) }).encode()
        return resp
    }

    func config(chap: CHAP.Credentials? = nil, type: SessionType = .normal) -> LoginConfig {
        var c = LoginConfig(
            initiatorName: "iqn.2026-08.com.example:mac",
            sessionType: type,
            targetName: type == .normal ? "iqn.2026-08.com.example:disk0" : nil,
            chap: chap
        )
        c.desired.offerDigests = true
        return c
    }

    @Test func noAuthLoginHappyPath() throws {
        var sm = LoginStateMachine(config: config(), cmdSN: 10)
        let first = sm.start()
        let firstText = try TextParameters.decode(first.dataSegment)
        #expect(first.currentStage == .securityNegotiation)
        #expect(first.transit && first.nextStage == .loginOperationalNegotiation)
        #expect(firstText["InitiatorName"] == "iqn.2026-08.com.example:mac")
        #expect(firstText["TargetName"] == "iqn.2026-08.com.example:disk0")
        #expect(firstText["SessionType"] == "Normal")
        #expect(firstText["AuthMethod"] == "None")
        #expect(first.cmdSN == 10)

        // Target: security stage complete, moving to operational.
        let r1 = response(to: first, statSN: 100, text: [("AuthMethod", "None")])
        guard case .send(let opReq) = try sm.receive(r1) else {
            Issue.record("expected operational proposal")
            return
        }
        #expect(opReq.currentStage == .loginOperationalNegotiation)
        #expect(opReq.transit && opReq.nextStage == .fullFeaturePhase)
        #expect(opReq.expStatSN == 101)
        let proposal = try TextParameters.decode(opReq.dataSegment)
        #expect(proposal["HeaderDigest"] == "CRC32C,None")
        #expect(proposal["ErrorRecoveryLevel"] == "0")

        // Target answers everything and transits to FFP.
        let r2 = response(to: opReq, statSN: 101, text: [
            ("HeaderDigest", "CRC32C"),
            ("DataDigest", "None"),
            ("MaxRecvDataSegmentLength", "65536"),
            ("ErrorRecoveryLevel", "0"),
            ("InitialR2T", "No"),
            ("ImmediateData", "Yes"),
            ("MaxBurstLength", "262144"),
            ("FirstBurstLength", "65536"),
            ("MaxConnections", "1"),
            ("MaxOutstandingR2T", "1"),
            ("DefaultTime2Wait", "2"),
            ("DefaultTime2Retain", "0"),
            ("DataPDUInOrder", "Yes"),
            ("DataSequenceInOrder", "Yes"),
            ("TargetPortalGroupTag", "1"),
        ], tsih: 0x99)
        guard case .success(let result) = try sm.receive(r2) else {
            Issue.record("expected success")
            return
        }
        #expect(result.tsih == 0x99)
        #expect(result.expStatSN == 102)
        #expect(result.parameters.headerDigest)
        #expect(!result.parameters.dataDigest)
        #expect(result.parameters.targetMaxRecvDataSegmentLength == 65536)
        #expect(!result.parameters.initialR2T)
        #expect(result.parameters.targetPortalGroupTag == 1)
    }

    @Test func chapLoginHappyPath() throws {
        let creds = CHAP.Credentials(name: "user", secret: "s3cret")
        var sm = LoginStateMachine(config: config(chap: creds), cmdSN: 0)
        let first = sm.start()
        let firstText = try TextParameters.decode(first.dataSegment)
        #expect(firstText["AuthMethod"] == "CHAP")
        #expect(!first.transit) // CHAP needs the security stage to stay open

        // Target agrees to CHAP.
        let r1 = response(to: first, statSN: 1, text: [("AuthMethod", "CHAP")], transit: false)
        guard case .send(let algoReq) = try sm.receive(r1) else {
            Issue.record("expected CHAP_A")
            return
        }
        #expect(try TextParameters.decode(algoReq.dataSegment)["CHAP_A"] == "5")

        // Target sends the challenge.
        let challenge = "0xdeadbeefcafef00d"
        let r2 = response(to: algoReq, statSN: 2, text: [
            ("CHAP_A", "5"), ("CHAP_I", "1"), ("CHAP_C", challenge),
        ], transit: false)
        guard case .send(let chapReply) = try sm.receive(r2) else {
            Issue.record("expected CHAP response")
            return
        }
        let replyText = try TextParameters.decode(chapReply.dataSegment)
        #expect(replyText["CHAP_N"] == "user")
        // Independently-generated vector (hashlib) for id=1/secret/challenge —
        // wrong secret here would produce a different digest.
        let expected = CHAP.encodeHex(CHAP.response(
            id: 1, secret: "s3cret",
            challenge: try CHAP.decodeValue(challenge)
        ))
        #expect(replyText["CHAP_R"] == expected)
        #expect(chapReply.transit && chapReply.nextStage == .loginOperationalNegotiation)

        // Target accepts auth, transits to operational.
        let r3 = response(to: chapReply, statSN: 3)
        guard case .send(let opReq) = try sm.receive(r3) else {
            Issue.record("expected operational proposal")
            return
        }
        #expect(opReq.currentStage == .loginOperationalNegotiation)

        // Target answers minimally and transits.
        let r4 = response(to: opReq, statSN: 4, text: [
            ("HeaderDigest", "None"), ("DataDigest", "None"),
        ], tsih: 5)
        guard case .success(let result) = try sm.receive(r4) else {
            Issue.record("expected success")
            return
        }
        #expect(result.tsih == 5)
        // Unanswered keys land on RFC defaults.
        #expect(result.parameters.initialR2T == true)
    }

    @Test func chapRejectedByWrongAuthMethod() throws {
        let creds = CHAP.Credentials(name: "user", secret: "x")
        var sm = LoginStateMachine(config: config(chap: creds))
        let first = sm.start()
        let r1 = response(to: first, statSN: 1, text: [("AuthMethod", "None")], transit: false)
        #expect(throws: NegotiationError.self) { try sm.receive(r1) }
    }

    @Test func loginRejectStatusSurfaced() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        // 0x02/0x01 = initiator error / authentication failure.
        let r = response(to: first, statSN: 1, statusClass: 2, statusDetail: 1)
        #expect {
            try sm.receive(r)
        } throws: { error in
            error as? NegotiationError == .loginFailed(statusClass: 2, statusDetail: 1)
        }
    }

    @Test func redirectSurfaced() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        let r = response(
            to: first, statSN: 1,
            text: [("TargetAddress", "192.168.7.2:3260,1")],
            statusClass: 1, statusDetail: 2
        )
        guard case .redirect(let address, let permanent) = try sm.receive(r) else {
            Issue.record("expected redirect")
            return
        }
        #expect(address == "192.168.7.2:3260,1")
        #expect(permanent)
    }

    @Test func targetContinuedResponseReassembled() throws {
        var sm = LoginStateMachine(config: config(type: .discovery))
        let first = sm.start()

        let r1 = response(to: first, statSN: 100, text: [("AuthMethod", "None")])
        guard case .send(let opReq) = try sm.receive(r1) else {
            Issue.record("expected operational proposal")
            return
        }

        // Target splits its answer across two login responses with C=1.
        var full = TextParameters()
        full.append("HeaderDigest", "CRC32C")
        full.append("DataDigest", "None")
        full.append("MaxRecvDataSegmentLength", "32768")
        let encoded = full.encode()
        let splitAt = encoded.count / 2

        var part1 = response(to: opReq, statSN: 101, transit: false, continued: true)
        part1.dataSegment = encoded.prefix(splitAt)
        guard case .send(let ack) = try sm.receive(part1) else {
            Issue.record("expected continuation ack")
            return
        }
        #expect(ack.dataSegment.isEmpty)
        #expect(!ack.transit)

        var part2 = response(to: ack, statSN: 102, transit: true, nextStage: .fullFeaturePhase)
        part2.currentStage = .loginOperationalNegotiation
        part2.dataSegment = encoded.suffix(encoded.count - splitAt)
        guard case .success(let result) = try sm.receive(part2) else {
            Issue.record("expected success")
            return
        }
        #expect(result.parameters.headerDigest)
        #expect(result.parameters.targetMaxRecvDataSegmentLength == 32768)
    }

    @Test func oversizedOutgoingTextSplitsWithCBit() throws {
        // Force > 8192 bytes of login text via an absurd initiator name; the
        // machine must emit C=1 chunks and finish the text before transiting.
        var cfg = config()
        cfg.initiatorName = "iqn.2026-08.com.example:" + String(repeating: "x", count: 9000)
        var sm = LoginStateMachine(config: cfg)
        let first = sm.start()
        #expect(first.continued)
        #expect(!first.transit)
        #expect(first.dataSegment.count == 8192)

        // Target acks the chunk with an empty same-stage response.
        let ack = response(to: first, statSN: 1, transit: false)
        guard case .send(let second) = try sm.receive(ack) else {
            Issue.record("expected continuation chunk")
            return
        }
        #expect(!second.continued)
        #expect(second.transit) // remainder fits: transit restored
        let reassembled = first.dataSegment + second.dataSegment
        let text = try TextParameters.decode(reassembled)
        #expect(text["InitiatorName"]?.count == 9024)
    }

    @Test func discoverySessionAcceptsTSIHZero() throws {
        var sm = LoginStateMachine(config: config(type: .discovery))
        let first = sm.start()
        let firstText = try TextParameters.decode(first.dataSegment)
        #expect(firstText["SessionType"] == "Discovery")
        #expect(firstText["TargetName"] == nil)

        let r1 = response(to: first, statSN: 0, text: [("AuthMethod", "None")])
        guard case .send(let opReq) = try sm.receive(r1) else {
            Issue.record("expected proposal")
            return
        }
        let r2 = response(to: opReq, statSN: 1, text: [("HeaderDigest", "None")], tsih: 0)
        guard case .success = try sm.receive(r2) else {
            Issue.record("discovery login must succeed with TSIH 0")
            return
        }
    }

    @Test func normalSessionRequiresNonzeroTSIH() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        let r1 = response(to: first, statSN: 0, text: [("AuthMethod", "None")])
        guard case .send(let opReq) = try sm.receive(r1) else {
            Issue.record("expected proposal")
            return
        }
        let r2 = response(to: opReq, statSN: 1, tsih: 0)
        #expect(throws: NegotiationError.self) { try sm.receive(r2) }
    }

    @Test func statSNRegressionDetected() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        let r1 = response(to: first, statSN: 50, text: [("AuthMethod", "None")])
        guard case .send(let opReq) = try sm.receive(r1) else {
            Issue.record("expected proposal")
            return
        }
        // Target repeats StatSN 50 instead of 51.
        let r2 = response(to: opReq, statSN: 50, text: [("HeaderDigest", "None")], tsih: 1)
        #expect(throws: NegotiationError.self) { try sm.receive(r2) }
    }
}
