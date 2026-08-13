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

1. **Model the LUN as REMOVABLE media** (INQUIRY RMB=1, sense `02/3A/00`
   MEDIUM NOT PRESENT while the daemon is detached). A fixed disk that is
   NOT READY at probe gets exactly 45 s of `ClearNotReadyStatus` polling from
   `IOSCSIPeripheralDeviceType00::start`, then `InitializeDeviceSupport` fails
   PERMANENTLY — and the daemon usually logs in much later than 45 s after
   boot. Removable media attaches with "no medium" and polls forever; the disk
   appears whenever the daemon publishes and detaches cleanly when it drops.
2. **MODE SENSE must serve a WELL-FORMED caching page with WCE=0.** Two
   failure modes bracket this: (a) the original garbage MODE SENSE (header
   only, wrong lengths) left the block driver's cache state arbitrary; (b)
   WCE=1 is actively harmful — the kernel STILL never emitted SYNCHRONIZE
   CACHE, `DKIOCSYNCHRONIZECACHE` returned success in 83 µs without touching
   the device, and the very next write (newfs_apfs's final superblock commit)
   was rejected in-kernel with EIO in 24 µs: deterministic "failed to write
   superblock to block 0", format impossible. WCE=0 is also the honest
   report: the daemon completes a write only after the target acks it, so no
   host-visible volatile cache exists. Keep SYNCHRONIZE CACHE parked-and-
   forwarded and honor FUA with a post-write flush for whenever the kernel
   does send them.
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

## OPEN: APFS hangs; ExFAT works (the current blocker)

Status after a full day of instrumented testing on macOS 26.6.1 (dext v10):
**ExFAT formats, mounts, and runs perfectly. APFS reproducibly wedges the
storage stack the moment a volume is mounted** — not under load, at mount.
Once wedged, anything touching the mount table (`mount`, `ls /Volumes`,
`ioreg -c IOBlockStorageDevice`) blocks forever; bare ssh still answers. Only
a VM power-cycle recovers it. Because a mounted-at-attach APFS volume
re-triggers it, the scratch LUN must be wiped (`iscsictl wipe`) before
attaching, or the box wedges on auto-mount.

What is ruled OUT (measured, not assumed):
- Our task plumbing. ~30k tasks serviced: `wdFail=0`, `full=0`, no double
  completions, no leaks; every parked task completes well inside the watchdog.
- Data correctness. Write-vs-readback CRC32C cross-checks over thousands of
  ops, including 16-way concurrent same-region storms: zero mismatches.
- Short/truncated transfers. Every serviced op moves exactly its CDB length
  (the short-transfer guards never fired).
- The APFS *format* code path per se: `newfs_apfs` on an already-probed,
  stable slice SUCCEEDS. It is `diskutil eraseDisk APFS` that fails
  nondeterministically, because rewriting the partition map triggers a media
  re-probe (INQUIRY / MODE SENSE / PREVENT-ALLOW / READ CAPACITY appear
  mid-write-stream) that races the in-progress format; the losing write is
  rejected in-kernel with EIO in ~24 µs, never reaching the driver.

The load-bearing observation: **the kernel has never once sent SYNCHRONIZE
CACHE to this device** — confirmed by unconditional daemon-side logging
(`FLUSH` lines) across full formats and file writes, with WCE=0 and WCE=1,
despite `IOStorageFeatures = {Barrier=Yes, Unmap=Yes}`. ExFAT does not
journal; APFS commits every transaction behind a barrier. A barrier request
that is never translated into a device command — and whose waiter is never
completed — would block APFS's commit path forever and cascade exactly the
VFS-wide hang we see.

Next steps, in order:
1. Determine whether `SCSIControllerDriverKit` can deliver a cache-synchronize
   to a user-space controller AT ALL. If the family never converts the
   IOStorage barrier into a `UserProcessParallelTask`, this is an Apple-side
   gap of the same species as the single-segment limit (FB23814092), it
   blocks every journaling filesystem on a DriverKit software HBA, and it
   deserves a Feedback filing. Confirm by finding ANY condition that makes
   0x35/0x91 arrive.
2. Capture a stackshot DURING the hang, written to the (still-healthy) boot
   volume, to name the thread APFS is blocked in. Start it on a delay before
   mounting, since the shell is unusable afterwards.
3. Fix the re-probe race structurally by making the medium present BEFORE the
   family probes: keep the bootstrap nub always-matched with its own user
   client, have the daemon publish geometry to IT, and only then set the
   marker property that lets the `IOUserSCSIParallelInterfaceController`
   personality match. The LUN is then a FIXED disk (RMB=0) that exists only
   while the daemon is attached — real-HBA hot-plug semantics — which removes
   the NOT-READY window, the removable-media polling, and the re-probe churn
   in one move.

Entitlements (all restricted, requested from Apple): `com.apple.developer.driverkit`,
`.driverkit.family.scsicontroller`, `.driverkit.userclient-access` (daemon),
`com.apple.developer.system-extension.install` (host app). For development
before Apple grants them: `systemextensionsctl developer on` + SIP disabled,
done inside a throwaway macOS VM so the host stays protected.
