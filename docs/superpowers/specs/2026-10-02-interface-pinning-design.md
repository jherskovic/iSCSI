# Interface pinning — design

0.7.0, feature 2 of 3. Approved in conversation 2026-10-02.

## Goal

Let the user force a target's connections onto a chosen network interface
instead of whatever macOS routing picks. General-purpose: all three of these
are in scope —

- two paths to the same NAS (Wi-Fi and wired on one subnet) and macOS uses the
  slower one;
- a dedicated storage link (separate subnet or direct cable) that must carry the
  traffic;
- a VPN or tunnel (Tailscale, WireGuard, corporate) whose routes capture the
  NAS's address.

The choice is **per target**, and the behaviour when the interface is
unavailable is **the user's per-target choice**: strict (fail) or prefer (fall
back to macOS routing).

## Mechanism — measured, not assumed

Two throwaway probes on the dev host (2026-10-02), which has `en0` (Wi-Fi,
192.168.0.22) and `en17` (wired, 192.168.0.251) on one subnet, `en18`
(192.168.20.2) on a storage /24 with **no default route**, and Tailscale
(`utun4`) also claiming 192.168.0/24:

| What | Result |
|---|---|
| `NWPathMonitor`, generic and every per-type variant | lists `en0`, `en17`, `utun4`, `lo0`; **never `en18`** |
| `requiredLocalEndpoint` = `en17`'s address → router | connects via `en17` |
| `requiredLocalEndpoint` = `en0`'s address → router | connects via `en0` (Wi-Fi), same subnet |
| `requiredLocalEndpoint` = `en18`'s address → NAS :3260 | connects via `en18` |
| `requiredLocalEndpoint` = `en18`'s address → router (no route on `en18`) | `.waiting(ENETDOWN)` at once, never leaks to `en17`, never `.failed` |
| `requiredInterface` = `lo0` → 127.0.0.1 | connects |
| `requiredInterface` = `en0` → 127.0.0.1 | `.waiting(ENETDOWN)`, never `.failed` |

Consequences:

- **`requiredInterface` is unusable here.** `NWInterface` has no public
  initializer and only comes off an `NWPath`; the path monitor omits route-less
  interfaces, which is exactly the dedicated-storage-link case.
- **Binding the local address pins the interface.** macOS scoped routing ties a
  socket bound to an interface's address to that interface's routes — including
  for a route-less interface, and without leaking when that interface has no
  route to the destination.
- **A pinned connection with no route waits forever.** `NetworkTransport.start`
  today resolves only on `.ready` / `.failed` / `.cancelled`, so it would burn
  the whole 10 s connect deadline. While pinned, `.waiting` is a failure.

## Data model

`TargetRecord` gains two optional keys (a non-optional key would make every
existing `targets.json` undecodable):

```swift
/// BSD name of the interface this target's connections must use ("en18").
/// nil: macOS routing chooses, as before 0.7.0.
public var networkInterface: String?
/// When `networkInterface` is unavailable: nil/false fails the connection
/// (strict), true falls back to macOS routing (prefer).
public var interfaceFallback: Bool?
```

`interfaceFallback` is ignored when `networkInterface` is nil. An empty-string
`networkInterface` (hand-edited file) is treated as nil.

The BSD name is the identity. macOS persists BSD names per adapter
(`NetworkInterfaces.plist`), so it survives reboots and re-plugging the same
adapter; a different adapter gets a different name, and the target then shows
its stored name as "not present" until the user re-picks.

## Binding policy (pure, in iSCSIKit)

```swift
public struct InterfaceBinding: Sendable, Equatable {
    public var name: String        // BSD name
    public var fallback: Bool      // prefer (true) vs strict (false)
}
```

`TargetRecord` → `InterfaceBinding?` (nil when `networkInterface` is nil/empty).

At every connect attempt — the initial login, every recovery reconnect, both
NVMe queues — the transport, inside **one** connect deadline shared by every
step below:

1. Resolves the target name the ordinary, unscoped way (`getaddrinfo`, off the
   concurrency pool). A bound connection resolves names through the bound
   interface alone, and a storage link usually has no resolver — so a pinned
   hostname could otherwise never connect (review finding I1, reproduced
   against the NAS). A name that does not resolve fails both modes: an
   unbound connect would fail the same way.
2. Picks the endpoints from the interface's current addresses (`getifaddrs`,
   not cached: DHCP and re-plugged cables change it): the first target
   address, IPv4 before IPv6, whose family the interface holds a usable
   address in. Link-local addresses (169.254/16, fe80::/10) do not count — an
   interface holding only a self-assigned address has lost its network.
3. If there is no usable address (interface absent, down, or address-less):
   strict → re-check every 250 ms until the deadline, then throw
   `TransportError.interfaceUnavailable(name:, reason:)`; prefer → connect
   unbound at once and record the fallback. Strict waits because failing
   instantly ran recovery's whole budget out in ~16 s, against ~65 s for an
   unpinned session whose link is pulled — so a re-seated cable that heals an
   unpinned session would have unmounted a pinned one (review finding M1).
4. Otherwise binds `requiredLocalEndpoint = .hostPort(local, .any)` and
   connects to the resolved target address. While bound, a `.waiting` whose
   reason is a route failure (EADDRNOTAVAIL, ENETDOWN, ENETUNREACH,
   EHOSTUNREACH) ends the attempt at once with
   `interfaceUnavailable(name:, reason: "no route to <host>")`; prefer then
   retries unbound, strict throws. Any other `.waiting` — a refusal above all —
   is the target's answer and runs the deadline exactly as unbound does
   (review finding I2: reporting a refusal as "no route" blamed the cable).

Prefer falls back **only on these fast signals** (no address, no route). An
interface that is up and routed but whose SYNs go unanswered is a target
failure in both modes and runs out the normal connect deadline once, not
twice — doubling each recovery attempt's connect time would worsen the race
with the extension's 30 s call timeout recorded in `docs/open-questions.md`
§8a.

No migration: a session that fell back stays on its path until its next
reconnect, when the pinned interface is tried first again.

The ordering decision (resolve → bound attempt → maybe unbound attempt) is a
pure function over an injected "attempt" closure, so every branch is
unit-testable without a network. `NetworkTransport.connect(host:port:binding:)`
supplies the real attempt.

## Daemon plumbing

- `DaemonCore.transportFactory`: `(host, port)` →
  `(host, port, InterfaceBinding?)`. Every reconnect already goes through it,
  so recovery and both NVMe queues inherit the binding with no further change.
- `DaemonCore.login` takes the binding; `XPCService.login` and
  `XPCService.testConnection` pass the record's — `testConnection` already
  resolves the saved record for CHAP "deliberately", so it resolves the binding
  the same way and validates what `login` will actually run.
- `discoverTargets` and `discoverSubsystems` run before any record exists, so
  they take the binding explicitly: two new parameters,
  `interfaceName: String?, interfaceFallback: Bool`. App/daemon skew is already
  surfaced by `DaemonController`'s version-mismatch state.
- Each session keeps the outcome of its most recent connect — interface used,
  whether it fell back — updated on every reconnect.

## Visibility

- Every connect logs one line: the interface actually used (from the
  connection's `currentPath`), and for a bound target whether it fell back and
  why. Daemon subsystem, `session` category (`DaemonLog.session`).
- `SessionInfo` gains `interfaceName: String?` and `interfaceFallbackFrom:
  String?` — the pinned name a fallback left, nil when none — both optional so
  the DTO stays decodable across skew. (A Bool, as first drafted, could not
  say *which* interface was left.) The Sessions window shows
  "via en18", or "via en0 (fallback from en18)".

Without this, prefer mode is indistinguishable from pinning silently not
working.

## App

- **Target editor (`TargetsView`) and discovery sheet (`DiscoveryView`)** each
  get an interface picker. Discovery is where targets are born, so its choice
  carries into the record it creates.
- Picker entries: "Automatic (macOS chooses)" first and default; then every
  interface with a usable address, labelled from `SCNetworkInterfaceCopyAll`'s
  localized name plus BSD name and current address — e.g.
  "USB 10GbE (en18) — 192.168.20.2". The app is not sandboxed, so it enumerates
  itself; no daemon call.
- A stored interface that is not present stays in the list as
  "en18 — not present" and stays selected. Editing a target must never silently
  drop its pin.
- A Strict / Prefer control appears when an interface other than Automatic is
  selected; Strict is the default. One line of help text per mode.

## iscsictl

`--interface NAME` on every command that opens a connection — they all reach
the network through the two shared connect helpers in `ISCSICtl.swift` and
`NVMeCommands.swift`, so the flag is added once per protocol. Strict only: it is a test tool, and
a fallback would hide the thing being tested.

## Error handling

- Strict, unavailable: `ISCSIError` with recovery text naming the interface and
  the reason ("en18 has no address", "en18 has no route to 192.168.0.1"), so the
  UI and `iscsictl` print something actionable.
- During recovery, an unavailable strict interface is an ordinary failed
  reconnect attempt: recovery's existing retry budget applies, so a cable
  re-seated within it heals the session; past it, the existing latch applies.

## Testing

Unit (swift-testing, no network):

- Binding policy over an injected attempt: strict + absent → throws
  `interfaceUnavailable` naming the interface, no unbound attempt made; prefer +
  absent → exactly one unbound attempt, outcome marked fell-back; strict + bound
  attempt reports no-route → throws, no unbound attempt; prefer + no-route → one
  unbound attempt; bound attempt times out → error propagates in both modes, no
  unbound attempt (the fast-signals-only rule).
- Address selection from a fixture `getifaddrs`-shaped list: IPv4 preferred,
  IPv6 for an IPv6-literal host, link-local ignored, name not found.
- A pre-0.7.0 `targets.json` fixture decodes with both fields nil; a record
  round-trips with both set.
- Daemon: with a spy factory, `login` and `testConnection` pass the record's
  binding; `discoverTargets`/`discoverSubsystems` pass their parameters; a
  recovery reconnect passes the same binding again.

Integration (real Network.framework, loopback):

- Bound to `lo0` → connects; the reported interface is `lo0`.
- Bound to a name that does not exist → strict fails fast (well under the 10 s
  connect deadline); prefer connects unbound and reports the fallback.

Real network (dev host, `swift run iscsictl` — a CLI run, nothing installed or
registered; discovery is read-only):

- `discover 192.168.20.1 --interface en18` succeeds.
- `--interface en18` toward a 192.168.0.x address fails fast, naming `en18` and
  the missing route — `en18` has no default route. (`--interface en0` toward
  192.168.20.1 would *not* fail fast: `en0` has its own scoped default route,
  so the SYN goes to the gateway and times out — the "routed but unanswered"
  case, which correctly does not fall back.)
- Against a 192.168.0.x portal, `--interface en17` and `--interface en0` each
  egress the named link despite `utun4` claiming the subnet — confirmed by the
  logged interface and the interface byte counters.

App-level (picker, Sessions window, an attach that survives a recovery with
the binding intact) rides with the 0.7.0 RC on the VMs, alongside the ramp
check.

## Out of scope

- Interface *type* choices ("any wired"): cannot choose between two wired
  links.
- BSD sockets with `IP_BOUND_IF`: would replace the Network.framework transport.
- Moving a fallen-back session back onto the pinned interface while it is
  healthy.
- A per-server (host-keyed) setting.
