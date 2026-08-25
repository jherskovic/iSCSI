import Foundation
import Testing
@testable import iSCSIKit

// Tests pinning RFC 7143 requirements surfaced by the 2026-08 compliance
// review. Each test names the governing section.

@Suite("RFC compliance: PDU decoding")
struct PDUDecodeComplianceTests {
    /// §11.19.1: a NOP-In with ITT and TTT both 0xffffffff is a legal
    /// window/StatSN update ("If the target is initiating a NOP-In without
    /// wanting to receive a corresponding NOP-Out, this field MUST hold the
    /// reserved value 0xffffffff").
    @Test func nopInWithBothTagsReservedDecodes() throws {
        var nop = NopInPDU()
        nop.initiatorTaskTag = 0xFFFF_FFFF
        nop.targetTransferTag = 0xFFFF_FFFF
        nop.expCmdSN = 5
        nop.maxCmdSN = 40
        let decoded = try AnyPDU.decode(nop.encode())
        guard case .nopIn(let back) = decoded else {
            Issue.record("expected NOP-In, got \(decoded)")
            return
        }
        #expect(back.maxCmdSN == 40)
    }

    /// §11.4.3: response codes 0x80–0xff are vendor specific and valid on the
    /// wire; they map to SERVICE DELIVERY OR TARGET FAILURE, they are not a
    /// protocol error.
    @Test func vendorSpecificScsiResponseCodeDecodes() throws {
        var raw = SCSIResponsePDU().encode()
        raw.bhs.setU8(0x83, 2)
        let decoded = try AnyPDU.decode(raw)
        guard case .scsiResponse(let resp) = decoded else {
            Issue.record("expected SCSI Response, got \(decoded)")
            return
        }
        #expect(resp.response != .commandCompleted)
    }

    /// §11.4.3 + §11.1: 0x02–0x7f are reserved response codes — receipt MUST
    /// be reported as a protocol error.
    @Test func reservedScsiResponseCodeRejected() {
        var raw = SCSIResponsePDU().encode()
        raw.bhs.setU8(0x05, 2)
        #expect(throws: PDUError.self) { try AnyPDU.decode(raw) }
    }
}

@Suite("RFC compliance: negotiation engine")
struct NegotiationComplianceTests {
    /// §6.2: "the negotiation is not considered to have failed if the answer
    /// is 'Irrelevant'". The key falls back to its default.
    @Test func irrelevantAnswerFallsBackToDefault() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        _ = try engine.process(TextParameters([(key: "FirstBurstLength", value: "Irrelevant")]))
        let p = try engine.finalParameters(desired: DesiredParameters())
        #expect(p.firstBurstLength == 65536) // RFC default
    }

    /// §6.2: Irrelevant is only a legal *answer*; for a key we never proposed
    /// it is a protocol error (reserved constants MUST ONLY be used as
    /// described).
    @Test func irrelevantForUnproposedKeyRejected() {
        var engine = NegotiationEngine()
        #expect(throws: NegotiationError.self) {
            try engine.process(TextParameters([(key: "FirstBurstLength", value: "Irrelevant")]))
        }
    }

    /// §6.1: numerical-value is "a decimal-constant or a hex-constant".
    @Test func hexNumericAnswerAccepted() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        _ = try engine.process(TextParameters([(key: "MaxBurstLength", value: "0x40000")]))
        let p = try engine.finalParameters(desired: DesiredParameters())
        #expect(p.maxBurstLength == 0x40000)
    }

    /// §6.1: hex form is equally valid for a declarative key.
    @Test func hexDeclarativeMRDSLAccepted() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        _ = try engine.process(TextParameters([(key: "MaxRecvDataSegmentLength", value: "0x8000")]))
        let p = try engine.finalParameters(desired: DesiredParameters())
        #expect(p.targetMaxRecvDataSegmentLength == 32768)
    }

    /// §6.3: "An attempt to renegotiate/redeclare parameters not specifically
    /// allowed MUST be detected by the initiator" (and the connection dropped).
    @Test func renegotiatedKeyRejected() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        _ = try engine.process(TextParameters([(key: "MaxBurstLength", value: "524288")]))
        #expect(throws: NegotiationError.self) {
            try engine.process(TextParameters([(key: "MaxBurstLength", value: "524288")]))
        }
    }

    /// §6.3 allows repeated declarations only for specific keys, e.g.
    /// TargetAddress.
    @Test func repeatedTargetAddressAllowed() throws {
        var engine = NegotiationEngine()
        _ = try engine.process(TextParameters([
            (key: "TargetAddress", value: "10.0.0.1:3260,1"),
            (key: "TargetAddress", value: "10.0.0.2:3260,1"),
        ]))
    }

    /// §6.2: "An iSCSI implementation MUST comprehend all text keys defined in
    /// this document. Returning a NotUnderstood response on any of these text
    /// keys therefore MUST be considered a protocol error."
    @Test func notUnderstoodForStandardKeyIsProtocolError() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        #expect(throws: NegotiationError.self) {
            try engine.process(TextParameters([(key: "MaxOutstandingR2T", value: "NotUnderstood")]))
        }
    }

    /// §13 result functions: the selected value must be a possible result of
    /// the Boolean function — answering "No" to an OR-Yes offer is invalid.
    @Test func orOfferOfYesIsAnsweredYes() throws {
        var engine = NegotiationEngine() // nothing proposed: target opens
        let replies = try engine.process(TextParameters([(key: "InitialR2T", value: "Yes")]))
        #expect(replies["InitialR2T"] == "Yes")
    }

    /// §13 result functions: AND with "No" received determines the result;
    /// an answer, if sent, must be "No".
    @Test func andOfferOfNoIsAnsweredNo() throws {
        var engine = NegotiationEngine()
        let replies = try engine.process(TextParameters([(key: "ImmediateData", value: "No")]))
        #expect(replies["ImmediateData"] == "No")
    }
}

@Suite("RFC compliance: login state machine")
struct LoginComplianceTests {
    func config() -> LoginConfig {
        LoginConfig(
            initiatorName: "iqn.2026-08.test.example:mac",
            sessionType: .discovery
        )
    }

    func successResponse(to request: LoginRequestPDU, statSN: UInt32) -> LoginResponsePDU {
        var resp = LoginResponsePDU()
        resp.transit = request.transit
        resp.currentStage = request.currentStage
        resp.nextStage = request.nextStage
        resp.isid = request.isid
        resp.initiatorTaskTag = request.initiatorTaskTag
        resp.statSN = statSN
        resp.expCmdSN = request.cmdSN
        resp.maxCmdSN = request.cmdSN &+ 8
        return resp
    }

    /// §11.12.3 + §11.1: NSG is reserved when T=0, and reserved fields MUST be
    /// set to 0 by a compliant sender. The continuation ack during the
    /// operational stage is the request most likely to get this wrong.
    @Test func nonTransitContinuationAckCarriesZeroNSG() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        // Security transit into operational.
        var r1 = successResponse(to: first, statSN: 100)
        r1.transit = true
        r1.nextStage = .loginOperationalNegotiation
        guard case .send(let op) = try sm.receive(r1) else {
            Issue.record("expected operational proposal")
            return
        }
        // Target continues its answer (C=1): the machine must ack with an
        // empty, non-transit request whose NSG field is zero.
        var r2 = successResponse(to: op, statSN: 101)
        r2.transit = false
        r2.continued = true
        r2.currentStage = .loginOperationalNegotiation
        r2.dataSegment = Data("MaxRecvDataSegmentLength=8192".utf8)
        guard case .send(let ack) = try sm.receive(r2) else {
            Issue.record("expected continuation ack")
            return
        }
        #expect(!ack.transit)
        #expect(ack.nextStage.rawValue == 0)
    }

    /// The ISID in a Login Response identifies our session; a mismatch means
    /// the response is not for this login.
    @Test func mismatchedISIDEchoRejected() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        var resp = successResponse(to: first, statSN: 100)
        resp.isid = ISID(Data([0x80, 9, 9, 9, 0, 0]))
        #expect(throws: NegotiationError.self) { try sm.receive(resp) }
    }

    /// §11.13.1: the version the target operates at must be 0x00.
    @Test func nonzeroVersionActiveRejected() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        var resp = successResponse(to: first, statSN: 100)
        resp.versionActive = 1
        #expect(throws: NegotiationError.self) { try sm.receive(resp) }
    }

    /// The response's ITT must echo the request's (always 0 for this login).
    @Test func mismatchedITTEchoRejected() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        var resp = successResponse(to: first, statSN: 100)
        resp.initiatorTaskTag = 7
        #expect(throws: NegotiationError.self) { try sm.receive(resp) }
    }

    /// §11.12.3: CSG associates the exchange with a stage; a response for a
    /// stage we are not in is not an answer to our request.
    @Test func mismatchedCSGRejected() throws {
        var sm = LoginStateMachine(config: config())
        let first = sm.start()
        var resp = successResponse(to: first, statSN: 100)
        resp.currentStage = .loginOperationalNegotiation
        resp.nextStage = .loginOperationalNegotiation
        #expect(throws: NegotiationError.self) { try sm.receive(resp) }
    }
}

@Suite("RFC compliance: CHAP")
struct CHAPComplianceTests {
    let creds = CHAP.Credentials(name: "initiator", secret: "supersecret123")

    func challenge(a: String = "5") -> TextParameters {
        TextParameters([
            (key: "CHAP_A", value: a),
            (key: "CHAP_I", value: "1"),
            (key: "CHAP_C", value: "0xdeadbeefcafe0123"),
        ])
    }

    /// CHAP_A is a number (§12.1.3); "05" and "5" are the same algorithm.
    @Test func chapAlgorithmEchoWithLeadingZeroAccepted() throws {
        var exchange = CHAP.InitiatorExchange(credentials: creds)
        _ = try exchange.respond(to: challenge(a: "05"))
    }

    /// §12.1.3: the binary length of C "MUST NOT exceed 1024 bytes".
    @Test func oversizedChallengeRejected() {
        var params = TextParameters()
        params.append("CHAP_A", "5")
        params.append("CHAP_I", "1")
        params.append("CHAP_C", "0x" + String(repeating: "ab", count: 1025))
        var exchange = CHAP.InitiatorExchange(credentials: creds)
        #expect(throws: NegotiationError.self) { try exchange.respond(to: params) }
    }

    @Test func challengeAtLimitAccepted() throws {
        var params = TextParameters()
        params.append("CHAP_A", "5")
        params.append("CHAP_I", "1")
        params.append("CHAP_C", "0x" + String(repeating: "ab", count: 1024))
        var exchange = CHAP.InitiatorExchange(credentials: creds)
        _ = try exchange.respond(to: params)
    }

    /// §9.2.1: "If the CHAP response received by one end ... is the same as
    /// the CHAP response that the receiving endpoint would have generated for
    /// the same CHAP challenge, the response MUST be treated as an
    /// authentication failure" — the same-secret-both-directions check.
    @Test func mutualResponseMatchingOwnSecretRejected() throws {
        let shared = "sharedsecret1234"
        let creds = CHAP.Credentials(
            name: "initiator", secret: shared,
            mutualName: "target", mutualSecret: shared
        )
        var exchange = CHAP.InitiatorExchange(credentials: creds)
        let fixed = Data(repeating: 0x42, count: 16)
        let reply = try exchange.respond(to: challenge(), randomBytes: { _ in fixed })
        let id = try CHAP.decodeID(reply["CHAP_I"]!)
        var answer = TextParameters()
        answer.append("CHAP_N", "target")
        answer.append("CHAP_R", CHAP.encodeHex(CHAP.response(id: id, secret: shared, challenge: fixed)))
        #expect(throws: NegotiationError.self) { try exchange.verifyMutual(answer) }
    }

    /// §9.2.1: "Any CHAP secret used for initiator authentication MUST NOT be
    /// configured for authentication of any target."
    @Test func validatedRejectsSameSecretBothDirections() {
        #expect(throws: CHAP.CredentialError.self) {
            _ = try CHAP.Credentials.validated(
                name: "initiator", secret: "supersecret123",
                mutualName: "target", mutualSecret: "supersecret123"
            )
        }
    }
}

@Suite("RFC compliance: SCSI plumbing")
struct SCSIPlumbingComplianceTests {
    /// SPC-4 descriptor-format sense (response codes 0x72/0x73) carries the
    /// key/ASC/ASCQ in bytes 1–3.
    @Test func descriptorFormatSenseParsed() throws {
        let bytes = Data([0x72, 0x05, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00])
        let sense = try #require(SenseData(bytes))
        #expect(sense.key == 0x05)
        #expect(sense.asc == 0x20)
        #expect(sense.ascq == 0x00)
    }
}

@Suite("RFC compliance: node naming")
struct NodeNamingComplianceTests {
    /// §4.2.7.2 / RFC 3721: the iqn naming authority must be a domain the
    /// author actually owns; com.example is RFC 2606-reserved.
    @Test func defaultInitiatorNameUsesOwnedDomain() {
        let name = IQN.defaultInitiatorName(hostIdentifier: "Test Mac")
        #expect(name.hasPrefix("iqn.2026-08.me.herko:"))
        #expect(IQN.isValid(name))
    }
}

@Suite("RFC compliance: recovery timing")
struct RecoveryTimingTests {
    /// §7.5: after a transport exception, recovery SHOULD NOT begin before
    /// the negotiated DefaultTime2Wait; later attempts are already past it.
    @Test func firstRecoveryAttemptWaitsTime2Wait() {
        var policy = SessionPolicy()
        policy.recoveryBackoffBase = .milliseconds(10)
        policy.recoveryBackoffCap = .seconds(30)
        #expect(ISCSISession.recoveryDelay(attempt: 0, policy: policy, time2Wait: 2) == .seconds(2))
        #expect(ISCSISession.recoveryDelay(attempt: 1, policy: policy, time2Wait: 2) == .milliseconds(20))
    }

    @Test func time2WaitCanBeDisabled() {
        var policy = SessionPolicy()
        policy.honorTime2Wait = false
        policy.recoveryBackoffBase = .milliseconds(10)
        #expect(ISCSISession.recoveryDelay(attempt: 0, policy: policy, time2Wait: 2) == .milliseconds(10))
    }
}

@Suite("RFC compliance: LUN addressing")
struct LUNAddressingComplianceTests {
    /// SAM-2: single-level peripheral addressing covers LUN 0–255; larger
    /// numbers need the flat-space format (01b in the top bits).
    @Test func lunFieldUsesPeripheralThenFlatAddressing() {
        #expect(SCSITask.lunField(0) == 0)
        #expect(SCSITask.lunField(5) == 5 << 48)
        #expect(SCSITask.lunField(300) == (0x4000 | 300) << 48)
    }
}
