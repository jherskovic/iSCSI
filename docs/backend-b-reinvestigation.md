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
