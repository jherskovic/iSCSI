import Foundation
import Testing
@testable import iSCSIKit

/// The decision behind interface pinning, with no network: which addresses a
/// pin binds and connects to, and when strict fails versus prefer falls back.
/// The real socket behaviour is in LoopbackTCPTests.
@Suite("Interface pinning policy")
struct InterfacePinningTests {

    private static let storage = InterfaceSnapshot(
        present: ["lo0", "en0", "en18"],
        addresses: [
            InterfaceAddress(name: "en18", address: "fe80::1%en18", isIPv6: true),
            InterfaceAddress(name: "en18", address: "192.168.20.2", isIPv6: false),
            InterfaceAddress(name: "en18", address: "2001:db8::2", isIPv6: true),
            InterfaceAddress(name: "en0", address: "192.168.0.22", isIPv6: false),
        ])

    private static let gone = InterfaceSnapshot(present: ["lo0", "en0"], addresses: [])

    /// Records every attempt the policy makes, and answers each with a
    /// scripted result.
    private final class Attempts {
        var made: [InterfacePinning.Attempt] = []
        var boundResult: Result<String, TransportError> = .success("bound")
        func run(_ attempt: InterfacePinning.Attempt) throws -> String {
            made.append(attempt)
            switch attempt {
            case .bound: return try boundResult.get()
            case .unbound: return "unbound"
            }
        }
    }

    /// Hands out snapshots in order, repeating the last; counts waits.
    private final class World {
        var snapshots: [InterfaceSnapshot]
        var waitsAllowed: Int
        var waits = 0
        var resolutions = 0
        var resolved: Result<[String], TransportError> = .success(["192.168.20.1"])

        init(_ snapshots: [InterfaceSnapshot], waitsAllowed: Int = 0) {
            self.snapshots = snapshots
            self.waitsAllowed = waitsAllowed
        }
        func snapshot() -> InterfaceSnapshot {
            snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
        }
        func resolve(_ host: String) throws -> [String] {
            resolutions += 1
            return try resolved.get()
        }
        func wait() -> Bool {
            guard waits < waitsAllowed else { return false }
            waits += 1
            return true
        }
    }

    private func run(_ binding: InterfaceBinding?, host: String = "192.168.20.1",
                     world: World, attempts: Attempts) async throws
        -> (value: String, fallback: InterfacePinning.Fallback?) {
        try await InterfacePinning.connect(
            binding: binding, host: host,
            snapshot: { world.snapshot() },
            resolve: { try world.resolve($0) },
            waitForInterface: { world.wait() },
            attempt: { try attempts.run($0) })
    }

    // MARK: - Endpoint choice

    @Test("an IPv4 target binds the interface's IPv4 address")
    func picksIPv4() throws {
        let e = try InterfacePinning.endpoints(for: "en18", remotes: ["192.168.20.1"],
                                               in: Self.storage)
        #expect(e == InterfacePinning.Endpoints(local: "192.168.20.2", remote: "192.168.20.1"))
    }

    @Test("a name that resolves to both families prefers IPv4")
    func prefersIPv4WhenBothResolve() throws {
        let e = try InterfacePinning.endpoints(for: "en18",
                                               remotes: ["2001:db8::1", "192.168.20.1"],
                                               in: Self.storage)
        #expect(e == InterfacePinning.Endpoints(local: "192.168.20.2", remote: "192.168.20.1"))
    }

    @Test("an IPv6-only target binds a global IPv6 address, never link-local")
    func picksGlobalIPv6() throws {
        let e = try InterfacePinning.endpoints(for: "en18", remotes: ["2001:db8::1"],
                                               in: Self.storage)
        #expect(e == InterfacePinning.Endpoints(local: "2001:db8::2", remote: "2001:db8::1"))
    }

    @Test("an IPv6 target on an IPv4-only interface fails as no IPv6 address")
    func ipv6TargetOnIPv4OnlyInterface() {
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en0", reason: "it has no IPv6 address")) {
            try InterfacePinning.endpoints(for: "en0", remotes: ["2001:db8::1"], in: Self.storage)
        }
    }

    /// A self-assigned 169.254 address is what an interface holds when DHCP
    /// failed — it has lost its network, so it must not count.
    @Test("a link-local-only interface has no usable address")
    func linkLocalOnlyIsNoAddress() {
        let snapshot = InterfaceSnapshot(
            present: ["en7"],
            addresses: [InterfaceAddress(name: "en7", address: "169.254.3.4", isIPv6: false)])
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en7", reason: "it has no IPv4 address")) {
            try InterfacePinning.endpoints(for: "en7", remotes: ["192.168.20.1"], in: snapshot)
        }
    }

    @Test("a target of both families on an addressless interface names both")
    func bothFamiliesMissing() {
        let snapshot = InterfaceSnapshot(present: ["en7"], addresses: [])
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en7", reason: "it has no IPv4 or IPv6 address")) {
            try InterfacePinning.endpoints(for: "en7", remotes: ["192.168.20.1", "2001:db8::1"],
                                           in: snapshot)
        }
    }

    @Test("a present interface with no address and an absent one are told apart")
    func absentVersusAddressless() {
        let snapshot = InterfaceSnapshot(present: ["en7"], addresses: [])
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en7", reason: "it has no IPv4 address")) {
            try InterfacePinning.endpoints(for: "en7", remotes: ["192.168.20.1"], in: snapshot)
        }
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en99", reason: "it is not present")) {
            try InterfacePinning.endpoints(for: "en99", remotes: ["192.168.20.1"], in: snapshot)
        }
    }

    // MARK: - Strict versus prefer

    @Test("no binding connects unbound, resolving and reading nothing")
    func noBinding() async throws {
        let attempts = Attempts()
        let world = World([Self.storage])
        var snapshotReads = 0
        let (value, fallback) = try await InterfacePinning.connect(
            binding: nil, host: "nas.lan",
            snapshot: { snapshotReads += 1; return Self.storage },
            resolve: { try world.resolve($0) },
            waitForInterface: { world.wait() },
            attempt: { try attempts.run($0) })
        #expect(value == "unbound")
        #expect(fallback == nil)
        #expect(attempts.made == [.unbound])
        #expect(snapshotReads == 0)
        #expect(world.resolutions == 0)
    }

    @Test("strict binds the interface's address and connects to the target's")
    func strictBinds() async throws {
        let attempts = Attempts()
        let (value, fallback) = try await run(InterfaceBinding(name: "en18", fallback: false),
                                              world: World([Self.storage]), attempts: attempts)
        #expect(value == "bound")
        #expect(fallback == nil)
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2",
                                         remoteAddress: "192.168.20.1")])
    }

    /// A bound connection resolves names through the bound interface only, and
    /// a storage link usually has no resolver — so a pinned hostname must be
    /// resolved the ordinary way first and the bound attempt aimed at the
    /// answer (review finding I1, reproduced against the NAS).
    @Test("a hostname is resolved before binding and the bound attempt targets the answer")
    func hostnameResolvedFirst() async throws {
        let attempts = Attempts()
        let world = World([Self.storage])
        _ = try await run(InterfaceBinding(name: "en18", fallback: false), host: "nas.lan",
                          world: world, attempts: attempts)
        #expect(world.resolutions == 1)
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2",
                                         remoteAddress: "192.168.20.1")])
    }

    /// An unbound connect would fail the same way, so there is nothing to fall
    /// back to.
    @Test("a name that does not resolve fails in prefer mode without connecting")
    func unresolvableNameFailsWithoutFallback() async {
        let attempts = Attempts()
        let world = World([Self.storage])
        world.resolved = .failure(.connectFailed("could not resolve nas.lan"))
        await #expect(throws: TransportError.connectFailed("could not resolve nas.lan")) {
            _ = try await run(InterfaceBinding(name: "en18", fallback: true), host: "nas.lan",
                              world: world, attempts: attempts)
        }
        #expect(attempts.made.isEmpty)
    }

    /// Unpinned, a pulled cable costs each recovery attempt the full connect
    /// deadline; a strict pin that failed at once ran recovery's whole budget
    /// out in ~16 s and unmounted where an unpinned session survived ~65 s
    /// (review finding M1). So strict waits, inside the same deadline.
    @Test("strict waits for an interface that comes back, then binds it")
    func strictWaitsForInterface() async throws {
        let attempts = Attempts()
        let world = World([Self.gone, Self.gone, Self.storage], waitsAllowed: 5)
        let (value, _) = try await run(InterfaceBinding(name: "en18", fallback: false),
                                       world: world, attempts: attempts)
        #expect(value == "bound")
        #expect(world.waits == 2)
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2",
                                         remoteAddress: "192.168.20.1")])
    }

    @Test("strict gives up when the wait runs out, without connecting at all")
    func strictAbsentFailsWhenWaitRunsOut() async {
        let attempts = Attempts()
        let world = World([Self.gone], waitsAllowed: 3)
        await #expect(throws: TransportError.interfaceUnavailable(
            name: "en18", reason: "it is not present")) {
            _ = try await run(InterfaceBinding(name: "en18", fallback: false),
                              world: world, attempts: attempts)
        }
        #expect(world.waits == 3)
        #expect(attempts.made.isEmpty)
    }

    @Test("prefer does not wait: an absent interface falls back at once and says why")
    func preferAbsentFallsBack() async throws {
        let attempts = Attempts()
        let world = World([Self.gone], waitsAllowed: 5)
        let (value, fallback) = try await run(InterfaceBinding(name: "en18", fallback: true),
                                              world: world, attempts: attempts)
        #expect(value == "unbound")
        #expect(world.waits == 0)
        #expect(attempts.made == [.unbound])
        #expect(fallback == InterfacePinning.Fallback(from: "en18", reason: "it is not present"))
    }

    @Test("strict with no route fails after the one bound attempt")
    func strictNoRouteFails() async {
        let attempts = Attempts()
        attempts.boundResult = .failure(.interfaceUnavailable(
            name: "en18", reason: "it has no route to 192.168.0.1"))
        await #expect(throws: TransportError.interfaceUnavailable(
            name: "en18", reason: "it has no route to 192.168.0.1")) {
            _ = try await run(InterfaceBinding(name: "en18", fallback: false),
                              world: World([Self.storage]), attempts: attempts)
        }
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2",
                                         remoteAddress: "192.168.20.1")])
    }

    @Test("prefer with no route retries unbound")
    func preferNoRouteFallsBack() async throws {
        let attempts = Attempts()
        attempts.boundResult = .failure(.interfaceUnavailable(
            name: "en18", reason: "it has no route to 192.168.0.1"))
        let (value, fallback) = try await run(InterfaceBinding(name: "en18", fallback: true),
                                              world: World([Self.storage]), attempts: attempts)
        #expect(value == "unbound")
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2",
                                         remoteAddress: "192.168.20.1"), .unbound])
        #expect(fallback == InterfacePinning.Fallback(
            from: "en18", reason: "it has no route to 192.168.0.1"))
    }

    /// The fast-signals-only rule: an interface that is up and routed but
    /// whose target does not answer is a target failure. Falling back here
    /// would spend a second connect deadline on every recovery attempt.
    @Test("prefer does not fall back when the bound attempt simply fails to connect")
    func preferDoesNotFallBackOnConnectFailure() async {
        let attempts = Attempts()
        attempts.boundResult = .failure(.connectFailed("timed out"))
        await #expect(throws: TransportError.connectFailed("timed out")) {
            _ = try await run(InterfaceBinding(name: "en18", fallback: true),
                              world: World([Self.storage]), attempts: attempts)
        }
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2",
                                         remoteAddress: "192.168.20.1")])
    }

    @Test("a nil or blank stored name pins nothing")
    func namedTreatsBlankAsAutomatic() {
        #expect(InterfaceBinding.named(nil, fallback: false) == nil)
        #expect(InterfaceBinding.named("  ", fallback: true) == nil)
        #expect(InterfaceBinding.named(" en18 ", fallback: true)
                == InterfaceBinding(name: "en18", fallback: true))
    }
}
