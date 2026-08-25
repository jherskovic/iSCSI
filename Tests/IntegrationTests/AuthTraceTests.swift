import Foundation
import Testing
@testable import iSCSIKit
@testable import MockTarget

/// The authentication trace exists because a redacted PDU dump cannot say what
/// the initiator was *trying* to do — one-way or mutual, as whom, and how far it
/// got before the target said no.
///
/// The second suite matters most: the daemon wires the sink to `os.Logger`,
/// so anything written outlives the connection — and a logged `CHAP_R` is an
/// offline attack on the secret handed to whoever reads the log.
@Suite("Authentication trace")
struct AuthTraceTests {
    /// Collects trace lines from whatever actor the login is running on.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        var emit: @Sendable (String) -> Void {
            { [self] message in
                lock.lock(); defer { lock.unlock() }
                lines.append(message)
            }
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }

        var joined: String { all.joined(separator: "\n") }
    }

    @Test func mutualLoginNarratesBothHalves() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "initiator-user"
        targetConfig.chapSecret = "initiator-secret-alpha"
        targetConfig.mutualName = "peer-user"
        targetConfig.mutualSecret = "peer-secret-bravo"

        let sink = Sink()
        let (connection, harness, _) = try await loggedInConnection(
            targetConfig: targetConfig,
            chap: CHAP.Credentials(
                name: "initiator-user", secret: "initiator-secret-alpha",
                mutualName: "peer-user", mutualSecret: "peer-secret-bravo"
            ),
            tune: { $0.trace = sink.emit }
        )
        defer { harness.serveTask.cancel() }
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))

        let trace = sink.joined
        // Which half was attempted, which is exactly what a rejection three PDUs
        // later cannot tell you on its own.
        #expect(trace.contains("mutual=yes"))
        #expect(trace.contains("challenging the target back"))
        #expect(trace.contains("mutual CHAP verified"))
    }

    @Test func oneWayLoginSaysItIsNotChallengingBack() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "initiator-user"
        targetConfig.chapSecret = "initiator-secret-alpha"

        let sink = Sink()
        let (connection, harness, _) = try await loggedInConnection(
            targetConfig: targetConfig,
            chap: CHAP.Credentials(name: "initiator-user", secret: "initiator-secret-alpha"),
            tune: { $0.trace = sink.emit }
        )
        defer { harness.serveTask.cancel() }
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))

        #expect(sink.joined.contains("mutual=no"))
        #expect(sink.joined.contains("one-way"))
    }

    /// An unauthenticated session is indistinguishable from an authenticated one
    /// at every layer above the login, which is why it gets a line of its own.
    @Test func unauthenticatedLoginAnnouncesItself() async throws {
        let sink = Sink()
        let (connection, harness, _) = try await loggedInConnection(
            tune: { $0.trace = sink.emit }
        )
        defer { harness.serveTask.cancel() }
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))

        #expect(sink.joined.contains("AuthMethod=None"))
        #expect(sink.joined.contains("no credentials configured"))
    }

    @Test func rejectionNamesTheStageAndTheStatusCode() async throws {
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "initiator-user"
        targetConfig.chapSecret = "the-right-secret"

        let sink = Sink()
        let harness = TargetHarness.start(config: targetConfig)
        defer { harness.serveTask.cancel() }
        let connection = ISCSIConnection(
            transport: harness.transport,
            login: standardLogin(
                targetName: targetConfig.targetName,
                chap: CHAP.Credentials(name: "initiator-user", secret: "the-wrong-secret"),
                tune: { $0.trace = sink.emit }
            )
        )
        await #expect(throws: ConnectionError.self) { _ = try await connection.login() }

        let trace = sink.joined
        // "0x02/0x01" alone reads as an initiator-credentials problem to
        // everyone; the stage is what says whether a secret was even involved.
        #expect(trace.contains("authentication failure"))
        #expect(trace.contains("awaiting CHAP result"))
    }

    // MARK: - What must never appear

    /// Runs a full mutual login and asserts the sink never saw key material.
    /// Deliberately checks the *derived* value too: redacting the secret and
    /// then logging `CHAP_R` would leak the same thing one MD5 later.
    @Test func traceNeverCarriesSecretsOrResponses() async throws {
        let initiatorSecret = "initiator-secret-alpha"
        let peerSecret = "peer-secret-bravo"

        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "initiator-user"
        targetConfig.chapSecret = initiatorSecret
        targetConfig.mutualName = "peer-user"
        targetConfig.mutualSecret = peerSecret

        let sink = Sink()
        let (connection, harness, _) = try await loggedInConnection(
            targetConfig: targetConfig,
            chap: CHAP.Credentials(
                name: "initiator-user", secret: initiatorSecret,
                mutualName: "peer-user", mutualSecret: peerSecret
            ),
            tune: { $0.trace = sink.emit }
        )
        defer { harness.serveTask.cancel() }
        _ = try await connection.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))

        let trace = sink.joined
        #expect(!trace.contains(initiatorSecret))
        #expect(!trace.contains(peerSecret))
        // Challenges and responses are logged by shape or not at all. A literal
        // "0x..." after either key means someone started printing the value.
        #expect(!trace.contains("CHAP_R=0x"))
        #expect(!trace.contains("CHAP_C=0x"))
        // The trace did run — otherwise the assertions above pass vacuously and
        // this test would keep passing after the sink was disconnected.
        #expect(trace.contains("mutual CHAP verified"))
    }

    @Test func aRejectedLoginAlsoLeaksNothing() async throws {
        let secret = "the-right-secret-charlie"
        var targetConfig = MockTargetConfig()
        targetConfig.requireChap = true
        targetConfig.chapUser = "initiator-user"
        targetConfig.chapSecret = secret

        let sink = Sink()
        let harness = TargetHarness.start(config: targetConfig)
        defer { harness.serveTask.cancel() }
        let connection = ISCSIConnection(
            transport: harness.transport,
            login: standardLogin(
                targetName: targetConfig.targetName,
                chap: CHAP.Credentials(name: "initiator-user", secret: "wrong-secret-delta"),
                tune: { $0.trace = sink.emit }
            )
        )
        await #expect(throws: ConnectionError.self) { _ = try await connection.login() }

        let trace = sink.joined
        #expect(!trace.contains("wrong-secret-delta"))
        #expect(!trace.contains(secret))
        #expect(!trace.contains("CHAP_R=0x"))
        #expect(trace.contains("authentication failure"))
    }
}
