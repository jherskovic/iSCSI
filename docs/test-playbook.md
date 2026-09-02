# Test playbook

Four layers, from pure logic up to a mounted disk under fault injection.

## Layer 1 — unit (`iSCSIKitTests` and `NVMeKitTests`, runs anywhere)

- PDU golden byte vectors + encode/decode round-trips for every PDU type.
- Framing: byte-at-a-time feed, multi-PDU chunks, digest round-trips, header
  and data digest **corruption detection**, oversized-segment rejection, AHS
  passthrough, padding.
- CRC32C against RFC 7143 test vectors.
- Negotiation matrix: ImmediateData×InitialR2T (all four), MRDSL asymmetry,
  burst-length boundaries (incl. FirstBurst>MaxBurst rejection), digest
  selection, ERL negotiate-down, absent-key defaults, Reject/NotUnderstood.
- CHAP forward + mutual, hex/base64/decimal codecs, vectors vs Python hashlib.
- Login state machine: None + CHAP happy paths, redirect, reject status,
  StatSN regression, C-bit continuation both directions, TSIH rules.
- Serial (RFC 1982) arithmetic incl. wraparound.

Run: `swift test --filter iSCSIKitTests`

## Layer 2 — protocol integration vs scriptable MockTarget (43 tests)

The `MockTarget` speaks real iSCSI over `MemoryPipe` (in-memory) or a real TCP
socket (`MockTargetServer`), with 20+ switchable faults.

- **Happy paths**: login/inquiry/logout, read/write round-trips, large writes
  exercising immediate+unsolicited+R2T bursts, solicited-only path, digests on,
  READ CAPACITY, SYNCHRONIZE CACHE, NOP ping + target-initiated ping echo,
  CHAP + mutual CHAP, discovery (incl. C-bit continuation), concurrent tasks.
- **Hostile scripts**: login reject/redirect/wrong-target; StatSN jump and
  duplicate; Data/Header digest corruption (caught → connection dies, *never*
  returns corrupt bytes) with a control test showing why digests matter;
  unexpected R2T on read; oversized Data-In; Reject-per-task; CHECK CONDITION
  with sense; command stall + auto-abort on cancel; LUN RESET; write stall
  after R2T; frozen command window; mid-read drop; abrupt drop fails all
  in-flight ops (no hangs).
- **Session recovery (ERL0)**: recover after target drop, data survives target
  reboot, recovery exhaustion surfaces, keepalive detects a dead-but-connected
  peer, logout stops recovery, CHAP re-runs on recovery, bounded retry.

  No longer MockTarget-only: on 2026-08-17 a real connection to the NAS dropped
  mid-soak (`POSIXErrorCode 60`) and recovery reconnected in ~12 s over two
  attempts, unprompted. It also exposed that the extension's fixed 30 s call
  timeout is unaware of recovery and gave up 330 ms before it succeeded, failing
  the caller's I/O for a session that was about to be fine — item 8a in
  `docs/open-questions.md`.
- **Real TCP loopback**: login/write/flush/read/verify with CRC32C over an
  actual socket; discovery; session recovery — validates `NetworkTransport`.

Run: `swift test --filter IntegrationTests`

## Layer 3 — end-to-end on real hardware (needs a NAS; Phase 4+)

- `iscsictl discover <nas>` then `iscsictl verify <nas> --target <iqn> --write`
  against a **scratch LUN** for an on-the-wire login + read/write/verify.
- Capture with Wireshark's iSCSI dissector; assert clean dissection and that
  APFS barriers become SYNCHRONIZE CACHE / FUA on the wire.
- `fio --verify=crc32c` across block sizes and queue depths once a block device
  is mounted (Backend A / B).
- Fault injection with `dnctl`/`pfctl` on port 3260 (latency, loss, black-hole
  then heal) under sustained load — see `scripts/fault-inject.sh` (Phase 7).
- Crash consistency: cut transport mid-write, reconnect, `diskutil
  verifyVolume` / `fsck_apfs -n`.

## Layer 4 — soak / performance (Phase 7)

Multi-hour `fio` soak with periodic fault injection; track daemon RSS (leaks),
dext health, latency percentiles; lifecycle churn (login/logout, dext
activate/teardown cycles).

Two scripts carry this today, and they answer different questions:

- `scripts/readahead-soak.py <lun0.img> --seconds N --block-kib {256,1024}` —
  every read verified against a per-(block, generation) pattern, with writes and
  seeks interleaved so invalidation and coherence are under test rather than
  assumed. Destructive: it writes at 12–14 GiB of the LUN, so point it at a
  scratch target. `--block-kib 1024` is the only way to exercise multi-command
  splitting against hardware that completes out of order.
- A pure sequential read pass (read-only, `F_NOCACHE`) — the soak is ~21% writes
  and ~17% seeks, which pins the readahead depth controller near its floor, so
  it can never exercise deep speculation. Only an unbroken stream drives the cap
  to its ceiling.

**Read the extension's counters, not just the script's output.** `cap=` and
`settled=Nused/Mwasted` in the CLOSE summary are what make the depth controller
observable; a soak that never moves `cap` is not testing it. Query with
`/usr/bin/log show --predicate 'subsystem == "me.herko.iSCSIInitiator.fsext"'
--info --debug` — spelled absolutely, because a `log` shell function shadows it
and returns nothing at all.

**One run per setting measures the array, not the setting.** Throughput on this
target moved 2.4x day over day and 48% within a morning at fixed settings.
Interleave (A/B/A/B in one session) before believing any MB/s comparison.

## The same again, over NVMe/TCP (2026-09-01)

Layer 1 has `NVMeKitTests`: framing (data at PDO, digests, PLEN bound), every
PDU round trip with golden bytes, SQE/SGL/CQE layouts, every command builder,
Identify Controller/Namespace geometry rules, the active namespace list and
the discovery log page, and the host identity derivation.

Layer 2 mirrors the iSCSI suites one for one against `MockNVMeSubsystem`
over `MemoryPipe` (`NVMeHarness.swift`; a fresh pipe per connection, because
a controller is two of them): `NVMeHappyPathTests`, `NVMeCrashConsistency-
Tests` (all five arms), `NVMeRecoveryTests` (I/O-queue drop, admin-queue
drop, target reboot, exhaustion, a mute peer caught by Keep Alive, logout),
`NVMeWriteConcurrencyTests`, `NVMeHostileTests` (PFV/CPDA refusal, TermReq,
unknown CID, C2HData and R2T overruns, digest-caught corruption and its
negative control), `NVMeLoopbackTCPTests` over a real socket, and
`NVMeDaemonTests` for the daemon serving both protocols from one registry
and the XPC surface over an NVMe record.

Layer 3: `swift run iscsictl nvme discover <nas>` then `nvme verify
--subsystem <nqn> --nsid 1 [--write]` — read-only without `--write`. The
simulator is `iscsi-target-sim --nvme`; the control socket and `crash` are
shared, so the FUA proof is the same command as for iSCSI. The whole app
path without the GUI is `scripts/vm-nvme-verify.sh` on the SIP-off VM: the
NAS namespace through `mount -F`/`hdiutil`/APFS, then both crash arms
against the simulator (first run 2026-09-01, all as expected).

One deploy gotcha it depends on: replacing the app bundle in place (rsync
over `/Applications/iSCSI Initiator.app`) keeps the `pluginkit` row, but
`mount -F` then fails with "Unable to invoke task" and fskitd logs "No
extension with fsShortName found" — the row still names the old appex's
UUID. `pluginkit -a <appex>`, `pluginkit -e use -i me.herko.iSCSIInitiator.fsext`,
then `sudo killall fskitd` brings it back without a reboot.

## Fuzzing

`scripts/fuzz.sh [seconds]` builds `pdu-fuzz` with AddressSanitizer and runs a
deterministic structure-aware mutation engine over the PDU decoder, login
parser, and text codec. Any crash reproduces from `pdu-fuzz derive <seed>
<iteration>`. Millions of inputs clean to date.

## Fuzzing campaigns (2026-08-13)

`scripts/fuzz-campaign.sh N seconds first-seed` runs N independent seeds under
AddressSanitizer. Independent seeds rather than one long run so that any
failure reproduces exactly via `pdu-fuzz derive <seed> <iteration>`.

| campaign | seeds | coverage | result |
|---|---|---|---|
| 1 | 1–100, 20 s each | PDU deframing (digest on/off), `AnyPDU` decode→encode, `TextParameters` | **0 failures** in 2007 s |
| 2 | 101–200, 20 s each | the above **plus** `ModeSense.writeCacheEnabled` and `SenseData` | **0 failures** in 2007 s |

The second campaign exists because the first built its binary before the new
target-facing parsers were added to the fuzz body — so campaign 1 never
executed them. Worth remembering: `fuzz-campaign.sh` builds once at the start,
so a fuzz target added mid-run is not covered by that run.

**No bugs were found by fuzzing.** The bounds hardening in `ModeSense` came
from reading the code, not from the fuzzer: a block-descriptor length past the
end of the buffer, and a zero-length mode page that would never advance the
cursor. Both are now rejected, and both are unit-tested.

This matters when judging what the clean result is worth. The engine is a
deterministic mutator with no coverage feedback, so a clean run means "no crash
on these inputs", not "no reachable crash". The parsers that matter most are
also covered by targeted unit tests over malformed input, which is the stronger
guarantee of the two.

Why parsing bugs here are crashes rather than wrong answers: `Data`'s accessors
in `Support/Endian.swift` are slice-tolerant but **not** bounds-checked —
`self[startIndex + offset]` traps. Any target-controlled parsing must prove its
offsets in bounds before reading.

## The update-postpone rule (manual, and awkward on purpose)

Replacing the bundle while a LUN is attached pulls the FSKit extension out from
under a live filesystem. `UpdateController` refuses to let that happen, and
`SPUInstallerDriver.installWithToolAndRelaunch:` calls the postpone hook before
it opens a connection to the installer — so returning `true` there stops the
installation, not merely the relaunch. That is the property under test.

The awkward part: **the postpone logic that runs is the one in the installed
version, not the one in the update.** A fix to this path can never be exercised
by shipping it; it takes the release *after*. So test it against a local feed.

1. Install the build under test on the acceptance VM, notarized as always.
2. Serve a doctored feed **on the VM itself, over loopback**. The app's
   Info.plist declares no App Transport Security exceptions, so plaintext HTTP
   to another machine on the LAN is refused inside the app with a network error
   that says nothing about ATS. `localhost` is exempt from that; a second Mac is
   not.

   Reuse a real, already-signed DMG — the enclosure has to survive signature
   checking, and the version comparison is read from the feed, so an existing
   DMG advertised under a higher build number gets Sparkle all the way to
   "Install and Relaunch":

   ```sh
   # on the VM, after scp'ing the DMG and appcast.xml over
   mkdir -p ~/feed && cp iSCSI-Initiator-0.3.2.dmg appcast.xml ~/feed/
   # edit ~/feed/appcast.xml: bump sparkle:version well past the installed
   # build, point the enclosure url at
   # http://localhost:8000/iSCSI-Initiator-0.3.2.dmg,
   # leave length and edSignature exactly as they are
   (cd ~/feed && python3 -m http.server 8000)
   ```

3. Redirect the feed without rebuilding — Sparkle reads this key from user
   defaults ahead of the Info.plist:

   ```sh
   defaults write me.herko.iSCSIInitiator SUFeedURL "http://localhost:8000/appcast.xml"
   ```

   Confirm it took effect before concluding anything: Sparkle 2 deprecated
   app-set feed URLs and has tightened where a feed may come from more than
   once, and this has not been checked against 2.9.5. If Check for Updates goes
   to GitHub anyway, edit `SUFeedURL` in `apps/iSCSIApp/Info.plist` and cut a
   throwaway build instead — slower, but it cannot be ignored.

4. Attach a LUN. Then Check for Updates → Install and Relaunch.

   Expected: an alert naming the attached volume, saying the update will install
   and relaunch once it is detached, offering **Detach and Install** and
   **Later**. Nothing is installed; the app does not quit.

5. Click Later, then eject the volume **in Finder** rather than using Detach.
   The update must install and the app relaunch anyway. This is the path that
   does not go through `AppModel.detach`, and it stayed broken for a while
   because the only release hook lived there.

6. `defaults delete me.herko.iSCSIInitiator SUFeedURL` when finished, or the VM
   keeps checking a web server that no longer exists.
