import Foundation

/// Things worth telling someone about, which are not errors the caller sees.
/// Recovery is invisible to callers by design; it must not be invisible to
/// operators too.
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
    /// forever. The keepalive does not cover this — a target that swallows
    /// commands usually still answers NOPs. 30s is the conventional SCSI
    /// command timeout.
    public var taskTimeout: Duration? = .seconds(30)
    /// How long a target that accepted the connection gets to finish logging
    /// in: the iSCSI login exchange, or an NVMe/TCP queue's ICReq and Fabrics
    /// Connect. The TCP connect has its own deadline (`NetworkTransport`);
    /// this one starts after it. nil waits forever, which is what every login
    /// did before 2026-11 — and since `taskTimeout` only covers I/O on an
    /// established connection, a target that accepted TCP and then went
    /// quiet hung the attach, and every recovery attempt behind it, with
    /// nothing to give up on. 15 s is open-iscsi's default login timeout.
    public var loginTimeout: Duration? = .seconds(15)
    /// How long a logout waits for the target's response before closing the
    /// connection anyway — the TMF path's five seconds. Bounded because the
    /// extension logs out on unmount, so an unanswered logout is an unmount
    /// that never finishes.
    public var logoutTimeout: Duration = .seconds(5)
    /// RFC 7143 §7.5: after a transport exception, recovery SHOULD NOT begin
    /// before the negotiated DefaultTime2Wait. Tests that script fast
    /// reconnects turn this off.
    public var honorTime2Wait = true

    public init() {}
}

/// One iSCSI session: owns the current connection, recovers it on failure
/// (ERL0: drop everything, re-login, resubmit), and runs NOP keepalive.
public actor ISCSISession {
    public typealias TransportFactory = @Sendable () async throws -> any ConnectionTransport
    /// How to reach a portal a login redirect names. nil: redirects are not
    /// followed and surface as `ConnectionError.redirected`.
    public typealias RedirectTransportFactory = @Sendable (TargetPortal) async throws -> any ConnectionTransport

    private let makeTransport: TransportFactory
    private let makeRedirectTransport: RedirectTransportFactory?
    /// Where logins start when a permanent redirect moved the target (§11.13.5);
    /// nil is the configured portal. A temporary redirect never lands here:
    /// EqualLogic picks the member port per login, so the next login must ask
    /// the group address again.
    private var movedTo: TargetPortal?
    private var loginConfig: LoginConfig
    private let policy: SessionPolicy

    private var connection: ISCSIConnection?
    private var loginResult: LoginResult?
    private var keepaliveTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, any Error>?
    private var loggedOut = false
    /// Latched when recovery gives up: the session is dead until an explicit
    /// `activate()`. Without it every later task re-ran the whole recovery
    /// budget (5 attempts × the connect timeout), so a caller behind a dead
    /// target waited a full cycle only to fail — and the periodic flush tick
    /// re-triggered it forever. The log already promises "every I/O on this
    /// session will now fail"; this makes that true and immediate.
    private var recoveryFailed: SessionError?
    /// DefaultTime2Wait from the most recent login, kept past the connection
    /// teardown so recovery can honor it (§7.5).
    private var lastTime2Wait: UInt32 = 0
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
        transportFactory: @escaping TransportFactory,
        redirectTransportFactory: RedirectTransportFactory? = nil
    ) {
        self.loginConfig = login
        self.policy = policy
        self.makeTransport = transportFactory
        self.makeRedirectTransport = redirectTransportFactory
    }

    // MARK: - Lifecycle

    /// Log in (initial activation).
    @discardableResult
    public func activate() async throws -> LoginResult {
        recoveryFailed = nil
        loggedOut = false
        guard connection == nil else { return loginResult! }
        let result = try await establish()
        return result
    }

    /// Ends the session, including a recovery in progress: without stopping
    /// it, a recovery that was backing off when the user detached logged in
    /// again afterwards and left a live session nothing would ever log out.
    public func logout() async throws {
        loggedOut = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        if let recovery = recoveryTask {
            recovery.cancel()
            _ = try? await recovery.value
        }
        guard let connection else { return }
        // Bounded (`SessionPolicy.logoutTimeout`), and closed either way.
        _ = try? await withDeadline(policy.logoutTimeout, onTimeout: { await connection.close() }) {
            try await connection.logout(reason: .closeSession)
        }
        await connection.close()
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
                try await recover(after: error, on: connection)
            } catch is DeadlineError {
                try Task.checkCancellation()
                // The deadline aborted the task at the target. Re-login rather
                // than resubmit on the same connection; when retries run out,
                // drop the connection so the next caller starts fresh instead
                // of queueing behind the wedge.
                guard !loggedOut, attempt < policy.taskRetries else {
                    await dropConnection()
                    throw SessionError.taskTimedOut
                }
                attempt += 1
                try await recover(after: nil, on: connection)
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
        if let recoveryFailed { throw recoveryFailed }
        if let connection { return connection }
        try await recover(after: nil, on: nil)
        guard let connection else { throw SessionError.notActive }
        return connection
    }

    @discardableResult
    private func establish() async throws -> LoginResult {
        let home = makeTransport
        let redirect = makeRedirectTransport
        let outcome = try await RedirectingLogin.login(
            loginConfig, startingAt: movedTo, followRedirects: redirect != nil,
            loginTimeout: policy.loginTimeout
        ) { portal in
            if let portal, let redirect { return try await redirect(portal) }
            return try await home()
        }
        if let moved = outcome.movedPermanentlyTo { movedTo = moved }
        let conn = outcome.connection
        // Logged out while this login was under way: a session installed now
        // would have nobody to log it out.
        guard !loggedOut else {
            _ = try? await withDeadline(policy.logoutTimeout, onTimeout: { await conn.close() }) {
                try await conn.logout(reason: .closeSession)
            }
            await conn.close()
            throw SessionError.loggedOut
        }
        connection = conn
        loginResult = outcome.result
        lastTime2Wait = outcome.result.parameters.defaultTime2Wait
        startKeepalive(for: conn)
        watchForClose(of: conn)
        return outcome.result
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

    /// The teardown half of recovery. Extracted so it can run *inside* the
    /// recovery task rather than ahead of it — see the note in `recover`.
    private func tearDownForRecovery() async {
        if let old = connection {
            connection = nil
            loginResult = nil
            await old.close()
        }
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// ERL0 session recovery: tear down, back off, re-login. Coalesces
    /// concurrent callers onto a single recovery task.
    ///
    /// `failed` is the connection the caller's attempt ran on, nil when there
    /// was none. If it has already been replaced, someone else's recovery
    /// finished first, and the caller just retries on the new connection:
    /// tearing down whatever is current would reset a healthy session for a
    /// late failure of the old one.
    private func recover(after error: ConnectionError?, on failed: ISCSIConnection?) async throws {
        if let recoveryFailed { throw recoveryFailed }
        if loggedOut { throw SessionError.loggedOut }
        if let existing = recoveryTask {
            try await existing.value
            return
        }
        if let failed, let current = connection, current !== failed { return }
        // `recoveryTask` MUST be assigned before the first suspension point.
        // Actor isolation does not span an `await`: with the teardown out here,
        // a second caller reaching the guard while this one was inside
        // `old.close()` also saw nil, and both re-logged-in. Everything that
        // suspends therefore lives inside the task, which is published
        // synchronously below. The NVMe twin had the same hole and was
        // observed taking it in production — see docs/resilience.md.
        let time2Wait = lastTime2Wait
        let task = Task { [policy, onEvent] in
            onEvent?(.connectionLost(reason: error.map { "\($0)" } ?? "no active connection"))
            await self.tearDownForRecovery()

            var lastError = error.map { "\($0)" } ?? "initial"
            for attempt in 0 ..< policy.maxRecoveryAttempts {
                onEvent?(.recoveryAttempt(number: attempt + 1,
                                          of: policy.maxRecoveryAttempts))
                if attempt > 0 || error != nil {
                    try await Task.sleep(for: Self.recoveryDelay(
                        attempt: attempt, policy: policy, time2Wait: time2Wait))
                }
                try Task.checkCancellation()
                do {
                    _ = try await self.establishForRecovery()
                    onEvent?(.recovered(totalRecoveries: await self.recoveryCount))
                    return
                } catch SessionError.loggedOut {
                    throw SessionError.loggedOut
                } catch {
                    lastError = "\(error)"
                }
            }
            onEvent?(.recoveryExhausted(lastError: lastError))
            throw SessionError.recoveryExhausted(lastError: lastError)
        }
        recoveryTask = task
        defer { recoveryTask = nil }
        do {
            try await task.value
        } catch let failure as SessionError {
            if case .recoveryExhausted = failure { recoveryFailed = failure }
            throw failure
        } catch {
            // Cancelled by `logout`: say so, not "cancelled".
            if loggedOut { throw SessionError.loggedOut }
            throw error
        }
    }

    /// Delay before recovery attempt `attempt` (0-based). The first attempt
    /// respects the negotiated DefaultTime2Wait (§7.5); later attempts are
    /// already past that respite and use plain exponential backoff.
    ///
    /// Time2Wait is the target's to declare, up to 3600 s, and every I/O
    /// waits behind it; so it is honoured only up to `recoveryBackoffCap`.
    /// An hour's stall on one drop is the wedge the timeouts exist to prevent.
    static func recoveryDelay(attempt: Int, policy: SessionPolicy, time2Wait: UInt32) -> Duration {
        let factor = 1 << min(attempt, 8)
        let backoff = min(policy.recoveryBackoffBase * factor, policy.recoveryBackoffCap)
        guard attempt == 0, policy.honorTime2Wait, time2Wait > 0 else { return backoff }
        return max(backoff, min(.seconds(Int(time2Wait)), policy.recoveryBackoffCap))
    }

    private func establishForRecovery() async throws {
        // A recovered session is a new session: a fresh random ISID keeps
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

    public init(name: String, addresses: [String]) {
        self.name = name
        self.addresses = addresses
    }
}

public enum Discovery {
    /// Run a discovery session on `transport`: login (type Discovery),
    /// SendTargets=All, logout. Returns the advertised targets.
    ///
    /// `timeout` bounds the login and the SendTargets exchange together; a
    /// target that answers neither has its connection closed and the call
    /// throws `DeadlineError.timedOut`. nil waits as long as the target does.
    public static func sendTargets(
        transport: any ConnectionTransport,
        initiatorName: String,
        chap: CHAP.Credentials? = nil,
        timeout: Duration? = SessionPolicy().loginTimeout,
        trace: (@Sendable (String) -> Void)? = nil
    ) async throws -> [DiscoveredTarget] {
        var config = LoginConfig(initiatorName: initiatorName, sessionType: .discovery,
                                 chap: chap, trace: trace)
        config.desired.offerDigests = false
        let connection = ISCSIConnection(transport: transport, login: config)
        let response: TextParameters
        do {
            response = try await withDeadline(timeout, onTimeout: { await connection.close() }) {
                _ = try await connection.login()
                var request = TextParameters()
                request.append("SendTargets", "All")
                return try await connection.textExchange(request)
            }
        } catch {
            await connection.close()
            throw error
        }
        _ = try? await withDeadline(SessionPolicy().logoutTimeout, onTimeout: { await connection.close() }) {
            try await connection.logout(reason: .closeSession)
        }
        await connection.close()
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
