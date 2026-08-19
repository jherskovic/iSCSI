# Backend B re-investigation (reopened 2026-08-19)

Branch `driverkit-wedge-reinvestigation`. Rig: the SIP-off VM at 192.168.0.34,
macOS 26.6.1 (25G76), Xcode 26.6, dext build 27 (0.1.2) — the
`ISCSI_DEXT_SCRATCH_DISK` + `ISCSI_DEXT_FIXED_DISK_PROBE` configuration, so
`disk7` is a 512 MiB RAM buffer inside the dext with no daemon, no network and
no target in the picture.

## Headline: the documented reproducer no longer reaches the wedge

`docs/architecture.md` describes the scratch reproducer as: format, mount
outside `/Volumes`, touch it twice, and the second access wedges. **It does not
get that far any more.** `newfs_apfs` fails first, deterministically, five times
out of five:

    nx_format:308: failed to write superblock to block 0: 5 - Input/output error
    tx_mgr_free_tx:195: rdisk7 Trash unfinished pending tx, xid range = 0x1 - 0x1
    newfs_apfs: unable to format /dev/disk7: Input/output error

That error text is recorded in "Still open #2: the partition-map re-probe race",
where it is described as **nondeterministic** and as something
`diskutil eraseDisk` hits while "`newfs_apfs` on a whole device with no
partition map does not". Both halves of that sentence are now false on this
build: this is `newfs_apfs`, on a whole device with no partition map, and it is
deterministic.

Either something regressed between the build that produced the architecture
notes and build 27, or the older characterisation was luck. Not yet resolved,
and it matters, because until it is the wedge itself cannot be reached.

## What is established

**The dext is not the party failing.** During a failed `newfs_apfs` it receives
315 tasks — `0x2a` WRITE(10), `0x28` READ(10), `0x35` SYNCHRONIZE CACHE — and
answers all of them. No error is logged, and its counters are clean.

**It is not transfer truncation.** This mattered because
`iSCSIDext.cpp:1068` calls truncation "the leading suspect for the wedge" in a
comment. `TRUNCATED-TRANSFERS` is **0** before and after a failed run, and the
log carries zero `TRUNCATED transfer` lines. Cleared, for this failure.

  Worth noting anyway: there are **two** clamps in that file and only one is
  instrumented. `iSCSIDext.cpp:1261` (`if (length > avail) length = avail;` in
  the scratch path, and the same shape at 1288 in the daemon path) shortens a
  transfer with no counter and no log whenever the CDB's block count implies
  more bytes than `fRequestedTransferCount`. It is silent by construction, so
  its counter reading 0 proves nothing about it. Instrument it before trusting
  it.

**It is not transfer size, and not the flush/barrier path in isolation.** Raw
`dd` writes to the same device succeed at 512, 1024, 1536, 2048, 4096, 8192,
16384 and 65536 bytes, including to block 0 — the very block `newfs_apfs`
cannot write. `dkflush --write` succeeds on all three ioctls
(`DKIOCSYNCHRONIZECACHE`, `DKIOCSYNCHRONIZE` whole-device, `DKIOCSYNCHRONIZE`
barrier) plus a pre- and post-flush `pwrite` of block 0.

**The EIO is manufactured above the driver, and here is where.** Caught with
`scripts/dtrace/storage-errors.d`, which nets any IOReturn-shaped error out of
the four storage kexts:

    ERR  [newfs_apfs] IOBlockStorageServices::doUnmap          -> 0xe00002c7  kIOReturnUnsupported
    ERR  [newfs_apfs] WaitForTask                              -> 0xe00002c2  kIOReturnBadArgument  (x3)
    CMPL [kernel_task] breakUpRequestCompletion  status=0xe00002ca actual=0    kIOReturnIOError
    ERR  [newfs_apfs] IOStorageSyncer::wait                    -> 0xe00002ca
    ERR  [newfs_apfs] IOStorage::write                         -> 0xe00002ca
    CMPL [newfs_apfs] dkreadwritecompletion      status=0xe00002ca actual=1024

The `doUnmap` refusal is expected and benign — UNMAP was implemented once,
changed nothing, and was reverted. The chain that matters starts at
`breakUpRequestCompletion`, which is the **IOBreaker** path: the path taken
precisely because we advertise `kIOMaximumSegmentCount{Read,Write}Key = 1`
(`iSCSIDext.cpp:349`). So the request that fails is one the kernel had to split,
and it comes back with zero bytes transferred while every task the dext saw was
answered.

## The leading hypothesis, and why it is not yet a finding

A control run in the same VM at the same moment: `newfs_apfs` on an `hdiutil`
RAM disk of **identical geometry** (536,870,912 bytes, 512-byte blocks)
succeeds silently. Ours fails. The properties that differ:

| | our scratch disk | hdiutil RAM disk |
|---|---|---|
| `Removable` / `Ejectable` | No / No | Yes |
| `WriteCacheState` | **Yes** | No |
| `newfs_apfs` | **EIO** | passes |

`WriteCacheState = Yes` is the thing RMB=0 bought us — it is what makes
barriers real rather than elided, and it was the whole point of the fixed-disk
change that closed the flush gap. The suggestion is that closing the flush gap
turned on a path our controller does not satisfy.

**This control does not establish that.** The RAM disk differs from our device
in far more than RMB: it is a DiskImages device on an entirely different driver
stack, not an `IOSCSIParallelInterfaceController`. Holding RMB as the single
variable requires our own device built both ways. That is the next experiment,
and it needs a rebuild — bump `CFBundleVersion`, or you will debug build 27.

## Method notes for whoever picks this up

- **`execname` is capped at 16 characters.** `me.herko.iSCSIInitiator.dext`
  appears to dtrace as `me.herko.iSCSIIn`. A predicate on the full bundle id
  matches nothing, silently.
- **fbt demangles.** `dtrace -l` prints C++ names in brackets and `probefunc`
  is the mangled symbol, so `c++filt` on the host closes the loop. The
  `kernel.release.vmapple` symbolication problem in the memory applies to
  `stack()`, not to fbt function names — base-kernel frames in `stack()` are
  still bare addresses, so prefer fbt naming over stacks here.
- **Filter fbt by `execname`, not by path.** Unfiltered, one 5-second tick
  logged 133,869 `IOMedia::read` entries from the boot disk. `execname` also
  needs no `copyinstr`, which is what defeated every earlier trace once
  page-ins stalled.
- **fbt has no return probe for some tail-call/leaf functions,** so unfiltered
  balances climb forever. Baseline first: a healthy single 4 KiB raw read
  leaves a stable 15-entry phantom residue, identical across ticks.
- **Validate every probe tool on a healthy box first.** `ukopen iSCSIDext`
  (lookup + open + 16 MiB arena map + `ExternalMethod`) returns in 12 ms
  healthy; `ukopen IOHIDSystem` in 10 ms. Those are the numbers a wedge-time
  reading has to be compared against.
- `dkflush` opens read-only unless given `--write`, and every flush then fails
  with `Permission denied` in 3 µs. That is the tool, not the device.

## Tooling added on this branch

- `scripts/dtrace/storage-errors.d` — nets any IOReturn error out of
  IOStorageFamily / IOSCSIArchitectureModelFamily / IOSCSIBlockCommandsDevice /
  IOSCSIParallelFamily, plus completion statuses. This is what caught the chain
  above.
- `scripts/dtrace/storage-inflight.d` — entry/return balance per function plus
  sleep stacks, for finding what entered and never returned. Built for the
  wedge; validated healthy, not yet run against one.
- `scripts/vm-wedge-run.sh` — staged one-shot wedge runner. `STAGE=setup` does
  newfs+mount with no tracer armed; `STAGE=probe` runs the control sets and the
  accesses. Batches every control into a single wedge, three times over
  (early/mid/late), because one wedge costs a power-cycle and the box degrades
  progressively — the docs' unresolved `ukopen`-returns-in-0 ms versus
  `dext-stats`-hangs conflict may simply be two ages of the same wedge.

## Not yet done

- The wedge itself has not been reached on this build, so **nothing here
  supersedes the wedge findings in `docs/architecture.md`.**
- The missing control named in `docs/architecture.md` — an unrelated driver's
  user client opened *during* a wedge — is armed in `vm-wedge-run.sh` but has
  not run.
- RMB=1 vs RMB=0 on our own device, the single-variable version of the table
  above.


---

# Part 2: macOS 26.6.2 — the mechanism found (2026-08-19, same day)

The VM was updated to 26.6.2 (25G83) mid-investigation. The failure moved, and
the move is what cracked it open.

## How the symptom moved

| | 26.6.1 (25G76) | 26.6.2 (25G83) |
|---|---|---|
| `newfs_apfs` on our device | EIO, 5/5 (that boot) | succeeds |
| `mount_apfs` | — | succeeds |
| first access after mount | (26.6.1: completed) | **blocks forever** |
| everything after | — | blocks; box degrades to the familiar pileup |
| APFS on an hdiutil RAM disk | works | works (verified clean-boot, same OS) |

The wedge now arms at **mount**: mount_apfs's own checkpoint is the last I/O
the device ever serves (its tail is SYNCHRONIZE CACHE + one 4 KiB write —
the same signature the 26.6.1 architecture notes recorded for the first
access). Immediately after mount returns, even fork/exec of new processes
stalls — one victim stack runs `sandbox match_rootless → vnode_getattr →
apfs_vnop_getattr → … → buf_biowait`, i.e. every process spawn does a sandbox
getattr against the wedged volume, which is why the whole box dies.

## The mechanism, captured

Chain of instruments, each validated healthy-first (all in `scripts/dtrace/`):

1. **The dext is healthy and idle through the wedge.** TEST UNIT READY
   arrives every 3 s and is answered, all through the wedge; watchdog stats
   stay clean. The docs' "the dext itself is stuck" hypothesis is **refuted**
   on this OS. (The recurring `WaitForTask → kIOReturnBadArgument` errors are
   the LUNRescan/Ping path's normal signature — they fire on healthy boots
   too, and are NOT a wedge signal.)
2. **Victims park in `buf_biowait ← nx_buf_bread`** — an APFS btree-node
   read against the device vnode that never completes (off-CPU stack capture,
   `wedge-owner.d`). The victim's read never becomes a SCSI command.
3. **No live loop.** During the standing wedge the storage stack is silent;
   the earlier-suspected "retry storm" was the mount burst itself
   (`wedge-loop.d` per-tick rates: storm during newfs/mount, then zero).
4. **The swallow, with a stack** (`wedge-zero.d`): during the mount
   checkpoint, exactly **35 calls (reproducible across runs) to
   `IOBreaker::getBreakSize` return 0**, all in the dext's kernel RPC
   context, on this stack:

       IOBreaker::getNextStage()
       ← IOBlockStorageServices::AsyncReadWriteComplete
       ← IOSCSIBlockCommandsDevice::AsyncReadWriteCompletion
       ← … ← IOUserSCSIParallelInterfaceController::UserCompleteParallelTask

   A request broken into stages completes a stage through our dext; the
   breaker computes the NEXT stage's size as zero and cannot advance. On
   26.6.1 that case completed the request with `kIOReturnIOError actual=0`
   (the newfs EIO of Part 1). On 26.6.2 nothing is completed — **the request
   is orphaned in-kernel**, and its issuer waits in `buf_biowait` forever.

   RETRACTED mid-session reading, recorded on purpose: "the dext receives an
   empty buffer and completes GOOD with 0 bytes." The stack supersedes it —
   the zero-size stage is never dispatched; the dext never sees any of this.

5. **Calibration:** in the same runs, the same call site returned ~16 KiB
   break sizes 198 times with the same constraint arguments. So the zero is
   geometry-dependent (specific stage offsets/buffers), not a constant
   misconfiguration of every read. The raw argument slots captured by dtrace
   were not decoded with confidence; do not build on any per-slot reading.

## The one aberrant thing we report

`iSCSIDext.cpp:355` sets `kIOMinimumHBADataAlignmentMaskKey = 1`. Family
convention for byte-aligned data is an all-ones mask; a literal 1 is
near-certainly wrong regardless of OS, and it is the only eccentric value in
our constraint set (the registry confirms the rest publish exactly as
intended: segment count 1, segment bytes 65536, block counts 65535).

**Fix experiment (single variable):** change the mask to
`0xFFFFFFFFFFFFFFFF`, rebuild (bump `CFBundleVersion`!), and re-run with
`wedge-zero.d` armed. Success = zero ZERO lines AND first access, second
access, raw read, `dkflush --write`, unmount all pass AND a second boot
repeats it (this bug has per-boot history). If zeros persist, the next single
variable is `alignment = 1` in `UserGetDMASpecification`; after that, stop
and re-diagnose.

Scope guard: this does **not** claim to solve the documented 26.6.1 wedge.
The signature match (checkpoint tail, then silence) makes the same orphaning
plausible there, but 26.6.1 is no longer testable on this rig —
linked-but-unverified.

## Instruments added in part 2 (all in `scripts/dtrace/`)

- `wedge-owner.d` — every thread's last off-CPU stack keyed by thread
  pointer; victims that park on turnstiles (invisible to `sched:::sleep`)
  show up here.
- `wedge-depth.d` — entry/return ladder from `nx_buf_bread` down to
  `executeRequest`. Lesson learned: deblock/breakUp/IOMedia read/write leak
  +1 per call (missing fbt returns), so balances scale with traffic and
  cannot name a stuck function; rates and stacks can.
- `wedge-loop.d` — per-tick rates + `getBreakSize` return distribution.
- `wedge-zero.d` — full argument set + stack for every zero-size break.

## Method notes (26.6.2 additions)

- The wedge now arms so early that a probe process may fail to even spawn:
  the trigger's `lsprobe` never issued one syscall. Arm tracers BEFORE
  `newfs`, and treat mount itself as the dangerous step.
- `sched:::sleep` misses turnstile parks entirely; `sched:::off-cpu` with
  `stack()` keyed by `(uint64_t)curthread` is the reliable park-site capture.
- `os_log` `%s` redaction (`<private>`) hid the dext's `buf=ok/none`
  discriminator all session. Instrument with `%{public}s` for diagnostics.
- The dext's dtrace `execname` is `me.herko.iSCSIIn` (16-char cap).
