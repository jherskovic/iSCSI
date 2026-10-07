import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

/// Login redirects (RFC 7143 §11.13.5, status class 1). An EqualLogic group
/// answers every normal login on its group address with "moved temporarily"
/// and a member port; an initiator that only reports the redirect can never
/// attach to one at all.
@Suite("Integration: login redirects", .timeLimit(.minutes(1)))
struct LoginRedirectTests {

    /// Which portal each connect was for: "home" for the configured portal,
    /// "host:port" for a redirect.
    final class ConnectLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    static let member = "10.0.0.2:3261,1"

    static func redirecting(temporary: Bool, to address: String = member) -> MockTargetConfig {
        var config = MockTargetConfig()
        config.faults.redirectTo = address
        config.faults.redirectIsTemporary = temporary
        return config
    }

    static func dropping() -> MockTargetConfig {
        var config = MockTargetConfig()
        config.faults.dropAfterSentPDUs = 1
        return config
    }

    /// Both factories draw from one fleet, so the configs are consumed in
    /// connect order whichever portal the connect was for.
    func makeSession(fleet: TargetFleet, log: ConnectLog,
                     followsRedirects: Bool = true) -> ISCSISession {
        let redirect: ISCSISession.RedirectTransportFactory? = followsRedirects
            ? { @Sendable portal in
                log.add("\(portal.host):\(portal.port)")
                return await fleet.makeTransport()
            }
            : nil
        return ISCSISession(
            login: standardLogin(),
            policy: testPolicy(),
            transportFactory: {
                log.add("home")
                return await fleet.makeTransport()
            },
            redirectTransportFactory: redirect
        )
    }

    @Test("a temporary redirect is followed to the address it names")
    func followsTemporaryRedirect() async throws {
        let fleet = TargetFleet(configs: [Self.redirecting(temporary: true), MockTargetConfig()])
        let log = ConnectLog()
        let session = makeSession(fleet: fleet, log: log)
        try await session.activate()

        #expect(log.all == ["home", "10.0.0.2:3261"])
        let ready = try await session.execute(SCSITask(lun: 0, cdb: CDB.testUnitReady()))
        #expect(ready.isGood)
        try await session.logout()
        await fleet.shutdown()
    }

    /// Temporary means this login only: EqualLogic picks the member per
    /// login, so a recovery that went straight back to the old member would
    /// defeat its load balancing and fail outright once that port moves.
    @Test("recovery after a temporary redirect starts again at the configured portal")
    func recoveryReturnsHomeAfterTemporaryRedirect() async throws {
        let fleet = TargetFleet(configs: [
            Self.redirecting(temporary: true), Self.dropping(),
            Self.redirecting(temporary: true), MockTargetConfig(),
        ])
        let log = ConnectLog()
        let session = makeSession(fleet: fleet, log: log)
        try await session.activate()

        let pattern = Data(repeating: 0x5A, count: 512)
        _ = try await session.execute(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 3, blocks: 1), direction: .write(pattern)))
        let read = try await session.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 3, blocks: 1), direction: .read(expectedLength: 512)))
        #expect(read.data == pattern)

        #expect(log.all == ["home", "10.0.0.2:3261", "home", "10.0.0.2:3261"])
        try await session.logout()
        await fleet.shutdown()
    }

    /// §11.13.5: a permanent move is where the target now lives, so later
    /// logins in this session go there directly.
    @Test("recovery after a permanent redirect goes straight to the new address")
    func recoveryKeepsPermanentRedirect() async throws {
        let fleet = TargetFleet(configs: [
            Self.redirecting(temporary: false), Self.dropping(), MockTargetConfig(),
        ])
        let log = ConnectLog()
        let session = makeSession(fleet: fleet, log: log)
        try await session.activate()

        let pattern = Data(repeating: 0xA5, count: 512)
        _ = try await session.execute(SCSITask(
            lun: 0, cdb: CDB.write16(lba: 4, blocks: 1), direction: .write(pattern)))
        let read = try await session.execute(SCSITask(
            lun: 0, cdb: CDB.read16(lba: 4, blocks: 1), direction: .read(expectedLength: 512)))
        #expect(read.data == pattern)

        #expect(log.all == ["home", "10.0.0.2:3261", "10.0.0.2:3261"])
        try await session.logout()
        await fleet.shutdown()
    }

    @Test("a redirect loop gives up after a bounded number of hops")
    func redirectLoopIsBounded() async throws {
        let fleet = TargetFleet(configs: [Self.redirecting(temporary: true)])
        let log = ConnectLog()
        let session = makeSession(fleet: fleet, log: log)

        await #expect(throws: ConnectionError.self) { try await session.activate() }
        #expect(log.all.count == 1 + ISCSISession.maxRedirects)
        await fleet.shutdown()
    }

    @Test("an unreadable TargetAddress surfaces the redirect instead of guessing")
    func unparseableAddressSurfaces() async throws {
        let fleet = TargetFleet(configs: [Self.redirecting(temporary: true, to: "[fe80::1")])
        let log = ConnectLog()
        let session = makeSession(fleet: fleet, log: log)

        do {
            try await session.activate()
            Issue.record("expected the redirect to surface")
        } catch ConnectionError.redirected(let address, _) {
            #expect(address == "[fe80::1")
        }
        #expect(log.all == ["home"])
        await fleet.shutdown()
    }

    /// Guards the existing contract for callers that cannot open a
    /// connection to an arbitrary address (iscsictl's single transport).
    @Test("without a redirect factory the redirect surfaces as before")
    func noFactorySurfaces() async throws {
        let fleet = TargetFleet(configs: [Self.redirecting(temporary: true)])
        let log = ConnectLog()
        let session = makeSession(fleet: fleet, log: log, followsRedirects: false)

        do {
            try await session.activate()
            Issue.record("expected the redirect to surface")
        } catch ConnectionError.redirected(let address, _) {
            #expect(address == Self.member)
        }
        #expect(log.all == ["home"])
        await fleet.shutdown()
    }

    // MARK: Through the daemon

    /// The redirect connect is the daemon's to make, with the target's
    /// interface pin: a pinned target that followed a redirect over whatever
    /// interface macOS chose would quietly undo the pin.
    @Test("the daemon follows a redirect over the same interface pin")
    func daemonFollowsRedirectWithPin() async throws {
        let calls = ConnectLog()
        let harnesses = HarnessBox()
        defer { harnesses.cancelAll() }
        let disk = RAMDisk()
        let pinned = InterfaceBinding(name: "en18", fallback: false)
        let core = DaemonCore(initiatorName: "iqn.test:initiator", policy: testPolicy(),
                              hostIdentity: testHost) { host, port, binding in
            calls.add("\(host):\(port) via \(binding?.name ?? "routing")")
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let config = host == "group" ? Self.redirecting(temporary: true) : MockTargetConfig()
            let target = MockTarget(config: config, disk: disk, transport: targetSide)
            harnesses.add(Task { await target.run() })
            return initiatorSide
        }

        let handle = try await core.login(host: "group", port: 3260, targetIQN: spyIQN,
                                          lun: 0, binding: pinned)
        #expect(calls.all == ["group:3260 via en18", "10.0.0.2:3261 via en18"])
        try await core.logout(handle)
    }
}
