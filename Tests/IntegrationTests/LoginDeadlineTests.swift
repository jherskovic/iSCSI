import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// A target that accepts the connection and then says nothing. `taskTimeout`
/// covers I/O on an established connection only, so before
/// `SessionPolicy.loginTimeout` this hung the attach — and every recovery
/// attempt behind it — for as long as the peer stayed quiet.
@Suite("Integration: login and bring-up deadlines", .timeLimit(.minutes(1)))
struct LoginDeadlineTests {
    /// Hands out connections whose far end never answers, and keeps those ends
    /// so a test can see the initiator closed them.
    actor SilentPeers {
        private(set) var peers: [MemoryPipe] = []

        func makeTransport() -> any ConnectionTransport {
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            peers.append(targetSide)
            return initiatorSide
        }

        /// True once every peer has read to EOF — the initiator closed it,
        /// which is what ends an abandoned login instead of leaking it.
        func allClosed() async throws -> Bool {
            for peer in peers {
                while let chunk = try await peer.receive() { _ = chunk }
            }
            return !peers.isEmpty
        }
    }

    private func policy(loginTimeout: Duration = .milliseconds(200), attempts: Int = 2) -> SessionPolicy {
        var policy = testPolicy(retries: 1, recoveryAttempts: attempts)
        policy.loginTimeout = loginTimeout
        return policy
    }

    @Test func anISCSILoginNobodyAnswersTimesOutAndClosesTheConnection() async throws {
        let silent = SilentPeers()
        let session = ISCSISession(login: standardLogin(), policy: policy()) {
            await silent.makeTransport()
        }
        await #expect(throws: DeadlineError.timedOut) { try await session.activate() }
        #expect(try await silent.allClosed())
    }

    @Test func recoveryIntoASilentTargetExhaustsInsteadOfHanging() async throws {
        // The first connection is healthy; after it drops, every portal the
        // session can reach accepts TCP and never answers the login.
        actor Script {
            let fleet = TargetFleet(disk: RAMDisk(), configs: [MockTargetConfig()])
            let silent = SilentPeers()
            var calls = 0
            func makeTransport() async -> any ConnectionTransport {
                calls += 1
                return calls == 1 ? await fleet.makeTransport() : await silent.makeTransport()
            }
        }
        let script = Script()
        let session = ISCSISession(login: standardLogin(), policy: policy(attempts: 2)) {
            await script.makeTransport()
        }
        try await session.activate()
        await script.fleet.shutdown()

        await #expect(throws: SessionError.self) {
            _ = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        }
        #expect(await script.calls == 3)   // the healthy login, then both attempts
        #expect(try await script.silent.allClosed())
    }

    @Test func sendTargetsAgainstASilentPortalTimesOut() async throws {
        let silent = SilentPeers()
        await #expect(throws: DeadlineError.timedOut) {
            _ = try await Discovery.sendTargets(
                transport: await silent.makeTransport(),
                initiatorName: "iqn.2026-08.com.example:initiator",
                timeout: .milliseconds(200))
        }
        #expect(try await silent.allClosed())
    }

    @Test func aLogoutTheTargetIgnoresStillFinishes() async throws {
        var config = MockTargetConfig()
        config.faults.swallowLogout = true
        let fleet = TargetFleet(disk: RAMDisk(), configs: [config])
        var policy = policy()
        policy.logoutTimeout = .milliseconds(200)
        let session = ISCSISession(login: standardLogin(), policy: policy) {
            await fleet.makeTransport()
        }
        try await session.activate()
        let started = ContinuousClock.now
        try await session.logout()
        #expect(ContinuousClock.now - started < .seconds(2))
        await fleet.shutdown()
    }

    @Test func anNVMeControllerThatNeverSendsICRespTimesOut() async throws {
        let silent = SilentPeers()
        let controller = NVMeController(config: testControllerConfig(), policy: policy()) {
            await silent.makeTransport()
        }
        await #expect(throws: DeadlineError.timedOut) { try await controller.activate() }
        #expect(try await silent.allClosed())
    }

    @Test func anNVMeControllerThatStallsAfterConnectTimesOut() async throws {
        // ICResp, Fabrics Connect and the property commands are answered;
        // Identify, the first admin command, never is.
        var config = MockNVMeConfig()
        config.faults.stallCommands = true
        let fleet = NVMeFleet(config: config)
        let controller = NVMeController(config: testControllerConfig(), policy: policy()) {
            await fleet.makeTransport()
        }
        await #expect(throws: DeadlineError.timedOut) { try await controller.activate() }
        await fleet.shutdown()
    }

    @Test func nvmeDiscoveryAgainstASilentPortalTimesOut() async throws {
        let silent = SilentPeers()
        await #expect(throws: DeadlineError.timedOut) {
            _ = try await NVMeDiscovery.getLogPage(
                transport: await silent.makeTransport(), host: testHost,
                timeout: .milliseconds(200))
        }
        #expect(try await silent.allClosed())
    }
}
