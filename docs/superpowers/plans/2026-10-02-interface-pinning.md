# Interface Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each target pin its connections to a chosen network interface — strict (fail) or prefer (fall back to macOS routing) — through the daemon, the CLI and the app.

**Architecture:** A pure policy in iSCSIKit decides, per connect attempt, whether to bind the interface's current address or connect unbound. `NetworkTransport` applies a bind with `requiredLocalEndpoint` (macOS scoped routing), treats `.waiting` while bound as "no route", and reports the interface it landed on. The daemon's transport factory gains a binding argument so every connect — first, recovery, both NVMe queues — is pinned; the binding comes from the `TargetRecord` for login and from explicit XPC parameters for discovery.

**Tech Stack:** Swift 6 (language mode 6), Network.framework, Darwin `getifaddrs`, SystemConfiguration (app only), SwiftUI, swift-testing, swift-argument-parser, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-02-interface-pinning-design.md`

## Global Constraints

- Every target is Swift 6 language mode; tests are swift-testing (`@Test` / `#expect`), not XCTest.
- CI runs `swift test --no-parallel`; run the full suite that way before calling anything done.
- `TargetRecord` gains only **optional** keys — "a new non-optional key would make every existing `targets.json` undecodable".
- Never change `HostIdentity`'s NQN derivation or `MountpointTag`'s derivation.
- `Sources/iSCSIKit` stays transport-free and side-effect-free **except** `Sources/iSCSIKit/Transport/`, which already holds `NetworkTransport`; the new `getifaddrs` reader lives there and nowhere else in iSCSIKit.
- The app builds against the **macOS 26 SDK**. The dev host has only Xcode 27, which accepts code Xcode 26 rejects; CI (Xcode 26.6) is the authority. Use no API newer than macOS 26.
- After adding app source files: `cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate`, and commit the regenerated `apps/iSCSIInitiator.xcodeproj/project.pbxproj`. Never hand-edit the `.pbxproj`.
- Nothing is installed or registered on the dev host. `swift run iscsictl …` is fine. Against the NAS (192.168.20.1) only read-only commands (`discover`); never `verify --write`.
- Use `/usr/bin/log`, never bare `log`.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
  ```
- Work on branch `interface-pinning`.

## Review Focus

1. A hand-edited `targets.json` with `"networkInterface": ""` or whitespace must behave as Automatic, not pin to an empty name — test in Task 3.
2. A strict pin whose interface is up but has no route to the target must fail in well under the 10 s connect deadline, naming the interface — test in Task 2 (bound to `lo0`, connecting to TEST-NET `192.0.2.1`).
3. A stored interface that has since vanished must still appear in the picker ("not present") so saving the target does not silently drop the pin — test in Task 7.
4. An IPv6-literal portal pinned to an interface with only IPv4 must fail with "no IPv6 address", not bind an IPv4 address — test in Task 1.
5. An XPC discovery call with `interfaceName: ""` (the app's empty state) must run unpinned — test in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/iSCSIKit/Transport/InterfaceBinding.swift` (create) | `InterfaceBinding`, `InterfaceAddress`, `InterfaceSnapshot`, `ConnectedPath`, `ConnectionPathReporting`, and `InterfacePinning` — the pure address choice and strict/prefer policy |
| `Sources/iSCSIKit/Transport/SystemInterfaces.swift` (create) | `getifaddrs` → `InterfaceSnapshot` |
| `Sources/iSCSIKit/Transport/InterfaceChoices.swift` (create) | Pure picker rows from a snapshot + display names + stored name |
| `Sources/iSCSIKit/Transport/Transport.swift` (modify) | `TransportError.interfaceUnavailable` |
| `Sources/iSCSIKit/Transport/NetworkTransport.swift` (modify) | Bound connect, `.waiting` handling, path reporting |
| `Sources/iSCSIKit/ISCSIError.swift` (modify) | User-facing text for the new error |
| `Sources/iSCSIKit/XPCModels.swift` (modify) | `TargetRecord` keys + `interfaceBinding`; `SessionInfo` path fields |
| `Sources/iSCSIKit/XPCProtocol.swift` (modify) | Discovery calls take the binding |
| `Sources/iSCSIDaemon/ConnectedPathBox.swift` (create) | Per-session latest connect outcome + log line |
| `Sources/iSCSIDaemon/DaemonCore.swift` (modify) | 3-argument factory, binding through login/discover/attach, path into `SessionInfo` |
| `Sources/iSCSIDaemon/XPCService.swift` (modify) | Record binding for login/testConnection; explicit binding for discovery |
| `Sources/iscsid/main.swift` (modify) | Factory passes the binding to `NetworkTransport` |
| `Sources/iscsictl/ISCSICtl.swift`, `Sources/iscsictl/NVMeCommands.swift` (modify) | `--interface` |
| `apps/iSCSIApp/Client/DaemonClient.swift` (modify) | Discovery wrappers pass the binding |
| `apps/iSCSIApp/Client/NetworkInterfaceNames.swift` (create) | SystemConfiguration display names |
| `apps/iSCSIApp/Windows/InterfacePicker.swift` (create) | Shared picker rows |
| `apps/iSCSIApp/Windows/TargetsView.swift`, `DiscoveryView.swift`, `SessionsView.swift` (modify) | Use the picker; show the path |
| Tests (create) `Tests/iSCSIKitTests/InterfacePinningTests.swift`, `Tests/iSCSIKitTests/TargetRecordInterfaceTests.swift`, `Tests/iSCSIKitTests/InterfaceChoicesTests.swift`, `Tests/IntegrationTests/InterfaceTestSupport.swift`, `Tests/IntegrationTests/InterfaceBindingDaemonTests.swift`, `Tests/IntegrationTests/InterfaceBindingXPCTests.swift` | |
| Tests (modify) `Tests/iSCSIKitTests/ISCSIErrorTests.swift`, `Tests/IntegrationTests/LoopbackTCPTests.swift`, the seven `DaemonCore(…) { _, _ in` sites, `Tests/IntegrationTests/DaemonStoreTests.swift`, `Tests/IntegrationTests/XPCServiceTests.swift` | |

---

### Task 1: Pinning policy and address choice (pure)

**Files:**
- Create: `Sources/iSCSIKit/Transport/InterfaceBinding.swift`
- Modify: `Sources/iSCSIKit/Transport/Transport.swift:15-18`
- Modify: `Sources/iSCSIKit/ISCSIError.swift:223-231`
- Test: `Tests/iSCSIKitTests/InterfacePinningTests.swift` (create), `Tests/iSCSIKitTests/ISCSIErrorTests.swift` (modify)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `public struct InterfaceBinding: Sendable, Equatable { var name: String; var fallback: Bool; init(name:fallback:); static func named(_ name: String?, fallback: Bool) -> InterfaceBinding? }`
  - `public struct InterfaceAddress: Sendable, Equatable { var name: String; var address: String; var isIPv6: Bool }`
  - `public struct InterfaceSnapshot: Sendable, Equatable { var present: Set<String>; var addresses: [InterfaceAddress] }`
  - `public struct ConnectedPath: Sendable, Equatable { var interfaceName: String?; var fallback: InterfacePinning.Fallback?; init(interfaceName: String? = nil, fallback: InterfacePinning.Fallback? = nil) }`
  - `public protocol ConnectionPathReporting { var connectedPath: ConnectedPath { get } }`
  - `public enum InterfacePinning` with `enum Attempt { case bound(localAddress: String); case unbound }`, `struct Fallback { var from: String; var reason: String }`, `static func isLinkLocal(_:) -> Bool`, `static func localAddress(for:host:in:) throws -> String`, `static func connect<T>(binding:host:snapshot:attempt:) async throws -> (value: T, fallback: Fallback?)`
  - `TransportError.interfaceUnavailable(name: String, reason: String)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/iSCSIKitTests/InterfacePinningTests.swift`:

```swift
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
```

In `Tests/iSCSIKitTests/ISCSIErrorTests.swift`, add `TransportError.interfaceUnavailable(name: "en18", reason: "it is not present"),` to the `errors` array directly after `TransportError.connectFailed("x"),` (line 100), and add this test inside `ISCSIErrorTests` after `authIsNotConnectivity`:

```swift
    @Test("an unavailable pinned interface names the interface and the way out")
    func interfaceUnavailableIsActionable() {
        let error = ISCSIError.nsError(
            from: TransportError.interfaceUnavailable(name: "en18", reason: "it is not present"))
        #expect(error.code == ISCSIError.Code.cannotConnect.rawValue)
        #expect(error.localizedDescription.contains("en18"))
        #expect(error.localizedDescription.contains("it is not present"))
        #expect(error.localizedRecoverySuggestion?.contains("Automatic") == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "InterfacePinning|ISCSIError" 2>&1 | tail -20`
Expected: build failure — `cannot find 'InterfacePinning' in scope`, `type 'TransportError' has no member 'interfaceUnavailable'`.

- [ ] **Step 3: Add the error case**

In `Sources/iSCSIKit/Transport/Transport.swift` replace:

```swift
public enum TransportError: Error, Equatable, Sendable {
    case closed
    case connectFailed(String)
}
```

with:

```swift
public enum TransportError: Error, Equatable, Sendable {
    case closed
    case connectFailed(String)
    /// A pinned interface cannot carry the connection: it is absent, holds
    /// no usable address, or has no route to the target.
    case interfaceUnavailable(name: String, reason: String)
}
```

In `Sources/iSCSIKit/ISCSIError.swift`, inside `case let e as TransportError:`, add after the `.connectFailed` case:

```swift
            case .interfaceUnavailable(let name, let reason):
                return (.cannotConnect, "Could not use network interface \(name): \(reason).",
                        "Reconnect \(name), or change this target's network interface — "
                        + "or set it to Automatic — in its settings.", nil)
```

- [ ] **Step 4: Write the policy**

Create `Sources/iSCSIKit/Transport/InterfaceBinding.swift`:

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "InterfacePinning|ISCSIError" 2>&1 | grep -E "Test run with|✘"`
Expected: `Test run with N tests … passed`, no `✘`.

- [ ] **Step 6: Commit**

```bash
git add Sources/iSCSIKit/Transport/InterfaceBinding.swift Sources/iSCSIKit/Transport/Transport.swift \
        Sources/iSCSIKit/ISCSIError.swift Tests/iSCSIKitTests/InterfacePinningTests.swift \
        Tests/iSCSIKitTests/ISCSIErrorTests.swift
git commit -F - <<'EOF'
Add the interface-pinning policy: address choice and strict/prefer

Pure and network-free: which address a pin binds (IPv4 unless the portal
is an IPv6 literal, never link-local), and when strict fails versus
prefer falls back — only on the fast signals, never on a plain connect
failure.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 2: Bound connects in `NetworkTransport`

**Files:**
- Create: `Sources/iSCSIKit/Transport/SystemInterfaces.swift`
- Modify: `Sources/iSCSIKit/Transport/NetworkTransport.swift` (whole file replaced below)
- Test: `Tests/IntegrationTests/LoopbackTCPTests.swift` (modify)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces:
  - `public enum SystemInterfaces { static func snapshot() -> InterfaceSnapshot }`
  - `NetworkTransport.connect(host: String, port: UInt16, binding: InterfaceBinding? = nil, timeout: Duration = .seconds(10)) async throws -> NetworkTransport`
  - `NetworkTransport: ConnectionPathReporting` — `public private(set) var connectedPath: ConnectedPath`

- [ ] **Step 1: Write the failing tests**

Append inside `struct LoopbackTCPTests` in `Tests/IntegrationTests/LoopbackTCPTests.swift` (the file is already `#if canImport(Network)` and imports `MockTarget` and `iSCSIKit`):

```swift
    // MARK: - Interface pinning, over real sockets

    @Test("the system snapshot lists loopback and its address")
    func snapshotListsLoopback() {
        let snapshot = SystemInterfaces.snapshot()
        #expect(snapshot.present.contains("lo0"))
        #expect(snapshot.addresses.contains(
            InterfaceAddress(name: "lo0", address: "127.0.0.1", isIPv6: false)))
    }

    @Test("a connection pinned to lo0 runs over lo0")
    func pinnedToLoopback() async throws {
        let server = try MockTargetServer { MockTargetConfig() }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await NetworkTransport.connect(
            host: "127.0.0.1", port: port,
            binding: InterfaceBinding(name: "lo0", fallback: false))
        #expect(transport.connectedPath.interfaceName == "lo0")
        #expect(transport.connectedPath.fallback == nil)
        await transport.close()
    }

    @Test("strict: a missing interface fails at once, naming it")
    func strictMissingInterfaceFailsFast() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TransportError.interfaceUnavailable(
            name: "nosuch0", reason: "it is not present")) {
            _ = try await NetworkTransport.connect(
                host: "127.0.0.1", port: 9,
                binding: InterfaceBinding(name: "nosuch0", fallback: false))
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test("prefer: a missing interface falls back to macOS routing and says so")
    func preferMissingInterfaceFallsBack() async throws {
        let server = try MockTargetServer { MockTargetConfig() }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let transport = try await NetworkTransport.connect(
            host: "127.0.0.1", port: port,
            binding: InterfaceBinding(name: "nosuch0", fallback: true))
        #expect(transport.connectedPath.interfaceName == "lo0")
        #expect(transport.connectedPath.fallback
                == InterfacePinning.Fallback(from: "nosuch0", reason: "it is not present"))
        await transport.close()
    }

    /// Bound to lo0, TEST-NET-1 is unroutable. macOS reports `.waiting`
    /// (EADDRNOTAVAIL) within a millisecond and never `.failed` (measured
    /// 2026-10-02), so without the `.waiting` rule this would sit out the
    /// whole 10 s deadline.
    @Test("strict: an interface with no route to the target fails at once")
    func strictNoRouteFailsFast() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await NetworkTransport.connect(
                host: "192.0.2.1", port: 3260,
                binding: InterfaceBinding(name: "lo0", fallback: false))
            Issue.record("connected through an interface with no route to the target")
        } catch let TransportError.interfaceUnavailable(name, reason) {
            #expect(name == "lo0")
            #expect(reason.contains("no route to 192.0.2.1"))
        }
        #expect(clock.now - start < .seconds(2))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LoopbackTCP 2>&1 | tail -20`
Expected: build failure — `cannot find 'SystemInterfaces' in scope`, `extra argument 'binding' in call`.

- [ ] **Step 3: Write the interface reader**

Create `Sources/iSCSIKit/Transport/SystemInterfaces.swift`:

```swift
#if canImport(Darwin)
import Darwin

/// The interfaces and addresses the kernel reports right now. Lives beside
/// `NetworkTransport` because it reads system state, which the rest of
/// iSCSIKit deliberately does not.
public enum SystemInterfaces {
    /// Every interface `getifaddrs` lists, and the IPv4/IPv6 addresses of
    /// those that are up and running. Read fresh on every call: DHCP and a
    /// re-plugged cable both change it, and a pin resolves on every connect.
    public static func snapshot() -> InterfaceSnapshot {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return InterfaceSnapshot(present: [], addresses: [])
        }
        defer { freeifaddrs(head) }

        var present = Set<String>()
        var addresses: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            let name = String(cString: ifa.ifa_name)
            present.insert(name)
            let up = ifa.ifa_flags & UInt32(IFF_UP) != 0
            let running = ifa.ifa_flags & UInt32(IFF_RUNNING) != 0
            guard up, running, let sa = ifa.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size
                                                     : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, length, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            addresses.append(InterfaceAddress(name: name, address: address,
                                              isIPv6: family == AF_INET6))
        }
        return InterfaceSnapshot(present: present, addresses: addresses)
    }
}
#endif
```

- [ ] **Step 4: Replace `NetworkTransport.swift`**

Replace the whole of `Sources/iSCSIKit/Transport/NetworkTransport.swift` with the following. `send`, `receive` and `close` are unchanged; the TCP options block is copied verbatim (see the note under "Out of scope" at the end of this plan).

```swift
#if canImport(Network)
import Foundation
import Network
import os

/// TCP transport over Network.framework for a real iSCSI connection.
/// Used by the daemon and by `iscsictl` against a live target.
public final class NetworkTransport: ConnectionTransport, ConnectionPathReporting, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "iscsi.transport")
    /// The interface this connection ended up on, and whether a pin fell
    /// back. Written inside `connect`, before the transport is handed out,
    /// and never again.
    public private(set) var connectedPath = ConnectedPath()

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Open a TCP connection to host:port and wait until it is ready.
    ///
    /// A `binding` pins the connection by binding the interface's current
    /// address (`requiredLocalEndpoint`); macOS scoped routing then keeps it
    /// on that interface, route-less storage links included.
    /// `requiredInterface` cannot: the `NWInterface` it needs only comes from
    /// `NWPathMonitor`, which omits interfaces without a default route
    /// (measured 2026-10-02, see the interface-pinning spec).
    public static func connect(
        host: String,
        port: UInt16,
        binding: InterfaceBinding? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> NetworkTransport {
        let (transport, fallback) = try await InterfacePinning.connect(
            binding: binding, host: host, snapshot: SystemInterfaces.snapshot
        ) { attempt in
            try await openConnection(host: host, port: port, attempt: attempt,
                                     pinnedName: binding?.name, timeout: timeout)
        }
        transport.connectedPath.fallback = fallback
        return transport
    }

    private static func openConnection(
        host: String, port: UInt16, attempt: InterfacePinning.Attempt,
        pinnedName: String?, timeout: Duration
    ) async throws -> NetworkTransport {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true // iSCSI PDUs are latency-sensitive; disable Nagle
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        if case .bound(let local) = attempt {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(local), port: .any)
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 3260)
        )
        let connection = NWConnection(to: endpoint, using: params)
        let transport = NetworkTransport(connection: connection)

        // While bound, `.waiting` means the interface has no route to the
        // target: macOS reports it within milliseconds (ENETDOWN,
        // EADDRNOTAVAIL) and never escalates it to `.failed`, so waiting it
        // out would only spend the whole deadline.
        let unroutable: (name: String, host: String)? = {
            if case .bound = attempt, let pinnedName { return (pinnedName, host) }
            return nil
        }()
        do {
            try await transport.start(timeout: timeout, unroutable: unroutable)
        } catch {
            // Never leave a failed attempt open: prefer mode is about to open
            // another, and an abandoned NWConnection keeps its socket.
            connection.cancel()
            throw error
        }
        transport.connectedPath.interfaceName =
            connection.currentPath?.availableInterfaces.first?.name
        return transport
    }

    private func start(timeout: Duration, unroutable: (name: String, host: String)?) async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let connection = self.connection
        let queue = self.queue
        try await withDeadline(timeout) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                @Sendable func resumeOnce(_ result: Result<Void, any Error>) {
                    let already = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return done
                    }
                    if !already { c.resume(with: result) }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumeOnce(.success(()))
                    case .failed(let error):
                        resumeOnce(.failure(TransportError.connectFailed("\(error)")))
                    case .cancelled:
                        resumeOnce(.failure(TransportError.closed))
                    case .waiting(let error):
                        if let unroutable {
                            resumeOnce(.failure(TransportError.interfaceUnavailable(
                                name: unroutable.name,
                                reason: "it has no route to \(unroutable.host) (\(error))")))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    /// Deliver bytes, and give up if the caller stops waiting.
    ///
    /// Must be cancellable: `contentProcessed` never fires against a peer that
    /// stops draining a full socket buffer, and an uninterruptible send here
    /// blocks every command *and* the keepalive that would detect the dead
    /// peer. Cancelling tears down the whole `NWConnection` — correct, because
    /// an incomplete send may have left a partial PDU on the wire, so the
    /// stream is off frame boundary; the session layer rebuilds it.
    public func send(_ data: Data) async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                @Sendable func resumeOnce(_ result: Result<Void, any Error>) {
                    let already = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return done
                    }
                    if !already { c.resume(with: result) }
                }
                // Cancellation can land between installing the handler and
                // this running; a continuation nobody resumes is the bug.
                if Task.isCancelled {
                    resumeOnce(.failure(CancellationError()))
                    return
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        resumeOnce(.failure(TransportError.connectFailed("\(error)")))
                    } else {
                        resumeOnce(.success(()))
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    c.resume(throwing: TransportError.connectFailed("\(error)"))
                } else if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if isComplete {
                    c.resume(returning: nil) // orderly EOF
                } else {
                    c.resume(returning: Data()) // keep the read loop turning
                }
            }
        }
    }

    public func close() async {
        connection.cancel()
    }
}
#endif
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LoopbackTCP 2>&1 | grep -E "Test run with|✘"`
Expected: all LoopbackTCP tests pass, including the five new ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/iSCSIKit/Transport/SystemInterfaces.swift Sources/iSCSIKit/Transport/NetworkTransport.swift \
        Tests/IntegrationTests/LoopbackTCPTests.swift
git commit -F - <<'EOF'
Pin NetworkTransport connections by binding the interface's address

A bound connect uses requiredLocalEndpoint, so macOS scoped routing holds
it to the interface — including a storage link with no default route,
which NWPathMonitor (and so requiredInterface) cannot see. While bound,
.waiting is a missing route and fails at once instead of spending the
10 s deadline. The transport reports the interface it landed on.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 3: `TargetRecord` and `SessionInfo` fields

**Files:**
- Modify: `Sources/iSCSIKit/XPCModels.swift:54-101` (TargetRecord) and `:204-246` (SessionInfo)
- Test: `Tests/iSCSIKitTests/TargetRecordInterfaceTests.swift` (create)

**Interfaces:**
- Consumes: `InterfaceBinding.named(_:fallback:)` (Task 1).
- Produces:
  - `TargetRecord.networkInterface: String?`, `TargetRecord.interfaceFallback: Bool?`, `TargetRecord.interfaceBinding: InterfaceBinding?`; init gains trailing `networkInterface: String? = nil, interfaceFallback: Bool? = nil` (after `workloadProfile:`).
  - `SessionInfo.interfaceName: String?`, `SessionInfo.interfaceFallbackFrom: String?`; init gains trailing `interfaceName: String? = nil, interfaceFallbackFrom: String? = nil` (after `negotiated:`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/iSCSIKitTests/TargetRecordInterfaceTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIKit

/// Every installed targets.json predates these keys, and a decode failure
/// there loses the user's whole target list.
@Suite("Target record interface keys")
struct TargetRecordInterfaceTests {

    @Test("a pre-0.7.0 record decodes with no pin")
    func preInterfaceRecordDecodes() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0",
             "flushIntervalSeconds":5}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.networkInterface == nil)
        #expect(record.interfaceFallback == nil)
        #expect(record.interfaceBinding == nil)
    }

    @Test("the interface keys round-trip and become a binding")
    func interfaceKeysRoundTrip() throws {
        let record = TargetRecord(id: "t1", displayName: "NAS", host: "192.168.20.1",
                                  targetIQN: "iqn.2026-08.me.herko:disk0",
                                  networkInterface: "en18", interfaceFallback: true)
        let decoded = try JSONDecoder().decode(TargetRecord.self,
                                               from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.interfaceBinding == InterfaceBinding(name: "en18", fallback: true))
    }

    @Test("a pin with no fallback key is strict")
    func missingFallbackIsStrict() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0",
             "networkInterface":"en18"}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.interfaceBinding == InterfaceBinding(name: "en18", fallback: false))
    }

    @Test("a blank hand-edited interface name pins nothing")
    func blankInterfaceIsAutomatic() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0",
             "networkInterface":"  ","interfaceFallback":false}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.interfaceBinding == nil)
    }

    @Test("a SessionInfo from an older daemon decodes with no path")
    func olderSessionInfoDecodes() throws {
        let golden = """
            {"handle":"s1","targetIQN":"iqn.x","lun":0,"writeThrough":true,
             "recoveryCount":0,"negotiated":{}}
            """
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(golden.utf8))
        #expect(info.interfaceName == nil)
        #expect(info.interfaceFallbackFrom == nil)
    }

    @Test("SessionInfo carries the interface and the fallback through a round trip")
    func sessionInfoPathRoundTrips() throws {
        let info = SessionInfo(handle: "s1", targetIQN: "iqn.x", lun: 0, writeThrough: true,
                               recoveryCount: 0, negotiated: [:],
                               interfaceName: "en0", interfaceFallbackFrom: "en18")
        let decoded = try JSONDecoder().decode(SessionInfo.self,
                                               from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TargetRecordInterface 2>&1 | tail -15`
Expected: build failure — `extra arguments at positions … in call`, `value of type 'TargetRecord' has no member 'networkInterface'`.

- [ ] **Step 3: Add the fields**

In `Sources/iSCSIKit/XPCModels.swift`, in `TargetRecord`, after the `workloadProfile` property add:

```swift
    /// BSD name of the interface this target's connections must use
    /// ("en18"). nil: macOS routing chooses, as before 0.7.0.
    public var networkInterface: String?
    /// When `networkInterface` cannot carry the connection: nil/false fails
    /// it (strict), true falls back to macOS routing (prefer).
    public var interfaceFallback: Bool?
```

Replace the `TargetRecord` init with:

```swift
    public init(id: String, displayName: String, host: String, port: UInt16 = 3260,
                targetIQN: String, lun: UInt64 = 0, chapUser: String? = nil,
                mutualChapUser: String? = nil, autoAttach: Bool = false,
                flushIntervalSeconds: Int? = nil, workloadProfile: String? = nil,
                networkInterface: String? = nil, interfaceFallback: Bool? = nil) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.targetIQN = targetIQN
        self.lun = lun
        self.chapUser = chapUser
        self.mutualChapUser = mutualChapUser
        self.autoAttach = autoAttach
        self.flushIntervalSeconds = flushIntervalSeconds
        self.workloadProfile = workloadProfile
        self.networkInterface = networkInterface
        self.interfaceFallback = interfaceFallback
    }
```

After `public var isNVMe: Bool { IQN.isNQN(targetIQN) }` add:

```swift
    /// The pin every connection for this target uses, or nil for macOS
    /// routing. Derived, never stored.
    public var interfaceBinding: InterfaceBinding? {
        InterfaceBinding.named(networkInterface, fallback: interfaceFallback ?? false)
    }
```

In `SessionInfo`, after `public var negotiated: [String: String]` add:

```swift
    /// The interface the session's current connection runs over. nil when
    /// unknown: an older daemon, or an in-memory transport.
    public var interfaceName: String?
    /// The pinned interface a prefer-mode connection fell back from.
    public var interfaceFallbackFrom: String?
```

Replace the `SessionInfo` init with:

```swift
    public init(handle: String, targetIQN: String, lun: UInt64,
                blockSize: Int? = nil, blockCount: UInt64? = nil,
                writeCacheEnabled: Bool? = nil, writeThrough: Bool,
                recoveryCount: Int, negotiated: [String: String],
                interfaceName: String? = nil, interfaceFallbackFrom: String? = nil) {
        self.handle = handle
        self.targetIQN = targetIQN
        self.lun = lun
        self.blockSize = blockSize
        self.blockCount = blockCount
        self.writeCacheEnabled = writeCacheEnabled
        self.writeThrough = writeThrough
        self.recoveryCount = recoveryCount
        self.negotiated = negotiated
        self.interfaceName = interfaceName
        self.interfaceFallbackFrom = interfaceFallbackFrom
    }
```

(Read the current init body first; if it assigns anything not listed here, keep those assignments.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "TargetRecordInterface|TargetStore" 2>&1 | grep -E "Test run with|✘"`
Expected: pass, including the existing TargetStore golden tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/iSCSIKit/XPCModels.swift Tests/iSCSIKitTests/TargetRecordInterfaceTests.swift
git commit -F - <<'EOF'
Store a target's network interface and report a session's path

Both TargetRecord keys are optional so every existing targets.json still
decodes; a blank hand-edited name pins nothing. SessionInfo gains the
interface in use and the pin a fallback left.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 4: The daemon carries the binding to every connect

**Files:**
- Create: `Sources/iSCSIDaemon/ConnectedPathBox.swift`
- Modify: `Sources/iSCSIDaemon/DaemonCore.swift`
- Modify: `Sources/iscsid/main.swift:36-43`, `Sources/iscsictl/ISCSICtl.swift:697` (Backend B)
- Modify (closure arity only): `Tests/IntegrationTests/FlushPolicyTests.swift:24`, `WorkloadBudgetTests.swift:32`, `NVMeDaemonTests.swift:21`, `XPCServiceTests.swift:32`, `DaemonCoreTests.swift:18`, `HandleScopingTests.swift:29`, `HandleScopingTests.swift:170`
- Test: `Tests/IntegrationTests/InterfaceTestSupport.swift` (create), `Tests/IntegrationTests/InterfaceBindingDaemonTests.swift` (create)

**Interfaces:**
- Consumes: `InterfaceBinding`, `ConnectedPath`, `ConnectionPathReporting`, `InterfacePinning.Fallback` (Task 1); `NetworkTransport.connect(host:port:binding:)` (Task 2); `SessionInfo(…, interfaceName:, interfaceFallbackFrom:)` (Task 3).
- Produces:
  - `DaemonCore.init(…, transportFactory: @escaping @Sendable (String, UInt16, InterfaceBinding?) async throws -> any ConnectionTransport)`
  - `DaemonCore.discover(host:port:chap:binding:)`, `DaemonCore.discoverSubsystems(host:port:binding:)`, `DaemonCore.login(host:port:targetIQN:lun:chap:flushPolicy:binding:)` — `binding: InterfaceBinding? = nil` last in each.
  - Test helpers (internal to IntegrationTests): `BindingLog`, `PathReportingTransport`, `makeSpyCore(path:)`.

- [ ] **Step 1: Write the test support and failing tests**

Create `Tests/IntegrationTests/InterfaceTestSupport.swift`:

```swift
import Foundation
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget
import NVMeKit

/// Every binding a transport factory was handed, and the transports it made,
/// in order.
final class BindingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [InterfaceBinding?] = []
    private var made: [any ConnectionTransport] = []

    func add(_ binding: InterfaceBinding?, _ transport: any ConnectionTransport) {
        lock.lock(); bindings.append(binding); made.append(transport); lock.unlock()
    }
    var all: [InterfaceBinding?] { lock.lock(); defer { lock.unlock() }; return bindings }
    var transports: [any ConnectionTransport] { lock.lock(); defer { lock.unlock() }; return made }
}

/// An in-memory transport that reports a fixed path, standing in for what
/// `NetworkTransport` reports over a real socket.
final class PathReportingTransport: ConnectionTransport, ConnectionPathReporting, @unchecked Sendable {
    private let inner: any ConnectionTransport
    let connectedPath: ConnectedPath

    init(_ inner: any ConnectionTransport, path: ConnectedPath) {
        self.inner = inner
        self.connectedPath = path
    }
    func send(_ data: Data) async throws { try await inner.send(data) }
    func receive() async throws -> Data? { try await inner.receive() }
    func close() async { await inner.close() }
}

let spyIQN = MockTargetConfig().targetName
let spyNQN = MockNVMeConfig().subsystemNQN

/// A daemon whose factory logs every binding and reports `path`: iSCSI
/// MockTarget on 3260 (offering `spyIQN` to discovery), the NVMe mock on 4420.
func makeSpyCore(path: ConnectedPath = ConnectedPath(interfaceName: "en18"))
    -> (DaemonCore, BindingLog, HarnessBox) {
    let log = BindingLog()
    let harnesses = HarnessBox()
    let iscsiDisk = RAMDisk()
    let subsystem = MockNVMeSubsystem(disk: RAMDisk(blockSize: 4096, capacityBlocks: 4096))
    let core = DaemonCore(initiatorName: "iqn.test:initiator", policy: testPolicy(),
                          hostIdentity: testHost) { _, port, binding in
        let (initiatorSide, targetSide) = MemoryPipe.pair()
        if port == 4420 {
            harnesses.add(Task { await subsystem.serve(targetSide) })
        } else {
            var config = MockTargetConfig()
            config.discoveryTargets = [(name: spyIQN, addresses: ["127.0.0.1:3260,1"])]
            let target = MockTarget(config: config, disk: iscsiDisk, transport: targetSide)
            harnesses.add(Task { await target.run() })
        }
        let transport = PathReportingTransport(initiatorSide, path: path)
        log.add(binding, transport)
        return transport
    }
    return (core, log, harnesses)
}
```

Create `Tests/IntegrationTests/InterfaceBindingDaemonTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

/// The binding must reach every connect a session makes — the first, both
/// NVMe queues, and each recovery reconnect — or a pin holds until the
/// first dropped connection and then silently stops.
@Suite("Interface binding through the daemon", .timeLimit(.minutes(1)))
struct InterfaceBindingDaemonTests {

    private let pinned = InterfaceBinding(name: "en18", fallback: false)

    @Test("an iSCSI login hands its binding to the transport factory")
    func iscsiLoginCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let handle = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN,
                                          lun: 0, binding: pinned)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == pinned })
        try await core.logout(handle)
    }

    @Test("both NVMe queues are pinned")
    func nvmeQueuesCarryBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let handle = try await core.login(host: "nas", port: 4420, targetIQN: spyNQN,
                                          lun: 1, binding: pinned)
        #expect(log.all.count == 2, "admin queue and I/O queue")
        #expect(log.all.allSatisfy { $0 == pinned })
        try await core.logout(handle)
    }

    @Test("a recovery reconnect is pinned like the first connect")
    func recoveryCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let handle = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN,
                                          lun: 0, binding: pinned)
        let first = try #require(log.transports.first)
        await first.close()
        _ = try await core.read(handle, offset: 0, length: 512)
        #expect(log.all.count >= 2, "the read must have rebuilt the connection")
        #expect(log.all.allSatisfy { $0 == pinned })
    }

    @Test("an unpinned login hands the factory no binding")
    func unpinnedLoginPassesNil() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        _ = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == nil })
    }

    @Test("iSCSI discovery is pinned")
    func discoveryCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        _ = try await core.discover(host: "nas", port: 3260, binding: pinned)
        #expect(log.all.count == 1)
        #expect(log.all.first == pinned)
    }

    /// Whether the mock answers NVMe discovery does not matter here — only
    /// that the connect it attempted was pinned.
    @Test("NVMe discovery is pinned")
    func nvmeDiscoveryCarriesBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        _ = try? await core.discoverSubsystems(host: "nas", port: 4420, binding: pinned)
        #expect(log.all.first == pinned)
    }

    @Test("the session list reports the interface and the pin a fallback left")
    func sessionDetailsReportPath() async throws {
        let (core, _, harnesses) = makeSpyCore(path: ConnectedPath(
            interfaceName: "en0",
            fallback: InterfacePinning.Fallback(from: "en18", reason: "it is not present")))
        defer { harnesses.cancelAll() }
        _ = try await core.login(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0,
                                 binding: InterfaceBinding(name: "en18", fallback: true))
        let details = await core.sessionDetails()
        #expect(details.count == 1)
        #expect(details.first?.interfaceName == "en0")
        #expect(details.first?.interfaceFallbackFrom == "en18")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InterfaceBindingDaemon 2>&1 | tail -15`
Expected: build failure — the factory closure `{ _, port, binding in` does not match the two-argument factory type; `extra argument 'binding'`.

- [ ] **Step 3: Write `ConnectedPathBox`**

Create `Sources/iSCSIDaemon/ConnectedPathBox.swift`:

```swift
import Foundation
import iSCSIKit
import os

/// One session's most recent connect outcome. Every connect updates it — the
/// first and each recovery reconnect — so the Sessions window shows the path
/// the session is on now, not the one it started on.
final class ConnectedPathBox: Sendable {
    private let label: String
    private let state = OSAllocatedUnfairLock<ConnectedPath?>(initialState: nil)

    init(label: String) { self.label = label }

    var current: ConnectedPath? { state.withLock { $0 } }

    /// Note which interface `transport` connected over, log one line, and
    /// hand the transport back unchanged. A transport that cannot say (an
    /// in-memory pipe) is passed through and records nothing.
    func record(_ transport: any ConnectionTransport) -> any ConnectionTransport {
        guard let reporting = transport as? ConnectionPathReporting else { return transport }
        let path = reporting.connectedPath
        state.withLock { $0 = path }
        var line = "\(label): connected via \(path.interfaceName ?? "an unknown interface")"
        if let fallback = path.fallback {
            line += " — fell back from \(fallback.from): \(fallback.reason)"
        }
        DaemonLog.session(line)
        return transport
    }
}
```

- [ ] **Step 4: Thread the binding through `DaemonCore`**

In `Sources/iSCSIDaemon/DaemonCore.swift`:

1. In `struct SessionEntry`, after `let flushPolicy: FlushPolicy` add:
   ```swift
        /// Where the session's connection runs now, for `sessionDetails`.
        let path: ConnectedPathBox
   ```
2. Change the factory property and its init parameter type from `@Sendable (String, UInt16) async throws -> any ConnectionTransport` to `@Sendable (String, UInt16, InterfaceBinding?) async throws -> any ConnectionTransport` (two places: the `private let transportFactory` declaration and the `transportFactory:` parameter of `init`). Update the property's doc comment's last sentence to: "NVMe calls it twice per attach (admin queue, I/O queue) and twice per recovery; the binding is the target's interface pin, nil for macOS routing."
3. Replace `discover` and `discoverSubsystems` with:
   ```swift
    public func discover(host: String, port: UInt16, chap: CHAP.Credentials? = nil,
                         binding: InterfaceBinding? = nil) async throws -> [DiscoveredTarget] {
        let transport = try await transportFactory(host, port, binding)
        return try await Discovery.sendTargets(
            transport: transport,
            initiatorName: initiatorName,
            chap: chap,
            trace: Self.authTrace
        )
    }

    /// NVMe/TCP discovery at a portal: the discovery log page's subsystems.
    public func discoverSubsystems(host: String, port: UInt16,
                                   binding: InterfaceBinding? = nil) async throws -> [DiscoveredTarget] {
        let transport = try await transportFactory(host, port, binding)
        return try await NVMeDiscovery.getLogPage(transport: transport, host: hostIdentity)
    }
   ```
4. In `login`, add the parameter `binding: InterfaceBinding? = nil` after `flushPolicy: FlushPolicy? = nil`. Before the `let session: any FabricSession` line add `let path = ConnectedPathBox(label: targetIQN)`. Pass `binding: binding, path: path` as the last two arguments to both `attachNVMe(…)` and `attachISCSI(…)`. In the `SessionEntry(…)` construction add `path: path` after `flushPolicy: durability`.
5. In `attachISCSI` add parameters `binding: InterfaceBinding?, path: ConnectedPathBox` after `writeThrough: Bool`, and replace
   ```swift
        let session = ISCSISession(login: config, policy: policy) {
            try await factory(host, port)
        }
   ```
   with
   ```swift
        let session = ISCSISession(login: config, policy: policy) {
            path.record(try await factory(host, port, binding))
        }
   ```
6. In `attachNVMe` add the same two parameters and replace
   ```swift
        let controller = NVMeController(config: config, policy: policy) {
            try await factory(host, port)
        }
   ```
   with
   ```swift
        let controller = NVMeController(config: config, policy: policy) {
            path.record(try await factory(host, port, binding))
        }
   ```
7. In `sessionDetails`, before `out.append(SessionInfo(` add `let path = entry.path.current`, and add these two arguments after `negotiated: negotiated`:
   ```swift
                negotiated: negotiated,
                interfaceName: path?.interfaceName,
                interfaceFallbackFrom: path?.fallback?.from
   ```

- [ ] **Step 5: Update every factory construction site**

`Sources/iscsid/main.swift` — replace
```swift
) { host, port in
    try await NetworkTransport.connect(host: host, port: port)
}
```
with
```swift
) { host, port, binding in
    try await NetworkTransport.connect(host: host, port: port, binding: binding)
}
```

`Sources/iscsictl/ISCSICtl.swift:697` (inside `#if ISCSI_BACKEND_B`) — replace `let core = DaemonCore(initiatorName: initiator) { host, port in` with `let core = DaemonCore(initiatorName: initiator) { host, port, _ in`.

Tests — add the third closure parameter:

```bash
sed -i '' 's/) { _, _ in$/) { _, _, _ in/' \
  Tests/IntegrationTests/FlushPolicyTests.swift Tests/IntegrationTests/WorkloadBudgetTests.swift \
  Tests/IntegrationTests/XPCServiceTests.swift Tests/IntegrationTests/DaemonCoreTests.swift \
  Tests/IntegrationTests/HandleScopingTests.swift
sed -i '' 's/hostIdentity: testHost) { _, port in$/hostIdentity: testHost) { _, port, _ in/' \
  Tests/IntegrationTests/NVMeDaemonTests.swift
grep -rn "DaemonCore(" Tests Sources | grep -v "DaemonCore.swift"
```

Expected from the grep: every `DaemonCore(` closure now takes three parameters (seven test sites, `iscsid/main.swift`, `ISCSICtl.swift:697`). Fix any line the seds missed by hand.

- [ ] **Step 6: Build both configurations and run the tests**

Run: `swift build 2>&1 | grep -E "error|warning: unre" ; swift build -Xswiftc -DISCSI_BACKEND_B 2>&1 | grep -E "error" ; swift test --filter "InterfaceBindingDaemon|DaemonCore|NVMeDaemon|FlushPolicy|WorkloadBudget|HandleScoping|XPCService" 2>&1 | grep -E "Test run with|✘"`
Expected: no errors from either build; all listed suites pass.

If `recoveryCarriesBinding` fails because the read surfaces the closed connection as an error instead of recovering, check `testPolicy()`'s `taskRetries` (2) and replace the single read with a loop of up to three reads that ignores errors from all but the last — the assertion that matters is that every factory call carried the binding.

- [ ] **Step 7: Commit**

```bash
git add Sources/iSCSIDaemon/ConnectedPathBox.swift Sources/iSCSIDaemon/DaemonCore.swift \
        Sources/iscsid/main.swift Sources/iscsictl/ISCSICtl.swift Tests/IntegrationTests
git commit -F - <<'EOF'
Carry the interface binding to every connect the daemon makes

The transport factory takes the binding, so the first connect, both NVMe
queues and every recovery reconnect are pinned alike. Each session keeps
its latest connect outcome, logs it, and reports it in SessionInfo.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 5: XPC — the record's pin for login, an explicit pin for discovery

**Files:**
- Modify: `Sources/iSCSIKit/XPCProtocol.swift:125-135`
- Modify: `Sources/iSCSIDaemon/XPCService.swift` (`login`, `discoverTargets`, `discoverSubsystems`, `testConnection`)
- Modify: `apps/iSCSIApp/Client/DaemonClient.swift:101-121`
- Modify: `Tests/IntegrationTests/DaemonStoreTests.swift:100-108` (FakeDaemon), `Tests/IntegrationTests/XPCServiceTests.swift:333`
- Test: `Tests/IntegrationTests/InterfaceBindingXPCTests.swift` (create)

**Interfaces:**
- Consumes: `makeSpyCore`, `BindingLog`, `spyIQN` (Task 4); `TargetRecord.interfaceBinding` (Task 3); `InterfaceBinding.named` (Task 1); `DaemonCore.login/discover/discoverSubsystems(…, binding:)` (Task 4).
- Produces:
  - `ISCSIDaemonProtocol.discoverTargets(host:port:chapUser:chapSecret:interfaceName:interfaceFallback:reply:)`
  - `ISCSIDaemonProtocol.discoverSubsystems(host:port:interfaceName:interfaceFallback:reply:)`
  - `DaemonConnection.discoverTargets(host:port:chapUser:chapSecret:interface: InterfaceBinding? = nil)`, `DaemonConnection.discoverSubsystems(host:port:interface: InterfaceBinding? = nil)` (app)

- [ ] **Step 1: Write the failing tests**

Create `Tests/IntegrationTests/InterfaceBindingXPCTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

/// Login and the editor's test probe take the pin from the saved record — a
/// client cannot choose it, and the probe validates what an attach will run.
/// Discovery has no record yet, so it takes the pin as parameters.
@Suite("Interface binding through XPC", .timeLimit(.minutes(1)))
struct InterfaceBindingXPCTests {

    private func makeStore(_ records: [TargetRecord] = []) async throws -> TargetStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        let store = TargetStore(url: url)
        for record in records { try await store.save(record) }
        return store
    }

    private func pinnedRecord() -> TargetRecord {
        TargetRecord(id: "t1", displayName: "NAS", host: "nas", port: 3260,
                     targetIQN: spyIQN, lun: 0,
                     networkInterface: "en18", interfaceFallback: true)
    }

    @Test("login pins to the saved target's interface")
    func loginUsesRecordBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore([pinnedRecord()]))
        let (handle, error) = await withCheckedContinuation { c in
            service.login(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(error == nil)
        #expect(handle != nil)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == InterfaceBinding(name: "en18", fallback: true) })
    }

    @Test("the connection test pins exactly as login does")
    func testConnectionUsesRecordBinding() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore([pinnedRecord()]))
        let (data, error) = await withCheckedContinuation { c in
            service.testConnection(host: "nas", port: 3260, targetIQN: spyIQN, lun: 0) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(error == nil)
        #expect(data != nil)
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 == InterfaceBinding(name: "en18", fallback: true) })
    }

    @Test("iSCSI discovery pins to the interface it is given")
    func discoverTargetsUsesParameters() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore())
        let (data, error) = await withCheckedContinuation { c in
            service.discoverTargets(host: "nas", port: 3260, chapUser: nil, chapSecret: nil,
                                    interfaceName: "en17", interfaceFallback: false) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(error == nil)
        #expect(data != nil)
        #expect(log.all == [InterfaceBinding(name: "en17", fallback: false)])
    }

    /// The app sends "" when the picker is on Automatic.
    @Test("an empty interface name discovers unpinned")
    func emptyInterfaceNameIsAutomatic() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore())
        _ = await withCheckedContinuation { c in
            service.discoverTargets(host: "nas", port: 3260, chapUser: nil, chapSecret: nil,
                                    interfaceName: "", interfaceFallback: true) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(log.all == [nil])
    }

    @Test("NVMe discovery pins to the interface it is given")
    func discoverSubsystemsUsesParameters() async throws {
        let (core, log, harnesses) = makeSpyCore()
        defer { harnesses.cancelAll() }
        let service = ISCSIXPCService(core: core, targets: try await makeStore())
        _ = await withCheckedContinuation { c in
            service.discoverSubsystems(host: "nas", port: 4420,
                                       interfaceName: "en18", interfaceFallback: true) {
                c.resume(returning: ($0, $1))
            }
        }
        #expect(log.all.first == InterfaceBinding(name: "en18", fallback: true))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InterfaceBindingXPC 2>&1 | tail -15`
Expected: build failure — `extra arguments 'interfaceName', 'interfaceFallback' in call`.

- [ ] **Step 3: Change the protocol**

In `Sources/iSCSIKit/XPCProtocol.swift` replace the two discovery declarations with:

```swift
    /// SendTargets against a portal, with optional CHAP. Reply: JSON
    /// `[DiscoveredTargetInfo]`. `interfaceName` pins the connection (nil or
    /// empty: macOS routing); `interfaceFallback` is prefer (true) versus
    /// strict (false). Taken from the caller because no record exists yet.
    func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                         chapSecret: String?, interfaceName: String?, interfaceFallback: Bool,
                         reply: @escaping (Data?, Error?) -> Void)

    /// NVMe/TCP discovery: read the discovery log page at this portal. Reply:
    /// JSON `[DiscoveredTargetInfo]`, `targetIQN` carrying each subsystem
    /// NQN. Its own method rather than a flag on `discoverTargets`: discovery
    /// happens before there is a name to tell the protocols apart by.
    /// `interfaceName`/`interfaceFallback` as for `discoverTargets`.
    func discoverSubsystems(host: String, port: NSNumber, interfaceName: String?,
                            interfaceFallback: Bool, reply: @escaping (Data?, Error?) -> Void)
```

- [ ] **Step 4: Change the service**

In `Sources/iSCSIDaemon/XPCService.swift`:

1. `login`: in the `core.login(` call add `binding: record.interfaceBinding` after the `flushPolicy:` argument:
   ```swift
                let handle = try await core.login(
                    host: host, port: port.uint16Value,
                    targetIQN: targetIQN, lun: lun.uint64Value, chap: chap,
                    flushPolicy: FlushPolicy(intervalSeconds: record.flushIntervalSeconds),
                    binding: record.interfaceBinding
                )
   ```
2. `testConnection`: change `let (_, chap) = try await self.credentials(` to `let (record, chap) = try await self.credentials(`, and its `core.login(` call to:
   ```swift
                let handle = try await core.login(
                    host: host, port: port.uint16Value, targetIQN: targetIQN,
                    lun: lun.uint64Value, chap: chap, binding: record.interfaceBinding)
   ```
   Extend the comment above it: "…would validate something the user never runs — the interface pin included."
3. `discoverTargets`: change the signature to
   ```swift
    public func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                                chapSecret: String?, interfaceName: String?,
                                interfaceFallback: Bool,
                                reply: @escaping (Data?, Error?) -> Void) {
   ```
   and the core call to
   ```swift
                let found = try await core.discover(
                    host: host, port: port.uint16Value, chap: chap,
                    binding: InterfaceBinding.named(interfaceName, fallback: interfaceFallback))
   ```
4. `discoverSubsystems`: change the signature to
   ```swift
    public func discoverSubsystems(host: String, port: NSNumber, interfaceName: String?,
                                   interfaceFallback: Bool,
                                   reply: @escaping (Data?, Error?) -> Void) {
   ```
   and the core call to
   ```swift
                let found = try await core.discoverSubsystems(
                    host: host, port: port.uint16Value,
                    binding: InterfaceBinding.named(interfaceName, fallback: interfaceFallback))
   ```

- [ ] **Step 5: Update the fake daemon and the existing XPC test**

In `Tests/IntegrationTests/DaemonStoreTests.swift`, replace the two `FakeDaemon` methods with:

```swift
    func discoverSubsystems(host: String, port: NSNumber, interfaceName: String?,
                            interfaceFallback: Bool, reply: @escaping (Data?, Error?) -> Void) {
        reply(nil, nil)
    }
```
and
```swift
    func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                         chapSecret: String?, interfaceName: String?, interfaceFallback: Bool,
                         reply: @escaping (Data?, Error?) -> Void) { reply(nil, nil) }
```

In `Tests/IntegrationTests/XPCServiceTests.swift` (`discoveryValidatesSecretLength`), change
```swift
            service.discoverTargets(host: "mock", port: 3260,
                                    chapUser: "someone", chapSecret: "tooshort") {
```
to
```swift
            service.discoverTargets(host: "mock", port: 3260,
                                    chapUser: "someone", chapSecret: "tooshort",
                                    interfaceName: nil, interfaceFallback: false) {
```

- [ ] **Step 6: Update the app's client wrappers**

In `apps/iSCSIApp/Client/DaemonClient.swift` replace the two discovery wrappers with:

```swift
    static func discoverTargets(host: String, port: UInt16,
                                chapUser: String?, chapSecret: String?,
                                interface: InterfaceBinding? = nil)
        async throws -> [DiscoveredTargetInfo] {
        try await decode([DiscoveredTargetInfo].self) { proxy, finish in
            proxy.discoverTargets(host: host, port: NSNumber(value: port),
                                  chapUser: chapUser, chapSecret: chapSecret,
                                  interfaceName: interface?.name,
                                  interfaceFallback: interface?.fallback ?? false) { data, error in
                finish(data, error)
            }
        }
    }

    /// NVMe/TCP discovery: the subsystems a portal's discovery log page lists,
    /// with `targetIQN` carrying each subsystem NQN. No credentials: NVMe-oF
    /// discovery has none, and access is decided per subsystem by host NQN.
    static func discoverSubsystems(host: String, port: UInt16,
                                   interface: InterfaceBinding? = nil)
        async throws -> [DiscoveredTargetInfo] {
        try await decode([DiscoveredTargetInfo].self) { proxy, finish in
            proxy.discoverSubsystems(host: host, port: NSNumber(value: port),
                                     interfaceName: interface?.name,
                                     interfaceFallback: interface?.fallback ?? false) { data, error in
                finish(data, error)
            }
        }
    }
```

- [ ] **Step 7: Run the tests, and compile the app**

Run: `swift test --filter "InterfaceBindingXPC|XPCService|DaemonStore|HandleScoping|NVMeDaemon" 2>&1 | grep -E "Test run with|✘"`
Expected: all pass.

Run: `cd apps && xcodegen generate && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; cd ..; git status --short apps/`
Expected: `** BUILD SUCCEEDED **`. No new app files yet, so `git status` should show no `.pbxproj` change; if it does, regenerate with `SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate` and confirm the diff is empty before continuing.

- [ ] **Step 8: Commit**

```bash
git add Sources/iSCSIKit/XPCProtocol.swift Sources/iSCSIDaemon/XPCService.swift \
        apps/iSCSIApp/Client/DaemonClient.swift Tests/IntegrationTests
git commit -F - <<'EOF'
Pin login and discovery over XPC

Login and the editor's connection test take the pin from the saved
record, so a client cannot choose it and the test validates what attach
will run. Discovery precedes any record and takes it as parameters; an
empty name means Automatic.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 6: `iscsictl --interface`

**Files:**
- Modify: `Sources/iscsictl/ISCSICtl.swift` (`GlobalOptions`, lines 52-121)
- Modify: `Sources/iscsictl/NVMeCommands.swift` (`NVMeOptions`, lines 19-66)

**Interfaces:**
- Consumes: `NetworkTransport.connect(host:port:binding:)`, `connectedPath` (Task 2); `InterfaceBinding.named` (Task 1).
- Produces: `--interface NAME` on every `iscsictl` command built on `GlobalOptions` or `NVMeOptions`.

No unit test: argument parsing is swift-argument-parser's, and the behaviour is `NetworkTransport`'s, tested in Task 2. This task's test is the loopback run in Step 3.

- [ ] **Step 1: Add the option to `GlobalOptions`**

In `Sources/iscsictl/ISCSICtl.swift`, in `struct GlobalOptions`, after the `debug` flag add:

```swift
    @Option(help: ArgumentHelp(
        "Network interface to connect over, by BSD name (e.g. en18).",
        discussion: "Strict: the connection fails rather than use any other interface. "
            + "Omit to let macOS routing choose."))
    var interface: String?
```

and replace its `openTransport()` with:

```swift
    func openTransport() async throws -> any ConnectionTransport {
        #if canImport(Network)
        let tcp = try await NetworkTransport.connect(
            host: host, port: port,
            binding: InterfaceBinding.named(interface, fallback: false))
        if interface != nil {
            FileHandle.standardError.write(Data(
                "connected via \(tcp.connectedPath.interfaceName ?? "an unknown interface")\n".utf8))
        }
        return debug ? TracingTransport(tcp, label: host) : tcp
        #else
        throw ValidationError("Network.framework unavailable on this platform")
        #endif
    }
```

- [ ] **Step 2: Add the option to `NVMeOptions`**

In `Sources/iscsictl/NVMeCommands.swift`, in `struct NVMeOptions`, after the `debug` flag add the same `@Option … var interface: String?` declaration as Step 1, and replace its `openTransport()` with:

```swift
    func openTransport() async throws -> any ConnectionTransport {
        #if canImport(Network)
        let tcp = try await NetworkTransport.connect(
            host: host, port: port,
            binding: InterfaceBinding.named(interface, fallback: false))
        if interface != nil {
            FileHandle.standardError.write(Data(
                "connected via \(tcp.connectedPath.interfaceName ?? "an unknown interface")\n".utf8))
        }
        return debug ? NVMeTracingTransport(tcp, label: host) : tcp
        #else
        throw ValidationError("Network.framework unavailable on this platform")
        #endif
    }
```

- [ ] **Step 3: Exercise it against the simulator on loopback**

```bash
swift build
swift run iscsi-target-sim --port 3260 --capacity-mib 64 &
SIM=$!
sleep 3
swift run iscsictl discover 127.0.0.1 --interface lo0
swift run iscsictl discover 127.0.0.1 --interface nosuch0; echo "exit=$?"
kill $SIM
```

Expected: the first prints `connected via lo0` on stderr and then the simulator's target(s). The second fails within a second with an error naming `nosuch0` and "it is not present", and exits non-zero.

- [ ] **Step 4: Commit**

```bash
git add Sources/iscsictl/ISCSICtl.swift Sources/iscsictl/NVMeCommands.swift
git commit -F - <<'EOF'
Add iscsictl --interface for pinned test connections

Strict only — a fallback would hide the thing being tested — and it says
on stderr which interface the connection actually used.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 7: The app — picker, editor, discovery, Sessions window

**Files:**
- Create: `Sources/iSCSIKit/Transport/InterfaceChoices.swift`
- Create: `apps/iSCSIApp/Client/NetworkInterfaceNames.swift`
- Create: `apps/iSCSIApp/Windows/InterfacePicker.swift`
- Modify: `apps/iSCSIApp/Windows/TargetsView.swift`, `apps/iSCSIApp/Windows/DiscoveryView.swift`, `apps/iSCSIApp/Windows/SessionsView.swift`
- Modify (generated): `apps/iSCSIInitiator.xcodeproj/project.pbxproj`
- Test: `Tests/iSCSIKitTests/InterfaceChoicesTests.swift` (create)

**Interfaces:**
- Consumes: `InterfaceSnapshot`, `InterfaceAddress`, `InterfacePinning.isLinkLocal`, `InterfaceBinding.named` (Task 1); `SystemInterfaces.snapshot()` (Task 2); `TargetRecord(…, networkInterface:, interfaceFallback:)`, `interfaceBinding`, `SessionInfo.interfaceName/interfaceFallbackFrom` (Task 3); `DaemonConnection.discoverTargets/discoverSubsystems(…, interface:)` (Task 5).
- Produces:
  - `public struct InterfaceChoice: Sendable, Equatable, Identifiable { var name: String; var label: String }`
  - `public enum InterfaceChoices { static func list(snapshot:displayNames:stored:) -> [InterfaceChoice] }`
  - App: `NetworkInterfaceNames.localized() -> [String: String]`, `InterfacePicker(name: Binding<String?>, fallback: Binding<Bool>)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/iSCSIKitTests/InterfaceChoicesTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIKit

@Suite("Interface picker rows")
struct InterfaceChoicesTests {

    private static let snapshot = InterfaceSnapshot(
        present: ["lo0", "en0", "en2", "en10", "en7"],
        addresses: [
            InterfaceAddress(name: "lo0", address: "127.0.0.1", isIPv6: false),
            InterfaceAddress(name: "en10", address: "fe80::1%en10", isIPv6: true),
            InterfaceAddress(name: "en10", address: "192.168.20.2", isIPv6: false),
            InterfaceAddress(name: "en2", address: "2001:db8::5", isIPv6: true),
            InterfaceAddress(name: "en0", address: "192.168.0.22", isIPv6: false),
            InterfaceAddress(name: "en7", address: "169.254.3.4", isIPv6: false),
        ])

    @Test("only interfaces with a usable address are offered, in natural order")
    func offersAddressedInterfacesNaturally() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot, displayNames: [:], stored: nil)
        #expect(rows.map(\.name) == ["en0", "en2", "en10"],
                "lo0 and the link-local-only en7 are left out; en2 sorts before en10")
    }

    @Test("a row shows the display name, the BSD name and an IPv4 address first")
    func labelsReadLikeSystemSettings() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot,
                                         displayNames: ["en10": "USB 10GbE", "en0": "Wi-Fi"],
                                         stored: nil)
        #expect(rows.first { $0.name == "en10" }?.label == "USB 10GbE (en10) — 192.168.20.2")
        #expect(rows.first { $0.name == "en0" }?.label == "Wi-Fi (en0) — 192.168.0.22")
        #expect(rows.first { $0.name == "en2" }?.label == "en2 — 2001:db8::5")
    }

    @Test("a stored interface that is gone stays listed, marked not present")
    func storedAbsentInterfaceIsKept() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot,
                                         displayNames: ["en18": "USB 10GbE"], stored: "en18")
        #expect(rows.last == InterfaceChoice(name: "en18", label: "USB 10GbE (en18) — not present"))
    }

    @Test("a stored interface that is present without an address says so")
    func storedAddresslessInterfaceIsKept() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot, displayNames: [:], stored: "en7")
        #expect(rows.last == InterfaceChoice(name: "en7", label: "en7 — no address"))
    }

    @Test("a stored interface that is offered anyway is not listed twice")
    func storedPresentInterfaceIsNotDuplicated() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot, displayNames: [:], stored: "en0")
        #expect(rows.filter { $0.name == "en0" }.count == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InterfaceChoices 2>&1 | tail -10`
Expected: build failure — `cannot find 'InterfaceChoices' in scope`.

- [ ] **Step 3: Write `InterfaceChoices`**

Create `Sources/iSCSIKit/Transport/InterfaceChoices.swift`:

```swift
import Foundation

/// One row of the interface picker.
public struct InterfaceChoice: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// BSD name — what is stored in the target record.
    public var name: String
    /// What the user reads: "USB 10GbE (en18) — 192.168.20.2".
    public var label: String

    public init(name: String, label: String) {
        self.name = name
        self.label = label
    }
}

/// The picker's rows, built from a snapshot so the logic is testable without
/// the machine's real interfaces.
public enum InterfaceChoices {
    /// Every interface holding a usable address, except loopback (nothing
    /// remote is reachable through it), in natural order. The stored name is
    /// appended when it is not among them, so editing a target never silently
    /// drops its pin.
    public static func list(snapshot: InterfaceSnapshot,
                            displayNames: [String: String],
                            stored: String?) -> [InterfaceChoice] {
        var held: [String: [InterfaceAddress]] = [:]
        for address in snapshot.addresses
        where address.name != "lo0" && !InterfacePinning.isLinkLocal(address) {
            held[address.name, default: []].append(address)
        }
        func title(_ name: String) -> String {
            displayNames[name].map { "\($0) (\(name))" } ?? name
        }
        var rows = held.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name -> InterfaceChoice in
                let addresses = held[name] ?? []
                // IPv4 first: it is what a portal address almost always is.
                let shown = addresses.first(where: { !$0.isIPv6 }) ?? addresses[0]
                return InterfaceChoice(name: name, label: "\(title(name)) — \(shown.address)")
            }
        if let stored, !stored.isEmpty, held[stored] == nil {
            let state = snapshot.present.contains(stored) ? "no address" : "not present"
            rows.append(InterfaceChoice(name: stored, label: "\(title(stored)) — \(state)"))
        }
        return rows
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter InterfaceChoices 2>&1 | grep -E "Test run with|✘"`
Expected: 5 tests pass.

- [ ] **Step 5: Write the app's display-name lookup**

Create `apps/iSCSIApp/Client/NetworkInterfaceNames.swift`:

```swift
//
//  NetworkInterfaceNames.swift
//  The names System Settings shows for each network interface.
//

import Foundation
import SystemConfiguration

/// Display names ("Wi-Fi", "USB 10/100/1G/2.5G LAN") keyed by BSD name. Best
/// effort: an interface SystemConfiguration does not know keeps its BSD name
/// alone in the picker.
enum NetworkInterfaceNames {
    static func localized() -> [String: String] {
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        var names: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let shown = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            names[bsd] = shown
        }
        return names
    }
}
```

- [ ] **Step 6: Write the shared picker**

Create `apps/iSCSIApp/Windows/InterfacePicker.swift`:

```swift
//
//  InterfacePicker.swift
//  The network-interface rows shared by the target editor and Discover.
//

import SwiftUI
import iSCSIKit

/// Automatic, or one interface plus what to do when it cannot be used. Lives
/// inside a Form section; the caller supplies the section and its footer.
struct InterfacePicker: View {
    /// nil: Automatic — macOS routing chooses.
    @Binding var name: String?
    /// false: strict (fail). true: prefer (fall back).
    @Binding var fallback: Bool
    @State private var choices: [InterfaceChoice] = []

    var body: some View {
        Group {
            Picker("Network interface", selection: $name) {
                Text("Automatic (macOS chooses)").tag(String?.none)
                ForEach(choices) { choice in
                    Text(choice.label).tag(String?.some(choice.name))
                }
            }
            if name != nil {
                Picker("When unavailable", selection: $fallback) {
                    Text("Fail the connection").tag(false)
                    Text("Use another interface").tag(true)
                }
                Text(fallback
                     ? "Falls back to whatever macOS picks when this interface is missing "
                       + "or has no route, and tries it again at the next reconnect."
                     : "Never uses another interface — not Wi-Fi, not a VPN. If this one "
                       + "is unavailable, the connection fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
    }

    /// Read when the sheet opens: interfaces come and go, and a stale list
    /// would offer one that is gone or hide one just plugged in.
    private func refresh() {
        choices = InterfaceChoices.list(snapshot: SystemInterfaces.snapshot(),
                                        displayNames: NetworkInterfaceNames.localized(),
                                        stored: name)
    }
}
```

- [ ] **Step 7: Use it in the target editor**

In `apps/iSCSIApp/Windows/TargetsView.swift`:

1. After `@State private var suppressFlushPrompt = false` add:
   ```swift
    /// nil = Automatic. Mirrors `TargetRecord.networkInterface`.
    @State private var networkInterface: String?
    /// Prefer (true) or strict (false); stored only when an interface is set.
    @State private var interfaceFallback: Bool
   ```
2. In `init`, after `_flushInterval = State(initialValue: target?.flushIntervalSeconds)` add:
   ```swift
        _networkInterface = State(initialValue: target?.interfaceBinding?.name)
        _interfaceFallback = State(initialValue: target?.interfaceFallback ?? false)
   ```
3. In `body`, directly after the first `Section { … }` (the one ending with `TextField(isNVMe ? "Namespace ID" : "LUN", text: $lun)`) add:
   ```swift
                Section {
                    InterfacePicker(name: $networkInterface, fallback: $interfaceFallback)
                } header: {
                    Text("Network")
                } footer: {
                    Text("Takes effect the next time this target is attached.")
                        .font(.caption).foregroundStyle(.secondary)
                }
   ```
4. In `save()`, change the end of the `TargetRecord(` call from
   ```swift
            workloadProfile: existing?.workloadProfile)
   ```
   to
   ```swift
            workloadProfile: existing?.workloadProfile,
            networkInterface: networkInterface,
            interfaceFallback: networkInterface == nil ? nil : interfaceFallback)
   ```

- [ ] **Step 8: Use it in Discover**

In `apps/iSCSIApp/Windows/DiscoveryView.swift`:

1. After `@State private var chapSecret = ""` add:
   ```swift
    @State private var networkInterface: String?
    @State private var interfaceFallback = false
   ```
2. After the `Section { … } header: { Text("Portal") } footer: { … }` block add:
   ```swift
                Section("Network") {
                    InterfacePicker(name: $networkInterface, fallback: $interfaceFallback)
                }
   ```
3. Change `.frame(maxHeight: 300)` to `.frame(maxHeight: 400)`.
4. In `search()`, add `interface: InterfaceBinding.named(networkInterface, fallback: interfaceFallback)` as the last argument to both `DaemonConnection.discoverSubsystems(…)` and `DaemonConnection.discoverTargets(…)`.
5. In `add(_:)`, change the end of the `TargetRecord(` call from
   ```swift
            chapUser: (isNVMe || chapUser.isEmpty) ? nil : chapUser)
   ```
   to
   ```swift
            chapUser: (isNVMe || chapUser.isEmpty) ? nil : chapUser,
            networkInterface: networkInterface,
            interfaceFallback: networkInterface == nil ? nil : interfaceFallback)
   ```
   and extend the comment above it: "…Carry the discovery credentials **and interface** onto the target: a portal that needed them to list its targets will need them to log in…"

- [ ] **Step 9: Show the path in the Sessions window**

In `apps/iSCSIApp/Windows/SessionsView.swift`, in `SessionDetail.body`, directly before `group("Durability") {` add:

```swift
                group("Network") {
                    row("Interface", interfaceText)
                }
```

and add to `SessionDetail`:

```swift
    /// "en18", "en0 (fell back from en18)", or "—" when the daemon cannot say.
    private var interfaceText: String {
        guard let name = session.interfaceName else { return "—" }
        guard let from = session.interfaceFallbackFrom else { return name }
        return "\(name) (fell back from \(from))"
    }
```

- [ ] **Step 10: Regenerate the project and build the app**

```bash
cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd ..
git diff --stat apps/iSCSIInitiator.xcodeproj
cd apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning:.*(InterfacePicker|NetworkInterfaceNames|TargetsView|DiscoveryView|SessionsView)|BUILD (SUCCEEDED|FAILED)"; cd ..
```

Expected: the `.pbxproj` diff adds exactly `InterfacePicker.swift` and `NetworkInterfaceNames.swift`; `** BUILD SUCCEEDED **` with no errors or warnings in the touched files.

- [ ] **Step 11: Commit**

```bash
git add Sources/iSCSIKit/Transport/InterfaceChoices.swift Tests/iSCSIKitTests/InterfaceChoicesTests.swift \
        apps/iSCSIApp/Client/NetworkInterfaceNames.swift apps/iSCSIApp/Windows/InterfacePicker.swift \
        apps/iSCSIApp/Windows/TargetsView.swift apps/iSCSIApp/Windows/DiscoveryView.swift \
        apps/iSCSIApp/Windows/SessionsView.swift apps/iSCSIInitiator.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
Add the interface picker to the target editor, Discover and Sessions

Automatic by default; a chosen interface adds strict-or-prefer. Rows
read like System Settings and keep a stored interface that has gone
missing, so an edit never drops a pin. Sessions shows the interface in
use and any fallback.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 8: Docs, full verification, and the real network

**Files:**
- Modify: `README.md` (end of "Run it on a network you trust", before `## Building`)
- Modify: `docs/open-questions.md` (new section before `## A note on method`)
- Modify: `docs/test-playbook.md` (new section before `## Fuzzing`)

- [ ] **Step 1: README**

In `README.md`, after the paragraph ending "…it does not stop an on-path attacker from corrupting the filesystem underneath you." and before `## Building`, add:

```markdown
A target can be **pinned to one network interface** (target editor → Network),
so its traffic stays on a dedicated storage link and never wanders onto Wi-Fi
or into a VPN's route. Strict pins fail rather than use another interface;
prefer pins fall back to macOS routing and say so in the Sessions window. It
binds the interface's own address, so it works on a direct-attached link with
no router.
```

- [ ] **Step 2: Open questions**

In `docs/open-questions.md`, before `## A note on method`, add:

```markdown
## 11. Interface pinning (0.7.0): what is unverified

Built and unit-tested; the binding mechanism was measured on the dev host
(`docs/superpowers/specs/2026-10-02-interface-pinning-design.md`). Not yet run:

- **App-level, on the VMs.** The picker, an attach pinned strict and prefer, a
  cable-pull recovery that keeps the pin, and the Sessions window's fallback
  line. Rides with the 0.7.0 RC.
- **IPv6.** A hostname that resolves only to IPv6 fails as "no route" under an
  IPv4 pin; nobody has an IPv6-only portal to try it on.
- **No migration back.** A prefer-mode session that fell back stays on its path
  until its next reconnect. Deliberate; worth revisiting only if someone
  notices a session parked on Wi-Fi.
```

- [ ] **Step 3: Test playbook**

In `docs/test-playbook.md`, before `## Fuzzing`, add:

```markdown
## Interface pinning (0.7.0)

On the dev host, which has `en0` (Wi-Fi) and `en17` (wired) on 192.168.0/24,
`en18` on the NAS's 192.168.20/24 with no default route, and Tailscale (`utun4`)
also claiming 192.168.0/24. All read-only.

    swift run iscsictl discover 192.168.20.1 --interface en18     # connected via en18, targets listed
    swift run iscsictl discover 192.168.0.1 --port 80 --interface en18   # fails at once: en18 has no route
    swift run iscsictl discover 192.168.0.1 --port 80 --interface en17   # connected via en17, then a protocol error
    swift run iscsictl discover 192.168.0.1 --port 80 --interface en0    # connected via en0, then a protocol error

The last two talk to the router's web port on purpose: what matters is the
`connected via` line, which shows two interfaces on one subnet chosen apart —
and Tailscale's route to the same subnet ignored. The protocol error after it
is the router not speaking iSCSI.
```

- [ ] **Step 4: Full verification**

```bash
swift build -Xswiftc -DISCSI_BACKEND_B 2>&1 | grep -E "error" ; echo "backend-b build done"
swift test --no-parallel 2>&1 | tee /tmp/claude-iface-test.log | grep -E "Test run with|✘"
grep -c "warning:" /tmp/claude-iface-test.log
cd apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; cd ..
cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd .. && git diff --exit-code apps/iSCSIInitiator.xcodeproj && echo "pbxproj in sync"
```

Expected: no Backend B build errors; every test run passes with no `✘`; the warning count matches `main`'s (run the same grep on a `main` checkout if it is not zero); `** BUILD SUCCEEDED **`; `pbxproj in sync`.

- [ ] **Step 5: The real network (dev host, read-only)**

Run the four commands from the playbook section in Step 3, plus:

```bash
swift run iscsictl nvme discover 192.168.20.1 --interface en18
```

Expected:
- `discover 192.168.20.1 --interface en18` → `connected via en18` and the NAS's targets.
- `--interface en18` toward `192.168.0.1:80` → fails within a second, naming `en18` and "no route to 192.168.0.1".
- `--interface en17` and `--interface en0` toward `192.168.0.1:80` → `connected via en17` and `connected via en0` respectively, each followed by an iSCSI protocol error.
- `nvme discover … --interface en18` → `connected via en18` and the subsystem list.

If any expectation fails, stop and report the output; do not adjust the expectations to fit.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/open-questions.md docs/test-playbook.md
git commit -F - <<'EOF'
Document interface pinning and its real-network checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

## Out of scope (found while planning, deliberately not fixed here)

`NetworkTransport` configures TCP through `params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options`. `internetProtocol` is the IP layer, so the cast always fails and `noDelay`, `enableKeepalive` and `keepaliveIdle` have never been applied — Nagle is on and TCP keepalive is off on every connection. Task 2 copies the block verbatim so this plan does not change throughput behaviour under the interface work. It needs its own change (`transportProtocol`) and its own measurement.
