# macOS iSCSI Initiator

A modern iSCSI initiator for macOS 26/27 on Apple Silicon. macOS ships no
initiator; the old open-source option is a dead kext. This project puts the
iSCSI/TCP protocol engine in a user-space Swift daemon and presents the LUN as
a real block device. The current FSKit/`hdiutil` backend in this project is a bit hacky,
but it works: you can mount LUNs as APFS, with the block device provided by Apple's
DiskImages framework. A DriverKit virtual SCSI HBA is the eventual goal once Apple lifts
some very real throughput limits (see `docs/architecture.md`).

## Status

**It ships.** A notarized DMG, dragged to Applications, gets you an APFS volume
in Finder without ever opening Terminal. Verified end to end on 2026-08-14 on a
clean macOS 26.6.1 machine with SIP on, no Xcode, no Apple ID and no developer
account, against a real TrueNAS target: discover → add → attach → copy files →
detach → re-attach. Full transcript in `docs/acceptance-2026-08-14.md`.

226 tests pass (unit + integration + real-TCP-loopback); the PDU fuzzer runs
clean over 100 independent seeds (`scripts/fuzz-campaign.sh`). The protocol
stack is verified against real hardware, not just the simulator.

What the app does today:

- **Setup that checks rather than instructs.** Four conditions — installed in
  Applications, background service running, filesystem extension registered,
  filesystem extension enabled — re-checked on every launch and every return to
  the foreground. The screen renders results, never a numbered list, so it can
  say which half of a half-finished install failed. It also repairs: an update
  that drops the extension's registration shows up as an ordinary unsatisfied
  step with a button.
- **Discover, add, attach, detach**, from a menu bar item or a window, with CHAP.
- **A diagnostics pane** showing negotiated login parameters, session recovery
  count, and the target's write-cache state — everything the daemon knew and
  had never told anyone.
- **Uninstall** that removes its own daemon, secrets, and extension registration
  in the one order that works.
- **Updates** via Sparkle, which refuse to install while a volume is attached.

### The FSKit enablement gate, and what it costs

macOS requires the user to enable a third-party filesystem extension. On
**macOS 27 that switch works** and the app deep-links to it. On **macOS 26.x it
is present but refuses to move** — reproduced independently against Apple's own
FSKitSample — and the URL that would open the pane does not navigate either. So
on 26.x the app asks for consent itself and writes the entry, then has the
daemon signal `fskitd`. No reboot, no Full Disk Access.

Both branches are measured, on both OS versions, with a notarized build and SIP
on. `docs/backend-a-fskit-notes.md` has the evidence and
`docs/feedback-fskit-enablement-26x.md` is the Feedback report.

### Backend B (DriverKit) is parked

All dext code sits behind the `ISCSI_BACKEND_B` compile flag and is in nothing
that ships. It is blocked on two things that are not ours to fix:

- **APFS wedges the block device after the first access**, and it is not an
  iSCSI problem: built with `ISCSI_DEXT_SCRATCH_DISK 1` the dext serves a RAM
  buffer from its own memory — no daemon, no network, no target — and APFS
  wedges identically, while ExFAT on the same driver is fine and APFS on an
  `hdiutil` RAM disk is fine. `scripts/vm-scratch-apfs.sh` reproduces it and
  `docs/feedback-virtual-scsi-wedge.md` is the Feedback draft.
- **The DriverKit family entitlements are approval-gated**, so their presence
  makes every Developer ID export fail at profile resolution.

The reconnaissance in it is expensive and correct, so it is flagged rather than
deleted. `swift build -Xswiftc -DISCSI_BACKEND_B` turns it back on; see the
header of `scripts/vm-deploy-dext.sh` for what else re-enabling needs.

One earlier blocker *was* ours and is fixed: presenting the LUN as **removable**
media makes macOS record `WriteCacheState = No` and elide every flush in-kernel,
so APFS's barriers became silent no-ops. Presented as a fixed disk, flushes
reach the wire. See "The flush gap" in `docs/architecture.md`.

## Building

```sh
cd apps
xcodegen generate          # produces iSCSIInitiator.xcodeproj
open iSCSIInitiator.xcodeproj
```

Two schemes. **iSCSI Initiator** is what ships: the app, the embedded FSKit
extension, and `iscsid` inside the bundle. **iSCSIDext-dev** builds the
DriverKit extension on its own, for a SIP-off VM.

The app builds against the macOS 26 SDK. Its one macOS 27 API,
`FSClient.openFileSystemExtensionsSettings()`, is reached by selector
(`FSKitSettingsLink`) precisely so that CI can build the app at all — before
that it compiled only on a machine with an Xcode beta.

## Releasing

```sh
scripts/release.sh                  # notarized, stapled DMG + signed appcast entry
scripts/release.sh --skip-notarize  # for iterating on the script itself, nothing else
```

The script archives, exports a Developer ID build, and then asserts the things
that fail silently: every nested Mach-O carries hardened runtime and a secure
timestamp, the FSKit extension and `iscsid` are present, every bundle reports
the same version, the shipped daemon has no DEBUG authorization bypass, there is
exactly one LaunchDaemon plist whose `Label` matches its filename, and the app
*inside the DMG* is stapled — not just the copy in `build/export`. It notarizes
and staples the app and the DMG separately, signs the DMG for Sparkle **after**
stapling, and writes the release into `appcast.xml`.

Publishing is printed, not performed: it is what makes an artifact visible to
everyone already running the app. The printed order matters — create the GitHub
release first, then commit the feed, because the feed points at the release
asset.

One-time setup is a notarytool credential profile and a Sparkle key pair
(`scripts/sparkle-generate-keys.sh`); the script names the exact command when
either is missing.

## Testing

CI (`.github/workflows/ci.yml`) runs the package tests, the app build, and the
project-hygiene checks. The most valuable of those regenerates the Xcode project
from `apps/project.yml` and fails on any diff — the `.pbxproj` once carried a
hand-patched embed phase that `project.yml` did not declare, so `xcodegen
generate` silently produced an app with **no filesystem module** and no build
error.

Two VMs, and which one answers a question matters:

- **SIP on, no Xcode, no Apple ID** — the end-user acceptance rig. The only
  place that can answer anything about consent, entitlements or Gatekeeper.
- **SIP off** — the fast loop for the daemon, XPC, and the setup machine's own
  logic. It cannot answer consent questions, because self-asserted entitlements
  pass there, and its FSKit view is not trustworthy (see the note in
  `docs/backend-a-fskit-notes.md`).

## Layout

```
Sources/
  iSCSIKit/          protocol core — no policy, fully testable
    PDU/             all PDU types, framer with digest verification
    Negotiation/     text-key negotiation, login state machine
    Auth/            CHAP (forward + mutual)
    Digest/          CRC32C
    Session/         ISCSIConnection + ISCSISession (recovery, keepalive)
    Transport/       ConnectionTransport, NetworkTransport (TCP), MemoryPipe
    SCSI/            SCSITask, CDB builders, sense parsing
    XPCProtocol      the daemon's surface, shared by app, extension and daemon
    XPCModels        Codable DTOs that cross as Data, not NSSecureCoding
    ISCSIError       one error domain; sense bytes and recovery text survive XPC
    MountpointTag    sha256(portal|target|lun) — a compatibility contract
  MockTarget/        scriptable target: protocol engine, volatile write cache,
                     TCP listener (drives both the tests and the simulator)
  iscsi-target-sim/  standalone local target + loopback control socket
  iscsictl/          control CLI (discover, verify, read-bench, write-bench)
  iscsid/            daemon: owns sessions, vends block I/O over XPC
  iSCSIDaemon/       daemon core, target store, keychain, XPC authorization
  pdu-fuzz/          structure-aware fuzzer
apps/
  iSCSIApp/          the app: setup machine, menu bar, windows, attach path
  iSCSIFSExtension/  FSKit module presenting the LUN as a file
  iSCSIDext/         DriverKit virtual SCSI HBA (parked, ISCSI_BACKEND_B)
Tests/
  iSCSIKitTests/     132 tests
  IntegrationTests/  94 tests: happy paths, hostile scripts, recovery, TCP
                     loopback, crash consistency, stalled-target resilience,
                     XPC authorization, handle scoping, target persistence
scripts/
  release.sh         notarized DMG + Sparkle signature + appcast
  iscsi-attach.sh    the bash-era attach path, superseded by the app
  bench.py           large-sequential throughput benchmark
  soak.py            small-file / read-modify-write soak
  crash-consistency.py  power-cut durability check
  vm-*.sh            VM deployment, fault matrix, and reproducers
  fuzz-campaign.sh   N-seed fuzzing campaign
docs/                architecture, measurements, and the two Feedback drafts
```

## Try it

```bash
swift test                          # unit + integration suite
scripts/fuzz.sh 60                  # 60s ASan fuzz of the PDU decoder

# Against a real target (e.g. your NAS):
swift run iscsictl discover 192.168.1.50
swift run iscsictl verify 192.168.1.50 --target iqn.2000-01.com.example:disk0 \
    --lun 0 --write        # DESTRUCTIVE — scratch LUN only
```

Or against the local simulator, which needs no NAS and can be broken on
purpose (drop connections, corrupt payloads, stall commands, cut the target's
power with a volatile write cache):

```bash
swift run iscsi-target-sim --port 3260 --capacity-mib 1024 &
swift run iscsictl verify 127.0.0.1 --target iqn.2026-08.me.herko.sim:lun0 --write
printf 'crash\n' | nc 127.0.0.1 3262     # target power loss, on demand
```

See `docs/architecture.md` for the two-backend design and the DriverKit
throughput caveat, `docs/backend-a-fskit-notes.md` for how the shipping backend
actually behaves on both OS versions, `docs/daemon-registration.md` for what
SMAppService really does, `docs/resilience.md` for the fault matrix, and
`docs/test-playbook.md` for the full test strategy.
