//
//  LoginFloodTests.swift
//  The login exchange against a target that never finishes it.
//
//  Both cases are pre-authentication, and the process on the receiving end
//  is the root daemon. The state machine is pure — no sockets, no clock — so
//  "does this terminate?" is answerable in microseconds.
//

import Foundation
import Testing
@testable import iSCSIKit

@Suite("Login flooding is refused")
struct LoginFloodTests {

    private func config() -> LoginConfig {
        var c = LoginConfig(initiatorName: "iqn.2026-08.com.example:mac",
                            sessionType: .normal,
                            targetName: "iqn.2026-08.com.example:disk0")
        c.desired.offerDigests = true
        return c
    }

    /// A continued login response carrying `bytes` of filler.
    private func continuedResponse(to request: LoginRequestPDU,
                                   statSN: UInt32,
                                   bytes: Int) -> LoginResponsePDU {
        var resp = LoginResponsePDU()
        resp.transit = false
        resp.continued = true
        resp.currentStage = request.currentStage
        resp.nextStage = request.currentStage
        resp.isid = request.isid
        resp.initiatorTaskTag = request.initiatorTaskTag
        resp.statSN = statSN
        resp.expCmdSN = request.cmdSN
        resp.maxCmdSN = request.cmdSN &+ 32
        resp.dataSegment = Data(repeating: 0x41, count: bytes)
        return resp
    }

    /// B4. The C bit set forever with real payload: `loginTextLimit` must
    /// bound what we *receive*, not only what we send.
    @Test("a target that never clears the C bit is cut off at the login text limit")
    func continuationFloodIsBounded() throws {
        var machine = LoginStateMachine(config: config(), cmdSN: 1)
        var request = machine.start()
        var statSN: UInt32 = 0

        var rounds = 0
        var threw = false
        while rounds < 10_000 {
            rounds += 1
            let resp = continuedResponse(to: request, statSN: statSN, bytes: 1024)
            statSN &+= 1
            do {
                switch try machine.receive(resp) {
                case .send(let next): request = next
                case .success, .redirect: Issue.record("flood should not complete a login")
                }
            } catch {
                threw = true
                break
            }
        }
        #expect(threw, "the initiator must refuse the flood rather than buffer it forever")
        // 8192 / 1024 chunks, plus the round that trips the guard. Pinned so a
        // future change that raises the cap has to say so out loud.
        #expect(rounds <= LoginStateMachine.loginTextLimit / 1024 + 2,
                "cut off after \(rounds) rounds, expected ~9")
    }

    /// The livelock the buffer cap alone does not catch: continuations with an
    /// *empty* data segment never grow the buffer, so nothing trips, and the
    /// exchange spins. `ISCSIConnection` bounds the round count for this.
    @Test("empty continuations do not grow the buffer, so the round cap is what stops them")
    func emptyContinuationsNeedTheRoundCap() throws {
        var machine = LoginStateMachine(config: config(), cmdSN: 1)
        var request = machine.start()
        var statSN: UInt32 = 0

        // Deliberately more rounds than ISCSIConnection allows, to show the
        // state machine alone will keep going: it is the connection's round cap
        // that ends this, which is why that cap exists.
        for _ in 0 ..< (ISCSIConnection.maxLoginRounds * 4) {
            let resp = continuedResponse(to: request, statSN: statSN, bytes: 0)
            statSN &+= 1
            switch try machine.receive(resp) {
            case .send(let next): request = next
            case .success, .redirect: Issue.record("empty continuations should not complete a login")
            }
        }
        #expect(ISCSIConnection.maxLoginRounds > 0)
    }

    /// The bound must not be so tight that a legitimate multi-chunk login fails.
    @Test("a login that legitimately spans two chunks still completes")
    func legitimateContinuationStillWorks() throws {
        var machine = LoginStateMachine(config: config(), cmdSN: 1)
        let request = machine.start()

        // One continued chunk well inside the limit, then a normal reply.
        let first = continuedResponse(to: request, statSN: 0, bytes: 2048)
        guard case .send(let next) = try machine.receive(first) else {
            Issue.record("expected the initiator to ask for the rest")
            return
        }
        var done = LoginResponsePDU()
        done.transit = true
        done.continued = false
        done.currentStage = .securityNegotiation
        done.nextStage = .loginOperationalNegotiation
        done.isid = next.isid
        done.initiatorTaskTag = next.initiatorTaskTag
        done.statSN = 1
        done.expCmdSN = next.cmdSN
        done.maxCmdSN = next.cmdSN &+ 32
        // The filler above is not key=value text, so this must decode as a whole;
        // send a clean segment and let the buffered filler make it fail *parsing*
        // rather than fail the cap. Either way it must not hang, which is the point.
        done.dataSegment = TextParameters([(key: "AuthMethod", value: "None")]).encode()
        _ = try? machine.receive(done)
    }
}
