//
//  ISCSIErrorTests.swift
//
//  These exist because the failure they guard against is silent. An error that
//  maps to the wrong code still crosses XPC, still displays, and still looks
//  like it worked — it just tells the user the wrong thing, at the moment they
//  are least able to tell.
//

import Foundation
import Testing
@testable import iSCSIKit

@Suite("Error mapping across XPC")
struct ISCSIErrorTests {

    /// The distinction the whole file exists for: a mistyped password must
    /// not read the same as an unplugged NAS.
    @Test("a bad secret and an unreachable target are different errors")
    func authIsNotConnectivity() {
        let auth = ISCSIError.nsError(
            from: ConnectionError.loginFailed(.authenticationFailed("CHAP mismatch")))
        let offline = ISCSIError.nsError(
            from: TransportError.connectFailed("Connection refused"))

        #expect(auth.code == ISCSIError.Code.authenticationFailed.rawValue)
        #expect(offline.code == ISCSIError.Code.cannotConnect.rawValue)
        #expect(auth.code != offline.code)
        #expect(auth.localizedRecoverySuggestion?.contains("CHAP") == true)
    }

    /// RFC 7143 status class 0x02 / detail 0x01 is an authorisation refusal, and
    /// is what a target actually returns for a wrong CHAP secret or a
    /// disallowed initiator IQN. Reporting it as a generic "login rejected"
    /// with two hex bytes sends the user looking in the wrong place.
    @Test("login status 0x02/0x01 is reported as an authentication failure")
    func loginStatusAuthFailureIsNamed() {
        let error = ISCSIError.nsError(
            from: NegotiationError.loginFailed(statusClass: 0x02, statusDetail: 0x01))
        #expect(error.code == ISCSIError.Code.authenticationFailed.rawValue)
        #expect(error.localizedDescription.lowercased().contains("unauthorised"))
    }

    @Test("other login refusals keep their status bytes visible")
    func otherLoginStatusKeepsBytes() {
        let error = ISCSIError.nsError(
            from: NegotiationError.loginFailed(statusClass: 0x01, statusDetail: 0x02))
        #expect(error.code == ISCSIError.Code.loginRejected.rawValue)
        #expect(error.localizedDescription.contains("0x01"))
        #expect(error.localizedDescription.contains("0x02"))
    }

    @Test("a task timeout is distinguishable from a lost connection")
    func timeoutIsNotDisconnection() {
        let timeout = ISCSIError.nsError(from: SessionError.taskTimedOut)
        let lost = ISCSIError.nsError(from: ConnectionError.connectionLost("EPIPE"))
        #expect(timeout.code == ISCSIError.Code.taskTimedOut.rawValue)
        #expect(lost.code == ISCSIError.Code.connectionLost.rawValue)
    }

    /// Sense bytes are the first thing a storage vendor asks for. They are
    /// attached to the error rather than left only in the daemon's log so that
    /// a bug report carries them without anyone having to know to go looking.
    @Test("a check condition carries its sense data")
    func checkConditionCarriesSense() throws {
        // SenseData only parses from the wire, so build a fixed-format buffer:
        // byte 0 response code 0x70, byte 2 low nibble sense key, 12/13 asc/ascq.
        var bytes = Data(count: 18)
        bytes[0] = 0x70; bytes[2] = 0x03; bytes[12] = 0x11; bytes[13] = 0x00
        let sense = try #require(SenseData(bytes))
        let error = ISCSIError.nsError(from: BlockDeviceError.scsiError(status: 0x02, sense: sense))
        #expect(error.code == ISCSIError.Code.checkCondition.rawValue)
        let recorded = try #require(error.userInfo[ISCSIError.senseKey] as? String)
        #expect(recorded.contains("0x03"), "the sense key must survive the crossing")
        #expect(recorded.contains("0x11"))
        #expect(error.localizedDescription.contains("0x02"))
    }

    @Test("every mapped error has a non-empty description and our domain")
    func everyErrorIsPresentable() {
        let errors: [Error] = [
            ConnectionError.closed,
            ConnectionError.connectionLost("x"),
            ConnectionError.protocolError("x"),
            ConnectionError.redirected(address: "10.0.0.1", permanent: true),
            ConnectionError.targetRequestedLogout,
            NegotiationError.keyRejected("MaxRecvDataSegmentLength"),
            NegotiationError.invalidValue(key: "k", value: "v"),
            NegotiationError.invalidResult("x"),
            NegotiationError.protocolViolation("x"),
            NegotiationError.authenticationFailed("x"),
            SessionError.notActive,
            SessionError.loggedOut,
            SessionError.recoveryExhausted(lastError: "x"),
            SessionError.taskTimedOut,
            BlockDeviceError.notReady,
            BlockDeviceError.misaligned(offset: 1, length: 2, blockSize: 512),
            BlockDeviceError.outOfRange(lba: 1, blocks: 2, capacity: 3),
            TransportError.closed,
            TransportError.connectFailed("x"),
        ]
        for error in errors {
            let mapped = ISCSIError.nsError(from: error)
            #expect(mapped.domain == ISCSIError.domain)
            #expect(!mapped.localizedDescription.isEmpty)
            // The raw Swift error is always retained: the mapping is a
            // convenience for humans, not a replacement for the evidence.
            #expect(mapped.userInfo[ISCSIError.underlyingKey] != nil)
        }
    }

    @Test("an unrecognised error still crosses the boundary intact")
    func unknownErrorsSurvive() {
        struct Odd: Error { let detail = "something new" }
        let mapped = ISCSIError.nsError(from: Odd())
        #expect(mapped.domain == ISCSIError.domain)
        #expect(mapped.code == ISCSIError.Code.daemonInternal.rawValue)
        #expect((mapped.userInfo[ISCSIError.underlyingKey] as? String)?.contains("Odd") == true)
    }

    /// Codes cross a process boundary between an app and a daemon that can be
    /// different builds mid-update, and they end up quoted in bug reports.
    @Test("error codes are unique")
    func codesAreUnique() {
        let raw = ISCSIError.Code.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
    }

    @Test("a Connect refused for the host NQN says what to add on the NAS")
    func nvmeInvalidHostIsActionable() {
        let error = ISCSIError.nsError(from: BlockDeviceError.nvmeStatus(sct: 1, sc: 0x84, opcode: 0x7F))
        #expect(error.code == ISCSIError.Code.nvmeStatus.rawValue)
        #expect(error.localizedDescription.contains("host NQN"))
        #expect(error.localizedRecoverySuggestion?.contains("allowed hosts") == true)
        #expect((error.userInfo[ISCSIError.senseKey] as? String) == "sct 0x01 sc 0x84 opcode 0x7f")
    }

    @Test("an invalid namespace ID points at NSIDs starting at 1")
    func nvmeInvalidNamespaceIsActionable() {
        let error = ISCSIError.nsError(from: BlockDeviceError.nvmeStatus(sct: 0, sc: 0x0B, opcode: 0x06))
        #expect(error.code == ISCSIError.Code.nvmeStatus.rawValue)
        #expect(error.localizedRecoverySuggestion?.contains("start at 1") == true)
    }

    @Test("an unclassified NVMe status still carries its bytes")
    func nvmeGenericStatusCarriesEvidence() {
        let error = ISCSIError.nsError(from: BlockDeviceError.nvmeStatus(sct: 2, sc: 0x81, opcode: 0x02))
        #expect(error.code == ISCSIError.Code.nvmeStatus.rawValue)
        #expect(error.localizedDescription.contains("0x02/0x81"))
        #expect((error.userInfo[ISCSIError.senseKey] as? String)?.contains("opcode 0x02") == true)
        let notReady = ISCSIError.nsError(from: BlockDeviceError.nvmeStatus(sct: 0, sc: 0x82, opcode: 0x02))
        #expect(notReady.code == ISCSIError.Code.deviceNotReady.rawValue)
    }

    @Test("context is prefixed so the message says what was being attempted")
    func contextIsPrefixed() {
        let error = ISCSIError.nsError(from: TransportError.connectFailed("refused"),
                                       context: "Discovering targets at nas.local")
        #expect(error.localizedDescription.hasPrefix("Discovering targets at nas.local: "))
    }
}
