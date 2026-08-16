# macOS iSCSI Initiator

A modern iSCSI initiator for macOS 26/27 on Apple Silicon. macOS ships no
initiator; the old open-source option is a dead kext. This project puts the
iSCSI/TCP protocol engine in a user-space Swift daemon and presents the LUN as
a real block device. The current FSKit/`hdiutil` backend in this project is a bit hacky,
but it works: you can mount LUNs as APFS, with the block device provided by Apple's
DiskImages framework. A DriverKit virtual SCSI HBA is the eventual goal once Apple lifts
some very real throughput limits (see `docs/architecture.md`).

## AI warning

The vast majority of the work here was done by Claude Code using Opus 5 and Fable 5.
It was closely supervised, but most of the architecture and discovery was by trial-and-error,
because lots of things that _should_ work, don't. Most of that is purposefully left in the repo
to act as documentation and memory. Claude also wrote most of the documentation, although I
reviewed and edited it.

## Repo/development

There are a large number of test/integration scripts that rely on my exact setup. I used
two disposable VMs on my dev machine to test ideas and iterate. One had XCode installed,
SIP disabled, extension barriers disabled, etc. This was used mostly for initial testing
and letting Claude try out ideas harmlessly. The other was as 'virgin' as possible in
order to figure out what required user prompts, whether notarization worked, etc. You'll
see plenty of references to this in the test scripts, with logins to `herko@192.168.0.x`,
and even an embedded password or two. They were all left in for documentation, reference,
and history. No secrets are actually compromised.

I also manually test the initiator on a completely different bare-metal macOS 26 machine.
It works. It's not just VMs.

Most of the work and testing is done against a LUN on my actual TrueNAS server in my
homelab. There is also a target simulator that can be, and was, used for destructive
testing.

There are some speed enhancements, but it is single-connection for simplicity and
stability. Don't expect it to be a speed demon. I achieve about 70 MB/sec against my
hardware HDD-backed RAID Z1 array, even over 10 gbps. Usable, but no records will be
broken. True optimization will need more users, more time, and to be done at a later
step in the process. It's too early for that, and things like multiple streams were
tested and discarded because they conferred zero speed benefits on my setup.

## Status

A notarized DMG, dragged to Applications, gets you an APFS volume
in Finder without ever opening Terminal. Verified end to end on 2026-08-14 on a
clean macOS 26.6.1 machine with SIP on, no Xcode, no Apple ID and no developer
account, against a real TrueNAS target: discover → add → attach → copy files →
detach → re-attach. Full transcript in `docs/acceptance-2026-08-14.md`.

226 tests pass (unit + integration + real-TCP-loopback); the PDU fuzzer runs
clean over 100 independent seeds (`scripts/fuzz-campaign.sh`). The protocol
stack is verified against real hardware, not just the simulator.

What the app does today:

- **Guides you through setting up.** For this to actually work it must satisfy
  four conditions: installed in Applications, background service running,
  filesystem extension registered, filesystem extension enabled. This is
  re-checked on every launch and every return to the foreground. The screen
  renders the results, of checks so you can easily see what steps are needed.
  It also repairs: an update that drops the extension's registration shows up
  as an ordinary unsatisfied step with a button.
- **Discover, add, attach, detach**, from a menu bar item or a window, with CHAP.
- **A diagnostics pane** showing negotiated login parameters, session recovery
  count, and the target's write-cache state — everything the daemon knew and
  had never told anyone.
- **Uninstall** that removes its own daemon, secrets, and extension registration
  in the one order that works.
- **Updates** via Sparkle, which refuse to install while a volume is attached.

### The FSKit enablement gate, and what it costs

macOS requires the user to enable a third-party filesystem extension. On
macOS 27 beta, that switch works, and the app deep-links to it. On macOS 26.x it
is present but doesn't actually move. Feedback filed with Apple, will update this
if they fix it. It was reproduced independently against Apple's own FSKitSample.
On 26.x the app asks for consent and writes the necessary entry itself, sidestepping
the bug.

Both branches are measured, on both OS versions, with a notarized build and SIP
on. `docs/backend-a-fskit-notes.md` has the evidence and
`docs/feedback-fskit-enablement-26x.md` is the Feedback report.

### There's a parked future backend.

Future work is on a different backend that uses a DriverKit extension. It was
extensively tested but it simply doesn't work, and requires Apple to fix an issue.

- **APFS wedges the block device after the first access**, and it is not an
  iSCSI problem: built with `ISCSI_DEXT_SCRATCH_DISK 1` the dext serves a RAM
  buffer from its own memory — no daemon, no network, no target — and APFS
  wedges identically, while ExFAT on the same driver is fine and APFS on an
  `hdiutil` RAM disk is fine. In other words, there's a bug somewhere in APFS'
  implementation... or in the interaction of these two things that I cannot
  figure out.
- **The DriverKit family entitlements are approval-gated**, so their presence
  makes every Developer ID export fail at profile resolution.

The reconnaissance in it is expensive and correct, so it is flagged rather than
deleted. `swift build -Xswiftc -DISCSI_BACKEND_B` turns it back on; see the
header of `scripts/vm-deploy-dext.sh` for what else re-enabling needs.

There are some other delicate issues embodied in the implementation. For example,
presenting the LUN as **removable** media makes macOS elide every flush in-kernel,
so APFS's barriers became silent no-ops. When presented as a fixed disk, flushes
reach the wire. See "The flush gap" in `docs/architecture.md`.

## Building

```sh
cd apps
xcodegen generate          # produces iSCSIInitiator.xcodeproj
open iSCSIInitiator.xcodeproj
```

Two schemes. **iSCSI Initiator** is what ships: the app, the embedded FSKit
extension, and `iscsid` inside the bundle. **iSCSIDext-dev** builds the
DriverKit extension on its own, for a SIP-off machine.

The app builds against the macOS 26 SDK. Its one macOS 27 API,
`FSClient.openFileSystemExtensionsSettings()`, is reached by selector
(`FSKitSettingsLink`) so that the app CAN build with XCode 26 and the 26 SDK.

## Releasing

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `apps/project.yml`,
then push a tag:

```sh
git tag v0.3.3 && git push origin v0.3.3
```

`.github/workflows/release.yml` archives, exports a Developer ID build,
notarizes and staples both the app and the DMG, signs it for Sparkle, creates
the GitHub release, and only then commits the appcast entry — because a feed
that names a file before the file exists is a failed download for every user who
checks in between. It ends by fetching the published feed and confirming the URL
it advertises really serves the bytes the signature covers.

The workflow holds no build logic of its own; it runs `scripts/release.sh`, the
same script that runs on a Mac:

```sh
scripts/release.sh --publish        # build, notarize, publish, write the feed
scripts/release.sh                  # stop before publishing
scripts/release.sh --skip-notarize  # for iterating on the script itself, nothing else
```

`docs/releasing.md` covers the six repository secrets, how to produce each, and
what to do when a release fails halfway.

## Testing

CI (`.github/workflows/ci.yml`) runs the package tests, the app build, and the
project-hygiene checks. The most valuable of those regenerates the Xcode project
from `apps/project.yml` and fails on any diff.

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
swift run iscsictl verify 127.0.0.1 --target iqn.2000-01.com.example:lun0 --write
printf 'crash\n' | nc 127.0.0.1 3262     # target power loss, on demand
```

See `docs/architecture.md` for the two-backend design and the DriverKit
throughput caveat, `docs/backend-a-fskit-notes.md` for how the shipping backend
actually behaves on both OS versions, `docs/daemon-registration.md` for what
SMAppService really does, `docs/resilience.md` for the fault matrix, and
`docs/test-playbook.md` for the full test strategy.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Apache rather than MIT for the patent grant in section 3. This implements a
standardised protocol, and a permissive licence that says nothing about patents
leaves users relying on the goodwill of every contributor; Apache makes the
grant explicit and terminates it for anyone who sues over it. The cost is a
longer file and a requirement to note modifications.

Bundled dependencies, both permissive and neither imposing conditions on this
code:

| | licence |
|---|---|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT |

Sparkle ships inside the app bundle, so a redistributed binary carries its
copyright notice; the framework includes its own licence file.
