//
//  CredentialHygieneTests.swift
//  Secrets must not be loggable, and must not be silently absent.
//

import Foundation
import Testing
@testable import iSCSIKit

@Suite("Credential hygiene")
struct CredentialHygieneTests {

    // MARK: - Tracing must not print the CHAP triple

    /// Builds a Text PDU carrying the given keys, pushes it through the tracing
    /// transport's real send path, and returns everything the sink received.
    private func traced(_ pairs: [(String, String)]) async throws -> String {
        var text = TextParameters()
        for (k, v) in pairs { text.append(k, v) }
        var pdu = TextResponsePDU()
        pdu.dataSegment = text.encode()
        let bytes = PDUSerializer().serialize(pdu)

        let sink = Captured()
        let transport = TracingTransport(NullTransport(), label: "test") { sink.append($0) }
        try await transport.send(bytes)
        return sink.text
    }

    /// The sink is `@Sendable`, so the capture needs its own synchronisation.
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    /// The exact scenario: a user hits a login problem, is told to run with
    /// `--debug`, and attaches the output to a bug report. Before this, that
    /// published `CHAP_I`, `CHAP_C` and `CHAP_R` — the complete input to an
    /// offline attack on their SAN password.
    @Test("a traced CHAP exchange discloses no challenge, response or user name")
    func chapValuesAreRedacted() async throws {
        let secretish = "0x8f1e2d3c4b5a69780f1e2d3c4b5a6978"
        let out = try await traced([
            ("CHAP_A", "5"),
            ("CHAP_I", "42"),
            ("CHAP_C", secretish),
            ("CHAP_N", "backup-user"),
            ("CHAP_R", secretish),
        ])
        #expect(!out.contains(secretish), "the challenge and response must not appear")
        #expect(!out.contains("backup-user"), "the CHAP user name must not appear")
        #expect(out.contains("redacted"), "and the trace should say it withheld something")
    }

    /// Redaction has to leave the trace worth reading, or it will be turned off.
    @Test("non-sensitive negotiation keys are still shown in full")
    func ordinaryKeysAreNotRedacted() async throws {
        let out = try await traced([
            ("HeaderDigest", "CRC32C"),
            ("MaxRecvDataSegmentLength", "262144"),
            ("TargetName", "iqn.2026-08.com.example:disk0"),
        ])
        #expect(out.contains("CRC32C"))
        #expect(out.contains("262144"))
        #expect(out.contains("iqn.2026-08.com.example:disk0"))
    }

    // MARK: - A missing secret is an error, not an empty one

    @Test("an empty secret is refused rather than hashed")
    func emptySecretRefused() {
        // This produced MD5(id ‖ "" ‖ challenge): a complete, well-formed
        // exchange whose only content is the news that the secret is empty.
        #expect(throws: CHAP.CredentialError.self) {
            _ = try CHAP.Credentials.validated(name: "backup", secret: "")
        }
    }

    @Test("a secret below the RFC minimum is refused")
    func shortSecretRefused() {
        #expect(throws: CHAP.CredentialError.self) {
            _ = try CHAP.Credentials.validated(name: "backup", secret: "hunter2")
        }
    }

    @Test("a mutual secret is held to the same minimum")
    func shortMutualSecretRefused() {
        #expect(throws: CHAP.CredentialError.self) {
            _ = try CHAP.Credentials.validated(
                name: "backup", secret: "long-enough-secret",
                mutualName: "target", mutualSecret: "short")
        }
    }

    @Test("a conforming pair is accepted and enables mutual CHAP")
    func validPairAccepted() throws {
        let c = try CHAP.Credentials.validated(
            name: "backup", secret: "twelve-chars-at-least",
            mutualName: "target", mutualSecret: "also-twelve-chars")
        #expect(c.wantsMutual, "a stored mutual secret must actually turn mutual CHAP on")
        #expect(c.mutualName == "target")
    }

    @Test("an empty user name is refused")
    func emptyNameRefused() {
        #expect(throws: CHAP.CredentialError.self) {
            _ = try CHAP.Credentials.validated(name: "", secret: "twelve-chars-at-least")
        }
    }
}

/// Stands in for a socket: the tracer only needs something to wrap.
private struct NullTransport: ConnectionTransport {
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? { nil }
    func close() async {}
}
