# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A user-space iSCSI and NVMe/TCP initiator for macOS 26/27 on Apple Silicon.
macOS ships no initiator and the old open-source option is a dead kext, so the
iSCSI/TCP and NVMe/TCP protocol engines live in a Swift daemon and something
else turns the LUN (or namespace) into a block device. Two things follow from that split and explain most of the code:

- **DriverKit extensions cannot open sockets** (no BSD sockets, no
  Network.framework, any DriverKit SDK through 25.x). That is why there is a
  daemon at all.
- **The shipping block-device backend is FSKit + `hdiutil`**, not the driver.

## Commands

### Swift package — protocol core, daemon, CLIs

```sh
swift build
swift test                                # both test targets
swift test --filter iSCSIKitTests         # one target
swift test --filter Digest                # regex over suite and test names
swift test --filter NVMe                  # everything NVMe/TCP, unit and integration
swift test --no-parallel                  # what CI runs
```

Tests are swift-testing (`@Test` / `#expect`), not XCTest. Every target is in
Swift 6 language mode.

**CI runs `--no-parallel` deliberately.** Several tests bound real durations —
`withDeadline` asserts a 100 ms deadline has fired 2 s later, the flush-policy
tests wait on a periodic timer. Saturating a 3-core runner does not make a
timeout wrong, it makes every continuation late, and those tests failed
deterministically in CI while passing locally every time. A parallel local run
is the lenient one; if a timing test is marginal, check it serially.

Coverage, and the two shields.io badge documents the README points at:

```sh
swift test --no-parallel --enable-code-coverage 2>&1 | tee /tmp/test.log
scripts/coverage-badges.sh /tmp/test.log /tmp/badges
```

CI force-pushes that output onto the orphan `badges` branch on main pushes
only. There is no third-party coverage service and no secret to keep alive.

### The app, the FSKit extension, the dext

```sh
cd apps && xcodegen generate && open iSCSIInitiator.xcodeproj
```

`apps/project.yml` is the source of truth; `iSCSIInitiator.xcodeproj/project.pbxproj`
is **generated and committed**, and CI regenerates it and fails on any diff. So
after touching `project.yml`, run `SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate`
and commit the result. That check is the highest-value one in the repo: a
hand-patched `.pbxproj` once produced an app with no filesystem extension, from
a build that looked clean. The env var matters: without it, xcodegen orders
same-named build phases (two "Embed Dependencies" copy-files phases, one per
embed destination) by Swift's per-process-randomized `Dictionary` iteration,
so an unmodified `project.yml` can regenerate into a spuriously different
`.pbxproj` — and CI, which does set the env var, uses it as its baseline.

Two schemes. **iSCSI Initiator** is what ships (app + FSKit extension +
`iscsid` inside the bundle). **iSCSIDext-dev** builds the parked DriverKit
extension alone, for a SIP-off machine.

The app builds against the macOS 26 SDK. Its one macOS 27 API,
`FSClient.openFileSystemExtensionsSettings()`, is reached by selector in
`FSKitSettingsLink` precisely so that stays true.

### Exercising the protocol without a NAS

```sh
swift run iscsi-target-sim --port 3260 --capacity-mib 1024 &
swift run iscsictl discover 127.0.0.1
swift run iscsictl verify 127.0.0.1 --target iqn.2000-01.com.example:lun0 --write  # DESTRUCTIVE
printf 'crash\n' | nc 127.0.0.1 3262      # target power loss with a dirty cache
scripts/fuzz.sh 60                        # ASan fuzz of both PDU decoders

swift run iscsi-target-sim --nvme --capacity-mib 1024 &        # NVMe/TCP on 4420
swift run iscsictl nvme discover 127.0.0.1
swift run iscsictl nvme verify 127.0.0.1 --subsystem nqn.2026-08.me.herko.sim:disk0 --write  # DESTRUCTIVE
```

Against the NAS (TrueNAS SCALE 25.10, `nvmet` on 4420), `iscsictl nvme
discover 192.168.20.1` is read-only; `verify --write` is not. The host NQN
both commands print is what goes in the subsystem's allowed-hosts list.

### Releasing

Bump **both** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`apps/project.yml`, then tag:

```sh
git tag v0.4.1 && git push origin v0.4.1
```

That is the whole release. `.github/workflows/release.yml` holds no build logic
— it runs `scripts/release.sh`, which archives, exports a Developer ID build,
notarizes and staples app and DMG, signs for Sparkle, creates the GitHub
release, and **only then** commits the appcast entry. Never commit a locally
generated `appcast.xml`: a feed that names a file before the file exists is a
failed download for everyone who checks in between. `docs/releasing.md` covers
the six repository secrets.

`scripts/release.sh --skip-notarize` exists for iterating on that script and
nothing else. Its output must never be installed anywhere — macOS behaves
differently around notarization, so an unnotarized build does not predict the
shipping one.

## Architecture

```
iscsictl / app / FSKit extension ──XPC──► iscsid (LaunchDaemon)
                                            │ iSCSIKit: PDU codec, negotiation,
                                            │ CHAP, CRC32C, session engine
                                            │ NVMeKit: NVMe/TCP PDUs, capsules,
                                            │ controller + queue actors
                                            └─ Network.framework ──TCP──► target
LUN ──► FSKit file ──hdiutil CRawDiskImage──► /dev/diskN        (Backend A, ships)
LUN ──► shared-memory ring ──► iSCSIDext virtual SCSI HBA       (Backend B, parked)
```

- **`Sources/iSCSIKit` is transport-free and side-effect-free on purpose.** No
  sockets, no filesystem, no policy — that is what makes every path unit-testable
  and fuzzable, and what lets `MemoryPipe` stand in for TCP in tests. Keep new
  I/O out of it.
- **`Sources/NVMeKit` is the NVMe/TCP twin of iSCSIKit** under the same rules,
  depending on iSCSIKit only for the transport, CRC32C, `withDeadline`, the
  session policy and `BlockDeviceBackend`. The daemon tells the protocols
  apart by the target name's prefix — `nqn.` is NVMe — in `DaemonCore.login`
  and nowhere else; `TargetRecord.targetIQN` carries the NQN and `lun` the
  namespace ID, with **no stored discriminator** (a new non-optional key
  would make every existing `targets.json` undecodable). The host NQN is
  derived from the platform UUID in `HostIdentity`; **never change that
  derivation** — TrueNAS allowed-hosts lists key on it, exactly the way the
  initiator-name change once broke the iSCSI ACLs.
- **`iSCSIDaemon` is the daemon core as a library**; `iscsid` is a thin
  XPC/launchd launcher on top, so the interesting logic is testable.
- **`iSCSIVolume` is the FSKit extension's data path without the FSKit** —
  `LUNStore`, `BackingStore`, `DaemonStore`, and with them read-modify-write,
  the chunk cache and the `ioLock` that pins cache-patch order to device order.
  It lives in the package rather than the Xcode target so `swift test` can
  reach it; what stays in the extension is what conforms to FSKit. Keep new
  FSKit types out of this target — that separation is what makes it testable.
- **`XPCModels` cross as `Codable` DTOs encoded to `Data`**, not
  NSSecureCoding. `ISCSIError` is one error domain, and sense bytes plus
  recovery text survive the XPC boundary intact.
- **`MountpointTag` is `sha256(portal|target|lun)` and is a compatibility
  contract** — changing how it is derived orphans every existing mount.
- **CHAP secrets live in the System keychain, and must.** The data-protection
  keychain (`kSecUseDataProtectionKeychain`) is served by `secd`, a per-user
  agent; `iscsid` is a system-domain LaunchDaemon with no such service in its
  bootstrap namespace, so every call returns `-25291` and no secret was ever
  stored. Naming a file keychain costs one deprecation warning on
  `SecKeychainOpen`, which is deliberate — see `KeychainStore.swift`.
- **Mutual CHAP is implemented but switched off** at `CHAP.mutualIsOffered`.
  The blocker is target-side; `docs/open-questions.md` item 3a has the evidence.
- **The attach path is unprivileged and lives in the app, not the daemon.**
  `mount -F` resolves the FSKit module through the user's `fskit_agent`; a root
  daemon's lookup goes to `fskitd`, which holds no third-party modules.
- **Writes default to Force Unit Access.** FSKit delivers no barrier signal, and
  an acknowledged write in a volatile target cache is a lie APFS acts on. Per
  target this can be relaxed to a 1–60 s timer or never; the interval bounds how
  stale the disk can be after a target power cut, not whether it survives intact.
- **Backend B is behind `ISCSI_BACKEND_B` and ships in nothing.**
  `swift build -Xswiftc -DISCSI_BACKEND_B` turns it back on. It is parked on two
  Apple-side blockers: an APFS wedge that reproduces with iSCSI removed
  entirely, and approval-gated DriverKit family entitlements that make every
  Developer ID export fail. It is kept because the reconnaissance is expensive
  and correct — treat everything in `docs/architecture.md` about it as findings,
  not as current behaviour.

## Invariants CI enforces, and why

Beyond the xcodegen drift check, `.github/workflows/ci.yml` asserts things that
are silent at build time and expensive at runtime:

- **Exactly one `me.herko.iSCSIInitiator.daemon.plist` in the tree.**
  SMAppService resolves a daemon by plist *filename*, so a second copy is not
  redundancy — it is an ambiguity that surfaces as "approved but nothing happens".
- **The plist's `Label` equals its filename minus `.plist`, and it uses
  `BundleProgram`.** A mismatched Label registers a service that can never be
  looked up again, including by `unregister()`, leaving the user a root daemon
  they cannot remove.
- **Every `.plist` in the repo parses.**

## Testing on real machines

Two VMs, and which one answers a question matters (`docs/vm-setup.md`):

- **SIP on, no Xcode, no Apple ID** — the end-user acceptance rig. The only
  place that can answer anything about consent, entitlements or Gatekeeper.
  Keep it clean.
- **SIP off** — the fast loop for the daemon, XPC and the setup machine's own
  logic. It cannot answer consent questions (self-asserted entitlements pass
  there) and its FSKit view is not trustworthy.

Nothing gets installed or registered on the development host itself.

Logs, by subsystem — `me.herko.iSCSIInitiator` (daemon),
`me.herko.iSCSIInitiator.app`, `me.herko.iSCSIInitiator.fsext`:

```sh
/usr/bin/log stream --info --debug --predicate 'subsystem BEGINSWITH "me.herko.iSCSIInitiator"'
```

Use `/usr/bin/log` explicitly; `log` is often a shell function in this
environment. `--info --debug` is what surfaces these, not `--level`.

## Where the knowledge lives

The docs are the memory of what was tried and what it cost; several record
retracted conclusions on purpose. Read before planning:

- `docs/open-questions.md` — the live list of what is untested, unexplained, or
  deferred, ordered by what a failure would cost. Start here.
- `docs/architecture.md` — the two backends, the storage-stack contract lessons,
  the flush gap, the APFS wedge investigation.
- `docs/backend-a-fskit-notes.md` — how the shipping backend behaves on both OS
  versions, including the macOS 26.x FSKit enablement-switch bug and the
  consented workaround.
- `docs/daemon-registration.md`, `docs/resilience.md`, `docs/performance.md`,
  `docs/test-playbook.md`, `docs/releasing.md`.
