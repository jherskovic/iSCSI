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

    /// How one connect attempt is made.
    public enum Attempt: Sendable, Equatable {
        case bound(localAddress: String)
        case unbound
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

    /// The address to bind for `name`: IPv6 for an IPv6-literal host, IPv4
    /// otherwise, never link-local. Throws `interfaceUnavailable` with the
    /// reason a person can act on.
    public static func localAddress(for name: String, host: String,
                                    in snapshot: InterfaceSnapshot) throws -> String {
        let held = snapshot.addresses.filter { $0.name == name }
        guard snapshot.present.contains(name) || !held.isEmpty else {
            throw TransportError.interfaceUnavailable(name: name, reason: "it is not present")
        }
        // Hostnames and IPv4 literals carry no colon; IPv6 literals always do.
        let wantsIPv6 = host.contains(":")
        guard let pick = held.first(where: { $0.isIPv6 == wantsIPv6 && !isLinkLocal($0) }) else {
            throw TransportError.interfaceUnavailable(
                name: name, reason: "it has no \(wantsIPv6 ? "IPv6" : "IPv4") address")
        }
        return pick.address
    }

    /// Connect under `binding`. Strict fails on an unusable interface; prefer
    /// retries unbound — but only on the fast signals (no address, no route).
    /// A bound attempt that merely fails to connect is the target's failure
    /// in both modes: falling back there would spend a second connect
    /// deadline on every recovery attempt (docs/open-questions.md §8a).
    public static func connect<T>(
        binding: InterfaceBinding?,
        host: String,
        snapshot: () -> InterfaceSnapshot,
        attempt: (Attempt) async throws -> T
    ) async throws -> (value: T, fallback: Fallback?) {
        guard let binding else { return (try await attempt(.unbound), nil) }

        let address: String
        do {
            address = try localAddress(for: binding.name, host: host, in: snapshot())
        } catch TransportError.interfaceUnavailable(_, let reason) where binding.fallback {
            return (try await attempt(.unbound), Fallback(from: binding.name, reason: reason))
        }

        do {
            return (try await attempt(.bound(localAddress: address)), nil)
        } catch TransportError.interfaceUnavailable(_, let reason) where binding.fallback {
            return (try await attempt(.unbound), Fallback(from: binding.name, reason: reason))
        }
    }
}
