import Foundation

/// A target's chosen egress interface, and what to do when it cannot carry
/// the connection. Applied by binding the interface's current address, which
/// macOS scoped routing then holds to that interface — see
/// docs/superpowers/specs/2026-10-02-interface-pinning-design.md for why not
/// `requiredInterface`.
public struct InterfaceBinding: Sendable, Equatable {
    /// BSD name, e.g. "en18". macOS keeps it stable per adapter.
    public var name: String
    /// true: fall back to macOS routing (prefer). false: fail (strict).
    public var fallback: Bool

    public init(name: String, fallback: Bool) {
        self.name = name
        self.fallback = fallback
    }

    /// The binding a stored or transmitted name asks for. nil — macOS
    /// routing — for nil or a blank name, which a hand-edited targets.json
    /// and an XPC caller can each produce.
    public static func named(_ name: String?, fallback: Bool) -> InterfaceBinding? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty
        else { return nil }
        return InterfaceBinding(name: trimmed, fallback: fallback)
    }
}

/// One address an interface holds.
public struct InterfaceAddress: Sendable, Equatable {
    public var name: String
    public var address: String
    public var isIPv6: Bool

    public init(name: String, address: String, isIPv6: Bool) {
        self.name = name
        self.address = address
        self.isIPv6 = isIPv6
    }
}

/// The interfaces the system lists, and the addresses of those that are up.
public struct InterfaceSnapshot: Sendable, Equatable {
    /// Every interface name, addressed or not: what tells "not present"
    /// apart from "present but holding no address".
    public var present: Set<String>
    public var addresses: [InterfaceAddress]

    public init(present: Set<String>, addresses: [InterfaceAddress]) {
        self.present = present
        self.addresses = addresses
    }
}

/// What a connect actually did, for the log and the Sessions window.
public struct ConnectedPath: Sendable, Equatable {
    /// The interface the connection runs over, from its path. nil when the
    /// transport cannot say.
    public var interfaceName: String?
    /// Set when a prefer-mode pin could not be used.
    public var fallback: InterfacePinning.Fallback?

    public init(interfaceName: String? = nil, fallback: InterfacePinning.Fallback? = nil) {
        self.interfaceName = interfaceName
        self.fallback = fallback
    }
}

/// A transport that knows which interface it ended up on. `NetworkTransport`
/// conforms; `MemoryPipe` does not, and reports nothing.
public protocol ConnectionPathReporting {
    var connectedPath: ConnectedPath { get }
}

/// The strict/prefer decision, over an injected attempt so every branch is
/// testable without a network.
public enum InterfacePinning {

    /// How one connect attempt is made. A bound attempt connects to an
    /// address, never a name: a bound connection resolves names through the
    /// bound interface alone, and a storage link usually has no resolver.
    public enum Attempt: Sendable, Equatable {
        case bound(localAddress: String, remoteAddress: String)
        case unbound
    }

    /// The pair a bound attempt uses.
    public struct Endpoints: Sendable, Equatable {
        public var local: String
        public var remote: String

        public init(local: String, remote: String) {
            self.local = local
            self.remote = remote
        }
    }

    /// A prefer-mode pin that could not be used, and why.
    public struct Fallback: Sendable, Equatable {
        public var from: String
        public var reason: String

        public init(from: String, reason: String) {
            self.from = from
            self.reason = reason
        }
    }

    /// 169.254/16 and fe80::/10. An interface holding only these has lost its
    /// network (a self-assigned address is what DHCP failure leaves).
    public static func isLinkLocal(_ address: InterfaceAddress) -> Bool {
        address.isIPv6
            ? address.address.lowercased().hasPrefix("fe80:")
            : address.address.hasPrefix("169.254.")
    }

    /// The interface address to bind and the target address to connect to:
    /// the first target address, IPv4 before IPv6, whose family `name` holds a
    /// usable (non-link-local) address in. Throws `interfaceUnavailable` with
    /// the reason a person can act on.
    public static func endpoints(for name: String, remotes: [String],
                                 in snapshot: InterfaceSnapshot) throws -> Endpoints {
        let held = snapshot.addresses.filter { $0.name == name && !isLinkLocal($0) }
        guard snapshot.present.contains(name) || !held.isEmpty else {
            throw TransportError.interfaceUnavailable(name: name, reason: "it is not present")
        }
        // Address literals: IPv6 always carries a colon, IPv4 never does.
        let ordered = remotes.filter { !$0.contains(":") } + remotes.filter { $0.contains(":") }
        for remote in ordered {
            let wantsIPv6 = remote.contains(":")
            if let local = held.first(where: { $0.isIPv6 == wantsIPv6 }) {
                return Endpoints(local: local.address, remote: remote)
            }
        }
        let families = [ordered.contains { !$0.contains(":") } ? "IPv4" : nil,
                        ordered.contains { $0.contains(":") } ? "IPv6" : nil].compactMap { $0 }
        throw TransportError.interfaceUnavailable(
            name: name, reason: "it has no \(families.joined(separator: " or ")) address")
    }

    /// `endpoints`, re-read from a fresh snapshot for as long as `wait` allows.
    private static func endpoints(for name: String, remotes: [String],
                                  snapshot: () -> InterfaceSnapshot,
                                  mayWait: Bool, wait: () async -> Bool) async throws -> Endpoints {
        while true {
            do {
                return try endpoints(for: name, remotes: remotes, in: snapshot())
            } catch {
                guard mayWait, await wait() else { throw error }
            }
        }
    }

    /// Connect under `binding`.
    ///
    /// A pinned target name is resolved first, the ordinary way (`resolve`);
    /// failing that fails both modes, since an unbound connect would fail the
    /// same way. Then:
    /// - an unusable interface (absent, or no address of the target's family):
    ///   strict waits for it while `waitForInterface` allows — inside the
    ///   connect deadline, so a re-seated cable heals a session exactly as it
    ///   would unpinned — then fails; prefer falls back at once;
    /// - a bound attempt reporting no route: strict fails, prefer falls back;
    /// - a bound attempt that merely fails to connect: the target's failure
    ///   in both modes. Falling back there would spend a second connect
    ///   deadline on every recovery attempt (docs/open-questions.md §8a).
    public static func connect<T>(
        binding: InterfaceBinding?,
        host: String,
        snapshot: () -> InterfaceSnapshot,
        resolve: (String) async throws -> [String],
        waitForInterface: () async -> Bool,
        attempt: (Attempt) async throws -> T
    ) async throws -> (value: T, fallback: Fallback?) {
        guard let binding else { return (try await attempt(.unbound), nil) }

        let remotes = try await resolve(host)
        let chosen: Endpoints
        do {
            // Prefer never waits: it has somewhere else to go.
            chosen = try await endpoints(for: binding.name, remotes: remotes, snapshot: snapshot,
                                         mayWait: !binding.fallback, wait: waitForInterface)
        } catch TransportError.interfaceUnavailable(_, let reason) where binding.fallback {
            return (try await attempt(.unbound), Fallback(from: binding.name, reason: reason))
        }

        do {
            return (try await attempt(.bound(localAddress: chosen.local,
                                             remoteAddress: chosen.remote)), nil)
        } catch TransportError.interfaceUnavailable(_, let reason) where binding.fallback {
            return (try await attempt(.unbound), Fallback(from: binding.name, reason: reason))
        }
    }
}
