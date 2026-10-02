import Foundation
import Testing
@testable import iSCSIKit

/// The decision behind interface pinning, with no network: which address a
/// pin binds, and when strict fails versus prefer falls back. The real
/// socket behaviour is in LoopbackTCPTests.
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

    // MARK: - Address choice

    @Test("an IPv4 or named portal binds the interface's IPv4 address")
    func picksIPv4() throws {
        #expect(try InterfacePinning.localAddress(for: "en18", host: "192.168.20.1",
                                                  in: Self.storage) == "192.168.20.2")
        #expect(try InterfacePinning.localAddress(for: "en18", host: "nas.local",
                                                  in: Self.storage) == "192.168.20.2")
    }

    @Test("an IPv6-literal portal binds a global IPv6 address, never link-local")
    func picksGlobalIPv6() throws {
        #expect(try InterfacePinning.localAddress(for: "en18", host: "2001:db8::1",
                                                  in: Self.storage) == "2001:db8::2")
    }

    @Test("an IPv6 portal on an IPv4-only interface fails as no IPv6 address")
    func ipv6PortalOnIPv4OnlyInterface() {
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en0", reason: "it has no IPv6 address")) {
            try InterfacePinning.localAddress(for: "en0", host: "2001:db8::1", in: Self.storage)
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
            try InterfacePinning.localAddress(for: "en7", host: "192.168.20.1", in: snapshot)
        }
    }

    @Test("a present interface with no address and an absent one are told apart")
    func absentVersusAddressless() {
        let snapshot = InterfaceSnapshot(present: ["en7"], addresses: [])
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en7", reason: "it has no IPv4 address")) {
            try InterfacePinning.localAddress(for: "en7", host: "192.168.20.1", in: snapshot)
        }
        #expect(throws: TransportError.interfaceUnavailable(
            name: "en99", reason: "it is not present")) {
            try InterfacePinning.localAddress(for: "en99", host: "192.168.20.1", in: snapshot)
        }
    }

    // MARK: - Strict versus prefer

    @Test("no binding connects unbound and never reads the interface list")
    func noBinding() async throws {
        let attempts = Attempts()
        var snapshotReads = 0
        let (value, fallback) = try await InterfacePinning.connect(
            binding: nil, host: "192.168.20.1",
            snapshot: { snapshotReads += 1; return Self.storage },
            attempt: { try attempts.run($0) })
        #expect(value == "unbound")
        #expect(fallback == nil)
        #expect(attempts.made == [.unbound])
        #expect(snapshotReads == 0)
    }

    @Test("strict binds the interface's address")
    func strictBinds() async throws {
        let attempts = Attempts()
        let (value, fallback) = try await InterfacePinning.connect(
            binding: InterfaceBinding(name: "en18", fallback: false), host: "192.168.20.1",
            snapshot: { Self.storage }, attempt: { try attempts.run($0) })
        #expect(value == "bound")
        #expect(fallback == nil)
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2")])
    }

    @Test("strict with the interface absent fails without connecting at all")
    func strictAbsentFails() async {
        let attempts = Attempts()
        await #expect(throws: TransportError.interfaceUnavailable(
            name: "en99", reason: "it is not present")) {
            _ = try await InterfacePinning.connect(
                binding: InterfaceBinding(name: "en99", fallback: false), host: "192.168.20.1",
                snapshot: { Self.storage }, attempt: { try attempts.run($0) })
        }
        #expect(attempts.made.isEmpty)
    }

    @Test("prefer with the interface absent connects unbound and says why")
    func preferAbsentFallsBack() async throws {
        let attempts = Attempts()
        let (value, fallback) = try await InterfacePinning.connect(
            binding: InterfaceBinding(name: "en99", fallback: true), host: "192.168.20.1",
            snapshot: { Self.storage }, attempt: { try attempts.run($0) })
        #expect(value == "unbound")
        #expect(attempts.made == [.unbound])
        #expect(fallback == InterfacePinning.Fallback(from: "en99", reason: "it is not present"))
    }

    @Test("strict with no route fails after the one bound attempt")
    func strictNoRouteFails() async {
        let attempts = Attempts()
        attempts.boundResult = .failure(.interfaceUnavailable(
            name: "en18", reason: "it has no route to 192.168.0.1"))
        await #expect(throws: TransportError.interfaceUnavailable(
            name: "en18", reason: "it has no route to 192.168.0.1")) {
            _ = try await InterfacePinning.connect(
                binding: InterfaceBinding(name: "en18", fallback: false), host: "192.168.0.1",
                snapshot: { Self.storage }, attempt: { try attempts.run($0) })
        }
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2")])
    }

    @Test("prefer with no route retries unbound")
    func preferNoRouteFallsBack() async throws {
        let attempts = Attempts()
        attempts.boundResult = .failure(.interfaceUnavailable(
            name: "en18", reason: "it has no route to 192.168.0.1"))
        let (value, fallback) = try await InterfacePinning.connect(
            binding: InterfaceBinding(name: "en18", fallback: true), host: "192.168.0.1",
            snapshot: { Self.storage }, attempt: { try attempts.run($0) })
        #expect(value == "unbound")
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2"), .unbound])
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
            _ = try await InterfacePinning.connect(
                binding: InterfaceBinding(name: "en18", fallback: true), host: "192.168.20.1",
                snapshot: { Self.storage }, attempt: { try attempts.run($0) })
        }
        #expect(attempts.made == [.bound(localAddress: "192.168.20.2")])
    }

    @Test("a nil or blank stored name pins nothing")
    func namedTreatsBlankAsAutomatic() {
        #expect(InterfaceBinding.named(nil, fallback: false) == nil)
        #expect(InterfaceBinding.named("  ", fallback: true) == nil)
        #expect(InterfaceBinding.named(" en18 ", fallback: true)
                == InterfaceBinding(name: "en18", fallback: true))
    }
}
