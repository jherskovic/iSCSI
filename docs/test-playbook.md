# Test playbook

Four layers, from pure logic up to a mounted disk under fault injection.

## Layer 1 — unit (`iSCSIKitTests`, 86 tests, runs anywhere)

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
2. Serve a doctored feed. Reuse a real, already-signed DMG — the enclosure has
   to survive signature checking, and the version comparison is read from the
   feed, so an existing DMG advertised under a higher build number gets Sparkle
   all the way to "Install and Relaunch":

   ```sh
   mkdir -p /tmp/feed && cp "build/iSCSI-Initiator-0.3.2.dmg" /tmp/feed/
   cp appcast.xml /tmp/feed/
   # edit /tmp/feed/appcast.xml: bump sparkle:version well past the installed
   # build, point the enclosure url at http://<this-mac>:8000/iSCSI-Initiator-0.3.2.dmg,
   # leave length and edSignature exactly as they are
   (cd /tmp/feed && python3 -m http.server 8000)
   ```

3. On the VM, redirect the feed without rebuilding — Sparkle reads this key from
   user defaults ahead of the Info.plist:

   ```sh
   defaults write me.herko.iSCSIInitiator SUFeedURL "http://<this-mac>:8000/appcast.xml"
   ```

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
