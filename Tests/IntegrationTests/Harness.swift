import Foundation
import Testing
@testable import MockTarget
@testable import iSCSIKit

/// One running MockTarget endpoint wired to an initiator-side transport.
struct TargetHarness {
    let transport: MemoryPipe
    let target: MockTarget
    let serveTask: Task<Void, Never>

    static func start(
        config: MockTargetConfig = MockTargetConfig(),
        disk: RAMDisk? = nil
    ) -> TargetHarness {
        let (initiatorSide, targetSide) = MemoryPipe.pair()
        let target = MockTarget(config: config, disk: disk, transport: targetSide)
        let serve = Task { await target.run() }
        return TargetHarness(transport: initiatorSide, target: target, serveTask: serve)
    }
}

func standardLogin(
    targetName: String = "iqn.2026-08.test.example:disk0",
    chap: CHAP.Credentials? = nil,
    tune: (inout LoginConfig) -> Void = { _ in }
) -> LoginConfig {
    var config = LoginConfig(
        initiatorName: "iqn.2026-08.com.example:initiator",
        sessionType: .normal,
        targetName: targetName,
        chap: chap
    )
    config.desired.offerDigests = false
    tune(&config)
    return config
}

/// Convenience: fresh target + logged-in connection.
func loggedInConnection(
    targetConfig: MockTargetConfig = MockTargetConfig(),
    disk: RAMDisk? = nil,
    chap: CHAP.Credentials? = nil,
    tune: (inout LoginConfig) -> Void = { _ in }
) async throws -> (ISCSIConnection, TargetHarness, LoginResult) {
    let harness = TargetHarness.start(config: targetConfig, disk: disk)
    let connection = ISCSIConnection(
        transport: harness.transport,
        login: standardLogin(targetName: targetConfig.targetName, chap: chap, tune: tune)
    )
    let result = try await connection.login()
    return (connection, harness, result)
}

/// Session policy tuned for fast tests.
func testPolicy(
    retries: Int = 2,
    recoveryAttempts: Int = 4,
    nopInterval: Duration? = nil
) -> SessionPolicy {
    var policy = SessionPolicy()
    policy.nopInterval = nopInterval
    policy.nopTimeout = .milliseconds(250)
    policy.maxRecoveryAttempts = recoveryAttempts
    policy.recoveryBackoffBase = .milliseconds(10)
    policy.recoveryBackoffCap = .milliseconds(50)
    policy.taskRetries = retries
    return policy
}
