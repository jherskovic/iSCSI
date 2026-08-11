import Foundation
import Testing
@testable import iSCSIKit

@Suite("CHAP authentication")
struct CHAPTests {
    // Ground truth generated independently with Python hashlib:
    // MD5(id || secret || challenge).
    @Test func knownResponseVectors() throws {
        let r1 = CHAP.response(
            id: 1,
            secret: "secret",
            challenge: try CHAP.decodeValue("0xdeadbeefcafef00d")
        )
        #expect(CHAP.encodeHex(r1) == "0x48a9f8c7b819180f441adac51bfd6b21")

        let r2 = CHAP.response(
            id: 200,
            secret: "longer-chap-secret-123",
            challenge: Data((0 ..< 16).map { UInt8($0) })
        )
        #expect(CHAP.encodeHex(r2) == "0xf5b4dd3f1487bae5f4a95c664775d019")
    }

    @Test func valueDecoding() throws {
        #expect(try CHAP.decodeValue("0xdead") == Data([0xDE, 0xAD]))
        #expect(try CHAP.decodeValue("0Xdead") == Data([0xDE, 0xAD]))
        // Odd-length hex is left-padded.
        #expect(try CHAP.decodeValue("0xabc") == Data([0x0A, 0xBC]))
        // Base64.
        #expect(try CHAP.decodeValue("0b" + Data([1, 2, 3]).base64EncodedString()) == Data([1, 2, 3]))
        // Decimal.
        #expect(try CHAP.decodeValue("255") == Data([0xFF]))
        #expect(try CHAP.decodeValue("256") == Data([0x01, 0x00]))
        #expect(throws: NegotiationError.self) { try CHAP.decodeValue("0x") }
        #expect(throws: NegotiationError.self) { try CHAP.decodeValue("0xzz") }
        #expect(throws: NegotiationError.self) { try CHAP.decodeValue("junk") }
    }

    @Test func idDecoding() throws {
        #expect(try CHAP.decodeID("0") == 0)
        #expect(try CHAP.decodeID("255") == 255)
        #expect(throws: NegotiationError.self) { try CHAP.decodeID("256") }
        #expect(throws: NegotiationError.self) { try CHAP.decodeID("-1") }
    }

    @Test func forwardExchange() throws {
        var exchange = CHAP.InitiatorExchange(
            credentials: .init(name: "initiator-user", secret: "secret")
        )
        #expect(exchange.algorithmProposal()["CHAP_A"] == "5")

        var challenge = TextParameters()
        challenge.append("CHAP_A", "5")
        challenge.append("CHAP_I", "1")
        challenge.append("CHAP_C", "0xdeadbeefcafef00d")
        let reply = try exchange.respond(to: challenge)
        #expect(reply["CHAP_N"] == "initiator-user")
        #expect(reply["CHAP_R"] == "0x48a9f8c7b819180f441adac51bfd6b21")
        #expect(reply["CHAP_I"] == nil) // no mutual requested
        // No mutual: verify is a no-op even with no target answer.
        try exchange.verifyMutual(TextParameters())
    }

    @Test func mutualExchangeVerifies() throws {
        var exchange = CHAP.InitiatorExchange(
            credentials: .init(
                name: "user", secret: "s1",
                mutualName: "target-user", mutualSecret: "s2"
            )
        )
        var challenge = TextParameters()
        challenge.append("CHAP_A", "5")
        challenge.append("CHAP_I", "7")
        challenge.append("CHAP_C", "0x0102030405060708")
        let reply = try exchange.respond(to: challenge) { count in
            Data(repeating: 0xAB, count: count) // deterministic "random"
        }
        let ourID = try CHAP.decodeID(reply["CHAP_I"]!)
        let ourChallenge = try CHAP.decodeValue(reply["CHAP_C"]!)
        #expect(ourChallenge == Data(repeating: 0xAB, count: 16))

        // Target answers correctly…
        var good = TextParameters()
        good.append("CHAP_N", "target-user")
        good.append("CHAP_R", CHAP.encodeHex(CHAP.response(id: ourID, secret: "s2", challenge: ourChallenge)))
        try exchange.verifyMutual(good)

        // …wrong secret fails…
        var badSecret = TextParameters()
        badSecret.append("CHAP_N", "target-user")
        badSecret.append("CHAP_R", CHAP.encodeHex(CHAP.response(id: ourID, secret: "wrong", challenge: ourChallenge)))
        #expect(throws: NegotiationError.self) { try exchange.verifyMutual(badSecret) }

        // …wrong name fails…
        var badName = TextParameters()
        badName.append("CHAP_N", "imposter")
        badName.append("CHAP_R", good["CHAP_R"]!)
        #expect(throws: NegotiationError.self) { try exchange.verifyMutual(badName) }

        // …and a missing answer fails.
        #expect(throws: NegotiationError.self) { try exchange.verifyMutual(TextParameters()) }
    }

    @Test func rejectsBadChallenge() throws {
        var exchange = CHAP.InitiatorExchange(credentials: .init(name: "u", secret: "s"))
        var missing = TextParameters()
        missing.append("CHAP_A", "5")
        #expect(throws: NegotiationError.self) { try exchange.respond(to: missing) }

        var wrongAlgo = TextParameters()
        wrongAlgo.append("CHAP_A", "7")
        wrongAlgo.append("CHAP_I", "1")
        wrongAlgo.append("CHAP_C", "0x01")
        #expect(throws: NegotiationError.self) { try exchange.respond(to: wrongAlgo) }

        var empty = TextParameters()
        empty.append("CHAP_A", "5")
        empty.append("CHAP_I", "1")
        empty.append("CHAP_C", "0b")
        #expect(throws: NegotiationError.self) { try exchange.respond(to: empty) }
    }
}
