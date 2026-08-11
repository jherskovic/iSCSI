import Foundation
import Testing
@testable import iSCSIKit

@Suite("Text key=value parameters")
struct TextParametersTests {
    @Test func encodeDecodeRoundTrip() throws {
        var params = TextParameters()
        params.append("InitiatorName", "iqn.2026-08.com.example:mac")
        params.append("SessionType", "Normal")
        params.append("HeaderDigest", "CRC32C,None")
        let decoded = try TextParameters.decode(params.encode())
        #expect(decoded == params)
    }

    @Test func wireFormat() {
        var params = TextParameters()
        params.append("A", "b")
        params.append("C", "d")
        #expect(params.encode() == Data("A=b\0C=d\0".utf8))
    }

    @Test func emptyValueAllowed() throws {
        let decoded = try TextParameters.decode(Data("X=\0".utf8))
        #expect(decoded["X"] == "")
    }

    @Test func unterminatedFinalPairTolerated() throws {
        let decoded = try TextParameters.decode(Data("A=1\0B=2".utf8))
        #expect(decoded["B"] == "2")
        #expect(throws: PDUError.self) {
            try TextParameters.decode(Data("A=1\0B=2".utf8), allowUnterminatedFinal: false)
        }
    }

    @Test func missingEqualsRejected() {
        #expect(throws: PDUError.self) { try TextParameters.decode(Data("NoEquals\0".utf8)) }
    }

    @Test func emptyKeyRejected() {
        #expect(throws: PDUError.self) { try TextParameters.decode(Data("=v\0".utf8)) }
    }

    @Test func valueMayContainEquals() throws {
        // CHAP_R=0x1234 style values, and base64 '=' padding, must survive.
        let decoded = try TextParameters.decode(Data("CHAP_R=dGVzdA==\0".utf8))
        #expect(decoded["CHAP_R"] == "dGVzdA==")
    }

    @Test func orderPreservedAndSubscriptUpdates() {
        var params = TextParameters()
        params.append("K1", "a")
        params.append("K2", "b")
        params["K1"] = "c"
        #expect(params.keys == ["K1", "K2"])
        #expect(params["K1"] == "c")
        params["K3"] = "new"
        #expect(params.keys.last == "K3")
    }

    @Test func emptyBuffer() throws {
        let decoded = try TextParameters.decode(Data())
        #expect(decoded.isEmpty)
    }
}
