import Foundation
import Testing
@testable import iSCSIKit

@Suite("Text-key negotiation engine")
struct NegotiationTests {
    /// Run a proposal + scripted target answers, return final parameters.
    func negotiate(
        desired: DesiredParameters = DesiredParameters(),
        answers: [(String, String)],
        sessionType: SessionType = .normal
    ) throws -> OperationalParameters {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: desired, sessionType: sessionType)
        _ = try engine.process(TextParameters(answers.map { (key: $0.0, value: $0.1) }))
        return try engine.finalParameters(desired: desired)
    }

    // MARK: ImmediateData × InitialR2T — all four write-path combinations

    @Test(arguments: [
        // (ourImmediate, ourInitialR2T, targetImmediate, targetInitialR2T,
        //  expectImmediate, expectInitialR2T)
        (true, false, "Yes", "No", true, false), // unsolicited everything
        (true, false, "No", "No", false, false),
        (true, false, "Yes", "Yes", true, true), // solicited-only target
        (false, true, "Yes", "No", false, true), // we want solicited
    ])
    func immediateDataByInitialR2TMatrix(
        _ combo: (Bool, Bool, String, String, Bool, Bool)
    ) throws {
        var desired = DesiredParameters()
        desired.immediateData = combo.0
        desired.initialR2T = combo.1
        let p = try negotiate(desired: desired, answers: [
            ("ImmediateData", combo.2),
            ("InitialR2T", combo.3),
        ])
        #expect(p.immediateData == combo.4)
        #expect(p.initialR2T == combo.5)
        #expect(p.canSendImmediateData == combo.4)
        #expect(p.canSendUnsolicitedDataOut == !combo.5)
    }

    // MARK: MaxRecvDataSegmentLength asymmetry (declarative per direction)

    @Test func mrdslAsymmetry() throws {
        var desired = DesiredParameters()
        desired.maxRecvDataSegmentLength = 1 << 20 // we accept 1 MiB
        let p = try negotiate(desired: desired, answers: [
            ("MaxRecvDataSegmentLength", "512"), // target accepts only 512
        ])
        #expect(p.initiatorMaxRecvDataSegmentLength == 1 << 20)
        #expect(p.targetMaxRecvDataSegmentLength == 512) // caps our sends
    }

    @Test func mrdslDefaultWhenUnanswered() throws {
        let p = try negotiate(answers: [])
        #expect(p.targetMaxRecvDataSegmentLength == 8192) // RFC default
    }

    @Test func mrdslOutOfRangeRejected() {
        #expect(throws: NegotiationError.self) {
            try negotiate(answers: [("MaxRecvDataSegmentLength", "256")]) // < 512
        }
        #expect(throws: NegotiationError.self) {
            try negotiate(answers: [("MaxRecvDataSegmentLength", "16777216")]) // > 2^24-1
        }
    }

    // MARK: Burst-length boundaries

    @Test func burstLengthsTakeMinimum() throws {
        var desired = DesiredParameters()
        desired.maxBurstLength = 1 << 20
        desired.firstBurstLength = 1 << 18
        let p = try negotiate(desired: desired, answers: [
            ("MaxBurstLength", "262144"),
            ("FirstBurstLength", "65536"),
        ])
        #expect(p.maxBurstLength == 262_144)
        #expect(p.firstBurstLength == 65536)
    }

    @Test func firstBurstGreaterThanMaxBurstRejected() {
        // Even after safe min-folding, a target that pushes MaxBurst below
        // FirstBurst must fail cross-key validation at the end of login.
        // (default desired: FirstBurst 262144, MaxBurst 1 MiB)
        #expect(throws: NegotiationError.self) {
            try negotiate(answers: [
                ("MaxBurstLength", "512"), // folds MaxBurst to 512
                ("FirstBurstLength", "262144"), // folds FirstBurst to 262144 > 512
            ])
        }
    }

    // MARK: Digests

    @Test(arguments: [
        ("CRC32C", "CRC32C", true, true),
        ("None", "None", false, false),
        ("CRC32C", "None", true, false),
    ])
    func digestSelections(_ combo: (String, String, Bool, Bool)) throws {
        let p = try negotiate(answers: [
            ("HeaderDigest", combo.0),
            ("DataDigest", combo.1),
        ])
        #expect(p.headerDigest == combo.2)
        #expect(p.dataDigest == combo.3)
    }

    @Test func digestPickOutsideOfferRejected() {
        var desired = DesiredParameters()
        desired.offerDigests = false // we offer only None
        #expect(throws: NegotiationError.self) {
            try negotiate(desired: desired, answers: [("HeaderDigest", "CRC32C")])
        }
    }

    @Test func digestDefaultIsNone() throws {
        let p = try negotiate(answers: [])
        #expect(!p.headerDigest && !p.dataDigest)
    }

    // MARK: ErrorRecoveryLevel

    @Test func erlNegotiatesDownToZero() throws {
        // We propose 0; target answering 0 is the only valid fold.
        let p = try negotiate(answers: [("ErrorRecoveryLevel", "0")])
        #expect(p.errorRecoveryLevel == 0)
    }

    @Test func erlAboveProposalClampedToZero() {
        // A target answering ERL=2 to our proposal of 0 is safely min-folded
        // back to 0 — we never silently operate above the ERL we support.
        let p = try! negotiate(answers: [("ErrorRecoveryLevel", "2")])
        #expect(p.errorRecoveryLevel == 0)
    }

    @Test func targetOfferedERLNegotiatedDown() throws {
        // Target opens ERL negotiation offering 2: we answer 0 (our hard
        // ceiling) and the folded result is min(2, 0) = 0.
        var engine = NegotiationEngine()
        let replies = try engine.process(TextParameters([(key: "ErrorRecoveryLevel", value: "2")]))
        #expect(replies["ErrorRecoveryLevel"] == "0")
        let p = try engine.finalParameters(desired: DesiredParameters())
        #expect(p.errorRecoveryLevel == 0)
    }

    @Test func targetDeclaredMRDSLNeedsNoReply() throws {
        var engine = NegotiationEngine()
        let replies = try engine.process(
            TextParameters([(key: "MaxRecvDataSegmentLength", value: "65536")])
        )
        #expect(replies.isEmpty)
        let p = try engine.finalParameters(desired: DesiredParameters())
        #expect(p.targetMaxRecvDataSegmentLength == 65536)
    }

    // MARK: Absent keys → RFC defaults

    @Test func absentKeysLandOnRFCDefaults() throws {
        let p = try negotiate(answers: [])
        #expect(p.initialR2T == true)
        #expect(p.immediateData == true)
        #expect(p.maxBurstLength == 262_144)
        #expect(p.firstBurstLength == 65536)
        #expect(p.maxConnections == 1)
        #expect(p.maxOutstandingR2T == 1)
        #expect(p.defaultTime2Wait == 2)
        #expect(p.defaultTime2Retain == 20)
        #expect(p.dataPDUInOrder == true)
        #expect(p.dataSequenceInOrder == true)
        #expect(p.errorRecoveryLevel == 0)
    }

    // MARK: Reject / NotUnderstood / unknown keys

    @Test func rejectFallsBackToDefault() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        _ = try engine.process(TextParameters([(key: "HeaderDigest", value: "Reject")]))
        let p = try engine.finalParameters(desired: DesiredParameters())
        #expect(!p.headerDigest)
        #expect(engine.rejected.contains("HeaderDigest"))
    }

    // NotUnderstood for an RFC-defined key is a protocol error (§6.2);
    // see notUnderstoodForStandardKeyIsProtocolError in RFCComplianceTests.

    @Test func unsolicitedRejectIsProtocolViolation() {
        var engine = NegotiationEngine()
        #expect(throws: NegotiationError.self) {
            try engine.process(TextParameters([(key: "InitialR2T", value: "Reject")]))
        }
    }

    @Test func unknownTargetKeyAnsweredNotUnderstood() throws {
        var engine = NegotiationEngine()
        let replies = try engine.process(TextParameters([(key: "X-com.example.magic", value: "42")]))
        #expect(replies["X-com.example.magic"] == "NotUnderstood")
    }

    @Test func markersNegotiatedOff() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        let replies = try engine.process(TextParameters([
            (key: "OFMarker", value: "Yes"),
            (key: "IFMarker", value: "Yes"),
        ]))
        #expect(replies["OFMarker"] == "No")
        #expect(replies["IFMarker"] == "No")
    }

    @Test func invalidBooleanRejected() {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        #expect(throws: NegotiationError.self) {
            try engine.process(TextParameters([(key: "ImmediateData", value: "Maybe")]))
        }
    }

    @Test func declarativeTargetFacts() throws {
        var engine = NegotiationEngine()
        _ = engine.proposeOperational(desired: DesiredParameters(), sessionType: .normal)
        let replies = try engine.process(TextParameters([
            (key: "TargetPortalGroupTag", value: "1"),
            (key: "TargetAlias", value: "Fancy NAS"),
        ]))
        #expect(replies.isEmpty)
        let p = try engine.finalParameters(desired: DesiredParameters())
        #expect(p.targetPortalGroupTag == 1)
        #expect(p.targetAlias == "Fancy NAS")
    }

    @Test func discoverySessionProposesOnlyConnectionKeys() {
        var engine = NegotiationEngine()
        let proposal = engine.proposeOperational(desired: DesiredParameters(), sessionType: .discovery)
        #expect(proposal["HeaderDigest"] != nil)
        #expect(proposal["MaxRecvDataSegmentLength"] != nil)
        #expect(proposal["MaxBurstLength"] == nil)
        #expect(proposal["InitialR2T"] == nil)
    }
}
