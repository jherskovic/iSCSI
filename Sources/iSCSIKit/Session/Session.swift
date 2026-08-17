import Foundation

/// Things worth telling someone about, which are not errors the caller sees.
///
/// Recovery is deliberately invisible to callers — that is its whole point — but
/// invisible to *operators* is a different thing. A session that quietly rebuilt
/// itself five times and then gave up produced, before this existed, exactly no
/// record: an I/O that never returned, and a log containing only the original
/// login banner. Diagnosing that took hours and ended in a guess.
public enum SessionEvent: Sendable {
    /// The connection dropped; recovery is starting.
    case connectionLost(reason: String)
    case recoveryAttempt(number: Int, of: Int)
    /// Back in business, having rebuilt the session this many times in total.
    case recovered(totalRecoveries: Int)
    /// Gave up. Every subsequent I/O on this session will fail.
    case recoveryExhausted(lastError: String)
}

public enum SessionError: Error, Equatable, Sendable {
    case notActive
    case loggedOut
    case recoveryExhausted(lastError: String)
    case taskFailed(SCSITaskResult)
    case taskTimedOut
}

/// Session-level policy knobs; test suites shrink the timings.
public struct SessionPolicy: Sendable {
    /// NOP keepalive cadence; nil disables the keepalive task.
    public var nopInterval: Duration? = .seconds(10)
    /// A ping unanswered for this long declares the connection dead.
    public var nopTimeout: Duration = .seconds(10)
    /// Re-login attempts after a connection drop (ERL0 session recovery).
    public var maxRecoveryAttempts = 5
    /// Backoff between recovery attempts (doubles per attempt, capped).
    public var recoveryBackoffBase: Duration = .milliseconds(500)
    public var recoveryBackoffCap: Duration = .seconds(30)
    /// Automatic transparent retries of a task interrupted by a connection
    /// drop. Block-layer reads/writes are idempotent, so retry is safe.
    public var taskRetries = 2
    /// A task unanswered for this long is abandoned: aborted at the target,
    /// then retried on a fresh session (bounded by `taskRetries`). nil waits
    /// forever.
    ///
    /// The keepalive does not cover this. A target that accepts commands and
    /// never answers them typically still answers NOPs, so the connection
    /// looks healthy while every I/O hangs — and under Backend A that hang
    /// propagates up through DiskImages into APFS, where it becomes a wedged
    /// volume rather than an error. 30s matches the conventional SCSI command
    /// timeout.
    public var taskTimeout: Duration? = .seconds(30)

    public init() {}
}

/// One iSCSI session: owns the current connection, recovers it on failure
/// (ERL0: drop everything, re-login, resubmit), and runs NOP keepalive.
public actor ISCSISession {
    public typealias TransportFactory = @Sendable () async throws -> any ConnectionTransport

    private let makeTransport: TransportFactory
    private var loginConfig: LoginConfig
    private let policy: SessionPolicy

    private var connection: ISCSIConnection?
    private var loginResult: LoginResult?
    private var keepaliveTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, any Error>?
    private var loggedOut = false
    /// Diagnostics for tests and status reporting.
    public private(set) var recoveryCount = 0

    /// Called for each `SessionEvent`. Set by the daemon to route them into the
    /// unified log; nil everywhere else, so tests and the CLI pay nothing.
    private var onEvent: (@Sendable (SessionEvent) -> Void)?

    public func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void) {
        onEvent = handler
    }

    public init(
        login: LoginConfig,
        policy: SessionPolicy = SessionPolicy(),
        transportFactory: @escaping TransportFactory
    ) {
        self.loginConfig = login
        self.policy = policy
        self.makeTransport = transportFactory
    }

    // MARK: - Lifecycle

    /// Log in (initial activation).
    @discardableResult
    public func activate() async throws -> LoginResult {
        guard connection == nil else { return loginResult! }
        loggedOut = false
        let result = try await establish()
        return result
    }

    public func logout() async throws {
        loggedOut = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        guard let connection else { return }
        _ = try? await connection.logout(reason: .closeSession)
        self.connection = nil
        self.loginResult = nil
    }

    public var parameters: OperationalParameters? {
        get async { loginResult?.parameters }
    }

    // MARK: - SCSI task execution

    /// Execute a task, transparently recovering the session and retrying on
    /// connection loss (bounded by policy).
    public func execute(_ task: SCSITask) async throws -> SCSITaskResult {
        var attempt = 0
        while true {
            let connection = try await ensureActive()
            do {
                return try await withDeadline(policy.taskTimeout) {
                    try await connection.execute(task)
                }
            } catch let error as ConnectionError {
                try Task.checkCancellation()
                guard !loggedOut, attempt < policy.taskRetries else { throw error }
                attempt += 1
                // The connection died (or the target killed it). Recover and
                // resubmit — safe for block I/O, which is idempotent.
                try await recover(after: error)
            } catch is DeadlineError {
                try Task.checkCancellation()
                // The deadline cancelled the task, which aborted it at the
                // target. Resubmitting on the same connection would just wait
                // out another timeout: a target that swallows commands is not
                // persuaded by a second one. Re-login instead — and if that
                // does not help either, drop the connection so the *next*
                // caller starts fresh rather than queueing behind the wedge,
                // and surface the failure so the layers above see an error
                // instead of hanging forever.
                guard !loggedOut, attempt < policy.taskRetries else {
                    await dropConnection()
                    throw SessionError.taskTimedOut
                }
                attempt += 1
                try await recover(after: nil)
            }
        }
    }

    /// Execute and require GOOD status, else throw with sense attached.
    public func executeChecked(_ task: SCSITask) async throws -> SCSITaskResult {
        let result = try await execute(task)
        guard result.isGood else { throw SessionError.taskFailed(result) }
        return result
    }

    public func taskManagement(
        _ function: TMFRequestPDU.Function,
        lun: UInt64,
        referencedTaskTag: UInt32 = 0xFFFF_FFFF
    ) async throws -> TMFResponsePDU.Response {
        let connection = try await ensureActive()
        do {
            return try await withDeadline(policy.taskTimeout) {
                try await connection.taskManagement(
                    function, lun: lun, referencedTaskTag: referencedTaskTag
                )
            }
        } catch is DeadlineError {
            throw SessionError.taskTimedOut
        }
    }

    public func ping() async throws {
        let connection = try await ensureActive()
        try await withDeadline(policy.nopTimeout) {
            try await connection.ping()
        }
    }

    // MARK: - Recovery

    private func ensureActive() async throws -> ISCSIConnection {
        if loggedOut { throw SessionError.loggedOut }
        if let connection { return connection }
        try await recover(after: nil)
        guard let connection else { throw SessionError.notActive }
        return connection
    }

    @discardableResult
    private func establish() async throws -> LoginResult {
        let transport = try await makeTransport()
        let conn = ISCSIConnection(transport: transport, login: loginConfig)
        do {
            let result = try await conn.login()
            connection = conn
            loginResult = result
            startKeepalive(for: conn)
            watchForClose(of: conn)
            return result
        } catch let ConnectionError.redirected(address, _) {
            // Follow one level of redirect immediately.
            throw ConnectionError.redirected(address: address, permanent: false)
        }
    }

    /// Tear the connection down without re-logging in. The next call to
    /// `ensureActive` builds a fresh session, so a wedge is not inherited by
    /// whoever comes next.
    private func dropConnection() async {
        guard let old = connection else { return }
        connection = nil
        loginResult = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        await old.close()
    }

    /// ERL0 session recovery: tear down, back off, re-login. Coalesces
    /// concurrent callers onto a single recovery task.
    private func recover(after error: ConnectionError?) async throws {
        if let existing = recoveryTask {
            try await existing.value
            return
        }
        onEvent?(.connectionLost(reason: error.map { "\($0)" } ?? "no active connection"))
        if let old = connection {
            connection = nil
            loginResult = nil
            await old.close()
        }
        keepaliveTask?.cancel()
        keepaliveTask = nil

        let task = Task { [policy, onEvent] in
            var lastError = error.map { "\($0)" } ?? "initial"
            for attempt in 0 ..< policy.maxRecoveryAttempts {
                onEvent?(.recoveryAttempt(number: attempt + 1,
                                          of: policy.maxRecoveryAttempts))
                if attempt > 0 || error != nil {
                    let factor = 1 << min(attempt, 8)
                    let delay = min(
                        policy.recoveryBackoffBase * factor,
                        policy.recoveryBackoffCap
                    )
                    try await Task.sleep(for: delay)
                }
                try Task.checkCancellation()
                do {
                    _ = try await self.establishForRecovery()
                    onEvent?(.recovered(totalRecoveries: await self.recoveryCount))
                    return
                } catch {
                    lastError = "\(error)"
                }
            }
            onEvent?(.recoveryExhausted(lastError: lastError))
            throw SessionError.recoveryExhausted(lastError: lastError)
        }
        recoveryTask = task
        defer { recoveryTask = nil }
        try await task.value
    }

    private func establishForRecovery() async throws {
        // A recovered session is a new session: fresh ISID qualifier keeps
        // targets from confusing it with the half-dead old one.
        loginConfig.isid = .random()
        loginConfig.tsih = 0
        _ = try await establish()
        recoveryCount += 1
    }

    private func startKeepalive(for connection: ISCSIConnection) {
        guard let interval = policy.nopInterval else { return }
        keepaliveTask = Task { [policy] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                do {
                    try await withDeadline(policy.nopTimeout) {
                        try await connection.ping()
                    }
                } catch {
                    // Dead peer: kill the connection; execute() paths recover.
                    await connection.close()
                    return
                }
            }
        }
    }

    private func watchForClose(of connection: ISCSIConnection) {
        Task { [weak self] in
            _ = await connection.waitClosed()
            await self?.noteClosed(connection)
        }
    }

    private func noteClosed(_ closed: ISCSIConnection) {
        if connection === closed {
            connection = nil
            loginResult = nil
            keepaliveTask?.cancel()
            keepaliveTask = nil
        }
    }
}

// MARK: - Discovery

/// One record from a SendTargets response.
public struct DiscoveredTarget: Sendable, Equatable {
    public var name: String
    /// "host:port,tpgt" entries; may be empty when the target only answers
    /// on the portal we asked.
    public var addresses: [String]
}

public enum Discovery {
    /// Run a discovery session on `transport`: login (type Discovery),
    /// SendTargets=All, logout. Returns the advertised targets.
    public static func sendTargets(
        transport: any ConnectionTransport,
        initiatorName: String,
        chap: CHAP.Credentials? = nil,
        trace: (@Sendable (String) -> Void)? = nil
    ) async throws -> [DiscoveredTarget] {
        var config = LoginConfig(initiatorName: initiatorName, sessionType: .discovery,
                                 chap: chap, trace: trace)
        config.desired.offerDigests = false
        let connection = ISCSIConnection(transport: transport, login: config)
        _ = try await connection.login()
        var request = TextParameters()
        request.append("SendTargets", "All")
        let response = try await connection.textExchange(request)
        _ = try? await connection.logout(reason: .closeSession)
        return parse(response)
    }

    static func parse(_ params: TextParameters) -> [DiscoveredTarget] {
        var result: [DiscoveredTarget] = []
        for (key, value) in params.pairs {
            switch key {
            case "TargetName":
                result.append(DiscoveredTarget(name: value, addresses: []))
            case "TargetAddress":
                if !result.isEmpty {
                    result[result.count - 1].addresses.append(value)
                }
            default:
                break
            }
        }
        return result
    }
}
