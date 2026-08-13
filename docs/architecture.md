# Architecture

## Why two processes

DriverKit extensions (dexts) **cannot open TCP sockets** — no BSD sockets, no
Network.framework, in any DriverKit SDK through 25.x. So the iSCSI/TCP protocol
engine must live in user space, and the dext only presents the block device.
This is the same wall that stalled the old `iscsi-osx` kext port.

```
┌──────────────────────── user space ─────────────────────────┐
│  iscsictl ─XPC─► iscsid (LaunchDaemon)                       │
│                    │  Network.framework ──TCP──► target/NAS  │
│                    │                                          │
│                    ├─ iSCSIKit: PDU codec, negotiation,      │
│                    │  CHAP, CRC32C, session engine           │
│                    │                                          │
│      Backend A ──► FSKit file ──hdiutil CRawDiskImage──► /dev/diskN
│      Backend B ──► shared-memory ring + IOUserClient ─┐      │
└───────────────────────────────────────────────────────┼──────┘
                                          ┌──────────────▼─────────────┐
                                          │ iSCSIDext (C++): virtual   │
                                          │ SCSI HBA on IOUserResources│
                                          └──────────► kernel SCSI stack → /dev/diskN
```

## iSCSIKit (done)

Transport-free protocol core, so every path is unit-testable and fuzzable:

- **PDU layer** — all 17 iSCSI PDU types (RFC 7143 §11), a serializer and an
  incremental deframer that verifies header/data CRC32C digests and bounds
  DataSegmentLength (DoS guard against a hostile peer).
- **Negotiation** — RFC 7143 result functions (bool-and/or, numeric min/max,
  declarative, list-select) with strict validation of the target's answers;
  login state machine covering security + operational stages, CHAP and None
  auth, redirect, and C-bit continuation in both directions.
- **Auth** — CHAP (MD5), forward and mutual, vectors cross-checked against an
  independent implementation.
- **Session** — `ISCSIConnection` (an actor) runs the full-feature phase:
  CmdSN window flow control, StatSN validation, Data-In reassembly, R2T-driven
  Data-Out (immediate + unsolicited + solicited bursts), NOP keepalive/echo,
  task management, text exchange, logout. `ISCSISession` adds ERL0 recovery
  (drop → backoff → re-login with a fresh ISID), bounded transparent retry of
  interrupted (idempotent) block I/O, and NOP-based dead-peer detection.
- **Transport** — `ConnectionTransport` protocol with two implementations:
  `NetworkTransport` (Network.framework TCP, Nagle off) and `MemoryPipe` (used
  by tests and the in-process MockTarget).

Scope is a "daily-driver" initiator: single connection per session, ERL0, no
MC/S, no iSNS. Those are deliberate future work.

## The DriverKit throughput caveat (the load-bearing risk)

`SCSIControllerDriverKit` / `IOUserSCSIParallelInterfaceController` can host a
virtual (no-hardware) SCSI HBA by matching on `IOUserResources` — this is
proven (Apple forum thread 837879, with DTS involvement). **But** the
framework's data path assumes DMA hardware: for a software controller the
kernel rejects tasks whose buffer spans more than one physical segment
*before* the dext sees them, forcing ~4 KB per task and measured throughput of
2.5–8 MB/s even with a shared-memory ring and bundled tasks — far below a
1 GbE NAS. Apple DTS has confirmed this and signaled a "software backend"
opt-in fix (Feedback FB23814092) that **has not shipped** as of Aug 2026.

**Consequence for this project:** we ship **Backend A** (FSKit exposing the
LUN as a file + `hdiutil attach -imagekey diskimage-class=CRawDiskImage`) as a
usable, full-speed product now, and build **Backend B** (the dext) behind the
same `BlockDeviceBackend` protocol so it's ready the day the fix lands. Both
sit on the identical iSCSIKit session engine.

## Backend B implementation notes (when built)

- Two-personality matching: an `IOUserResources` bootstrap personality
  publishes a nub via `RegisterService()`; the
  `IOUserSCSIParallelInterfaceController` personality matches that nub.
- Daemon↔dext: `IOUserClient` + `IOBufferMemoryDescriptor` shared ring
  (request/completion slots, out-of-order completion) + `IODataQueueDispatchSource`.
- **Nub-teardown user-client command from day one** — an always-matched
  virtual dext never gets a termination signal, so in-place upgrades otherwise
  require a reboot.
- Known pitfalls to code around: report the real max target ID in
  `UserReportHighestSupportedDeviceID`; set `version =
  kScsiUserParallelTaskResponseCurrentVersion1` on every task response;
  the zero-filled-reused-WRITE-buffer bug.

## Storage-stack contract lessons (learned the hard way on real macOS)

Each of these produced a system-wide wedge or nondeterministic corruption
with a perfectly healthy dext underneath. Recorded so they never get re-broken:

1. **A NOT-READY fixed disk at probe time is dead forever.**
   `IOSCSIPeripheralDeviceType00::start` gives `ClearNotReadyStatus` exactly
   45 s, then `InitializeDeviceSupport` fails PERMANENTLY — and the daemon
   normally logs in much later than 45 s after boot. Modelling the LUN as
   REMOVABLE media (INQUIRY RMB=1, sense `02/3A/00` MEDIUM NOT PRESENT while
   detached) dodges this: the device attaches with "no medium" and polls
   forever. **But removable costs you every barrier** — see "The flush gap"
   below — so it is a stopgap, not the answer. The answer is to make the
   medium present *before* the family probes.
2. **The block driver reads the mode parameter HEADER and nothing else.** One
   MODE SENSE(6), page 0x3F, DBD=0, allocation length 4, once per media
   arrival, never repeated no matter what mode data length you report. So a
   correct caching page is not sufficient for anything — it is never fetched.
   Serve a well-formed response anyway (the original garbage one left the
   driver's cache state arbitrary), but do not expect WCE, DPOFUA, or the
   block descriptor to change behaviour. Keep SYNCHRONIZE CACHE parked-and-
   forwarded and honour FUA with a post-write flush.
3. **Preserve submission order for overlapping LBA ranges.** The kernel
   rewrites the same block back-to-back (GPT headers, APFS superblocks,
   journal heads) trusting device-order semantics. The dext hands tasks to
   the daemon oldest-taskTag-first (parks are serialized, so tags are
   submission-ordered) and the daemon's `OrderingGate` blocks a task until
   every overlapping in-flight or earlier-fetched task releases; disjoint I/O
   stays fully concurrent, flushes are whole-device barriers. Without this,
   two same-LBA writes race on the wire and the OLDER data wins
   nondeterministically — per-op CRC tracing shows nothing wrong.
4. **Fire `UserCallMediaParametersHaveChanged` on BOTH publish and
   unpublish.** Only firing on publish leaves the kernel's buffer cache
   serving pre-swap content when the daemon bounces faster than the ~3 s TUR
   poll (newfs/fsck then validate against stale pages and fail with EIO).
5. Slot lifecycle in the dext is a per-slot atomic state machine
   (Free→Parking→Parked→Fetched→Completing→Free, plus Zombie quarantine for
   watchdog-failed fetched slots). Every completion path claims by CAS;
   double completions and mid-park watchdog steals are structurally
   impossible. The daemon's per-task timeout (10 s) sits BELOW the dext
   watchdog (~16 s) so the clean CHECK CONDITION path fires first.

## The flush gap: removable media silently disables barriers (root cause found)

The symptom was: ExFAT works end to end, APFS wedges the whole storage stack
at mount, and **the kernel has never once sent SYNCHRONIZE CACHE to this
device** — measured with unconditional daemon-side `FLUSH` logging across
formats, file writes, WCE=0 and WCE=1. ExFAT does not journal; APFS commits
every transaction behind a barrier, so a barrier that never becomes a device
command is exactly the difference between the two.

The suspicion was that `SCSIControllerDriverKit` cannot deliver a
cache-synchronize to a user-space controller at all. **It can. The bug was
ours: modelling the LUN as removable media.**

The measurement chain, each step from `tools/dkflush.c` (raw-device
`DKIOCSYNCHRONIZECACHE` / `DKIOCSYNCHRONIZE`, no filesystem in the picture):

| | removable (RMB=1) | fixed (RMB=0) |
|---|---|---|
| `WriteCacheState` on the Type00 node | `No` | `Yes` |
| flush ioctl on `/dev/rdiskN` | returns success in 4–25 µs | 2–4 ms |
| SYNCHRONIZE CACHE reaching the daemon | never, in any configuration | every time |

The mechanism, from the dext's own CDB trace: on each media arrival the block
driver sends **exactly one MODE SENSE(6), page 0x3F, DBD=0, allocation length
4** — the mode parameter header alone — and never asks again, whatever mode
data length we report back. For a removable device it stops there and records
`WriteCacheState = No`; nothing downstream (write cache, FUA, the Barrier
storage feature, whether `DKIOCSYNCHRONIZECACHE` becomes a real command) is
ever built. Every flush is then satisfied in-kernel in microseconds and the
device sees nothing, so APFS's barriers are silent no-ops.

Things that look like they should matter and do not: WCE in the caching page
(the page is never fetched), DPOFUA in the mode header, a block descriptor,
`DKIOCGETFEATURES` (still reports `0x00000000` even when flushes are flowing —
the internal disk reports `0x12 [barrier unmap]`, so it is not the gate).

This puts the RMB=1 workaround and working barriers in direct conflict:
removable was adopted to dodge the 45-second `ClearNotReadyStatus` trap that
permanently fails a fixed disk which is NOT READY at probe (see lesson 1
above), and the daemon normally logs in long after boot. The fix has to make
the medium **present before the family probes**, not make the device
removable. See "Next: make the LUN a fixed disk" below.

With that fixed, APFS gets much further than it ever did:
`newfs_apfs /dev/diskN` on the whole device succeeds, the container
synthesizes, and `diskutil mount` **mounts the volume** — reproducibly, where
before the mount itself wedged the box.

### Still open #1: first access to the mounted volume hangs

`ls -la /Volumes/iSCSITest` on the freshly mounted volume usually blocks and
never returns; the box then slides into the familiar wedge (`ps`, `log show`,
and anything touching the mount table hang; bare ssh still answers; only a
power-cycle recovers).

What is known:
- **It is not our I/O.** During the hang the dext receives nothing but 3-second
  TEST UNIT READY polls — not one READ or WRITE — and the daemon is alive and
  connected (no error logged, its exit-status wrapper never fires). APFS is not
  waiting on a command we failed to complete.
- **It is not deterministic.** One run listed the volume instantly and
  correctly (`.Spotlight-V100`, `.fseventsd`, nothing else). Every run that
  hung had touched the mount within a second or two of `diskutil mount`; the
  one that worked had a couple of seconds of slack. A 15 s settle delay did
  NOT make it reliable, so "it's just a race after mount" is a hypothesis, not
  a conclusion.
- **It is not Spotlight.** Reproduced with `mdutil -a -i off`.
- **The wedge blocks process creation.** In the worst runs the harness's own
  timeout never fires — the watchdog loop cannot `fork`/`exec` — which,
  together with `ps` hanging, points at a global kernel lock (proc list / VFS)
  held by whatever is blocked, not at a mere per-volume stall.
- Red herring: reads failing with sense `04/08/00` in the log are the
  *teardown* — the harness's trap kills the daemon, the arena goes away, and
  the dext fails everything after that. They are not the cause.

Next: a stackshot during the hang, to name the thread and the lock. Note that
`spindump` is NOT usable here — it hangs even on a healthy VM with the LUN
attached, and then wedges the box itself. Try the kernel stackshot facility
directly, or dtrace (SIP is off in the test VM).

### Still open #2: the partition-map re-probe race

`diskutil eraseDisk` fails nondeterministically — `failed to write superblock
to block 0: 5` or `Couldn't read partition map` — an EIO generated in-kernel
that never reaches the driver, while every task the dext did receive completed
cleanly (`wdFail=0`, `aborted=0`). Rewriting the partition map triggers a media
re-probe that races the in-flight I/O. `newfs_apfs` on an already-probed slice,
or on a whole device with no partition map at all, does not hit it. The
structural fix below removes this race too.

## Next: make the LUN a fixed disk that exists only while the daemon is attached

Gate controller matching on the daemon: keep the bootstrap nub always-matched
with its own user client, have the daemon publish geometry to IT, and only
then set the marker property that lets the
`IOUserSCSIParallelInterfaceController` personality match. The LUN becomes a
FIXED disk (RMB=0) that appears when the daemon attaches and disappears when
it drops — real-HBA hot-plug semantics. That removes the NOT-READY window, the
removable-media polling, the re-probe churn, and the flush gap in one move.

`ISCSI_DEXT_FIXED_DISK_PROBE` in the dext is the diagnostic stand-in for this:
RMB=0 plus hardcoded geometry so the device is ready the instant the
controller starts. It proves the mechanism but is not shippable — geometry
must come from the daemon.

Entitlements (all restricted, requested from Apple): `com.apple.developer.driverkit`,
`.driverkit.family.scsicontroller`, `.driverkit.userclient-access` (daemon),
`com.apple.developer.system-extension.install` (host app). For development
before Apple grants them: `systemextensionsctl developer on` + SIP disabled,
done inside a throwaway macOS VM so the host stays protected.
