# Feedback draft: a software SCSI controller cannot be made safe on macOS

Draft for Feedback Assistant, alongside the existing **FB23814092**
(single-physical-segment limit for software SCSI controllers). Not yet filed —
filing needs the project owner's account.

**Suggested title:** `IOUserSCSIParallelInterfaceController`: a zero-size
IOBreaker stage orphans the request (whole-system hang), and the only
advertisement that avoids it silently loses user data

**Area:** Storage / DriverKit (`SCSIControllerDriverKit`)
**Platform:** Apple Silicon VM (UTM / Apple Virtualization), SIP off.
Defect 1 measured on both macOS 26.6.1 (25G76) and 26.6.2 (25G83), with
different outcomes on each — see below. Defect 2 measured on 26.6.2 only.
API surface confirmed unchanged in the macOS 27 SDK.

> **Rewritten 2026-08-19.** The previous draft reported "APFS wedges the block
> layer" with the controller exonerated but no mechanism. The mechanism is now
> captured, and it turned out to be two distinct defects that trade against
> each other. The old draft's central evidence — that the controller answers
> IOKit normally and completes every task it is handed — still holds and is
> retained below.

---

## Summary

A hardware-less SCSI controller built on
`IOUserSCSIParallelInterfaceController` has exactly two behaviours available
to it, selected by what it advertises in `UserReportHBAConstraints`, and
**both are unsafe**:

1. **`kIOMaximumSegmentCountRead/WriteKey = 1`** — the value FB23814092 forces
   on software controllers. `IOBreaker` then computes a **zero-size stage** at
   certain buffer geometries, and on macOS 26.6.2 that request is **orphaned
   in the kernel**: never completed, never failed. Its issuer waits in
   `buf_biowait` forever, every subsequent process spawn queues behind the
   volume via sandbox's `vnode_getattr`, and the machine is unrecoverable
   without a power cycle. On 26.6.1 the same geometry failed the request
   loudly instead (`kIOReturnIOError`, 0 bytes) — so this is a **regression
   between 26.6.1 and 26.6.2**.

2. **A larger segment count** — avoids the zero-size stage, but requests
   larger than one 16 KiB page are then rejected before the dext sees them,
   and **macOS discards that failure on the cluster-pageout path**. Writes
   return success, `sync` returns success, reads return the data from the page
   cache, and **the data never reaches the device**. Nothing is logged to the
   application. This is silent user-data loss through a stock API path.

Item 2 is, we think, the more serious of the two.

---

## Defect 1: a zero-size IOBreaker stage orphans the request

### Reproducer

Self-contained; no target, daemon, or network required.

1. Build the dext with `ISCSI_DEXT_SCRATCH_DISK 1` (serves a 512 MiB RAM
   buffer from the dext's own memory; every SCSI command is answered inline)
   and `kIOMaximumSegmentCountRead/WriteKey = 1`.
2. `newfs_apfs -v scratchTest /dev/diskN`
3. `mount_apfs /dev/diskNsM /Users/<you>/mnt` — deliberately **outside**
   `/Volumes`, so no system daemon touches the volume and the sequence is
   deterministic.
4. Touch the volume once.

**Observed (26.6.2):** the mount's own checkpoint is the last I/O the device
ever serves. The next access blocks forever, as does raw `dd` on
`/dev/rdiskN`, a flush ioctl, and — within seconds — every new process on the
machine.

**Observed (26.6.1):** `newfs_apfs` instead fails with
`failed to write superblock to block 0: 5 - Input/output error`.

### The mechanism, captured

During the mount checkpoint, `IOBreaker::getBreakSize` returns **0** — 35
times per run, reproducibly (measured in the RAM-scratch configuration above,
512-byte blocks; the count is a property of that geometry, not a universal
figure) — on this stack:

```
IOBreaker::getNextStage()
  ← IOBlockStorageServices::AsyncReadWriteComplete
  ← IOSCSIBlockCommandsDevice::AsyncReadWriteCompletion
  ← IOSCSIHierarchicalLogicalUnit::HLUNTaskCompletion
  ← IOSCSITargetDevice::TargetTaskCompletion
  ← IOSCSIProtocolServices::ProcessCompletedTask
  ← IOSCSIProtocolServices::CommandCompleted
  ← IOCommandGate::runAction
  ← IOUserSCSIParallelInterfaceController::UserCompleteParallelTask
```

The arguments at those calls are exactly what the driver advertises
(`maxSegmentCount = 1`, `maxSegmentByteCount = 65536`, alignment 1,
`requestBlockSize = 512`, `maxBlockCount = 65535`). Reading
`IOBlockStorageDriver.cpp` from opensource.apple.com, a break is the buffer's
current physical run truncated down to a block multiple — so when a stage
boundary lands where the next physical run is shorter than one block, the
truncation floors to zero. In the same runs the identical call site returned
~16 KiB break sizes 198 times, so the zero is geometry-dependent, not a
constant misconfiguration.

Whatever the correct fix for the zero, **a zero-size stage must not orphan
the request.** 26.6.1's behaviour (fail it) was survivable; 26.6.2's is not.

### Evidence the controller is not the stalled party

Captured during a hang, with `getattr`, raw `dd` and a flush ioctl all
blocked:

- The controller answers `TEST UNIT READY` every 3 s **throughout the hang**,
  and its watchdog tick keeps advancing.
- A user-client open, a 16 MiB memory map, and an `ExternalMethod` dispatch to
  the dext each return in **0 ms**. A control against an unrelated service
  (`IOHIDSystem`) confirms IOKit itself is live.
- The dext's counters, read through that `ExternalMethod` rather than via
  logging: `parked=1372 fetched=1372 completed=1372 inflight=0`,
  `wdFail=0 aborted=0`.
- No task-management function was ever issued to the controller
  (`cAborted == 0`), so the stack is not waiting on an abort either.
- The blocked victim's kernel stack ends in `buf_biowait` under
  `nx_buf_bread` — an APFS btree read that never became a SCSI command at
  all.

### Ruled out by controlled test

Each was implemented or configured and re-tested; none changes the outcome:

- **Barriers/flushes** — with `WCE=0` the driver logs *zero* flushes and the
  hang is unchanged.
- **Queue depth / re-entrancy** — `UserReportMaximumTaskCount = 1`, so at most
  one task is outstanding. Still hangs.
- **UNMAP support** — implementing VPD 0xB0/0xB2, `LBPME` and `UNMAP` moved
  `DKIOCGETFEATURES` from 0 to `0x10 [unmap]`. Still hangs.
- **Removable vs fixed media, write-cache advertisement, media re-probe,
  short transfers, byte counts, completion accounting.**
- **Command volume** — ExFAT drives 300+ data commands through the same
  driver without trouble; it does not journal, so it never produces the
  buffer geometry that triggers the zero.

---

## Defect 2: cluster-pageout failures are discarded, losing user data silently

### Reproducer

Same driver, with `kIOMaximumSegmentCountRead/WriteKey = 32` (which removes
defect 1 entirely — zero-size breaks go from 35 per run to 0). Format and
mount any filesystem on it, then:

```c
int fd = open("<file on the volume>", O_CREAT|O_RDWR|O_TRUNC, 0644);
for (int i = 0; i < 30; i++) write(fd, one_megabyte, 1048576);
fcntl(fd, F_FULLFSYNC);        // <-- returns EIO
```

**Observed:** `write()` succeeds. `sync` succeeds. Reading the file back
succeeds (from the page cache). `F_FULLFSYNC` returns `EIO` — and it is the
*only* thing that does. Unmount and remount, and the file's contents are gone:
zeros, or whatever the extents held before.

`cp` onto the volume fails visibly (`fcopyfile failed: Input/output error`)
because `fcopyfile` surfaces the same error the pageout path swallows, which
is a useful contrast — the identical bytes written with `dd` "succeed" and are
lost.

**Version scope, stated precisely.** Everything in this section was measured
on 26.6.2. On 26.6.1 the same >16 KiB rejection surfaced *loudly* through the
synchronous write path — `IOStorageSyncer::wait` and `dkreadwritecompletion`
both returned `kIOReturnIOError` and `newfs_apfs` failed visibly at its
superblock write. Whether the asynchronous cluster-pageout path also
swallowed the error on 26.6.1, or whether the swallowing is itself new in
26.6.2, is **untested** — the test rig was updated mid-investigation and
26.6.1 is no longer available on it. If the swallowing is also new, then both
defects in this report regressed in a single point release.

### What we measured

With every SCSI task logged at the datamover (LBA + CRC32C per operation), a
clean-room run — fresh boot, fresh target, virgin filesystem — writing 90 MB
of files produced **270 MiB of write traffic, all of it metadata, confined to
LBAs 0–24,600. The file data never became SCSI writes at all.** Small
metadata writes (4–16 KiB) succeed throughout, which is exactly why the
filesystem's own structure stays consistent and healthy-looking while file
contents do not survive a remount.

The measured boundary is **≤16 KiB per task passes, >16 KiB is rejected before
the driver sees it**. We presume this is FB23814092's single-physical-segment
rule (one 16 KiB page = one run on Apple Silicon), though we note one
unexplained detail: the same buffer geometry that produces zero-size breaks
under segment count 1 passes cleanly under 32, which a strict one-run rule
would forbid unless `UserGetDataBuffer` bounces the buffer.

An innocent bystander confirms it independently: `mds_stores`, indexing the
volume unasked, logs streams of `Previous write error` against it.

**The request:** whatever the correct constraint plumbing turns out to be, a
rejected pageout must not be reported to the application as success. Today the
only way a program can discover the loss is to call `F_FULLFSYNC` and check
its return.

---

## Why these two cannot both be avoided

| advertisement | breaker behaviour | outcome |
|---|---|---|
| `segmentCount = 1` | pre-chops everything into single runs | zero-size stage → orphaned request → whole-machine hang |
| `segmentCount = 32` | passes multi-run stages | >16 KiB rejected pre-dispatch → pageout EIO discarded → silent data loss |
| adding `kIOMaximumByteCountRead/WriteKey` | keys are consumed but never published to any registry node | `newfs_apfs` fails its wipefs pass with EIO — worse than either |

A stage would have to be simultaneously never-zero and never larger than one
physical run, and at a sub-block physical run those requirements contradict.
One knob remains untried (`maxTransferSize = 16384`), but even if it works it
returns the driver to ~16 KiB per task, which is the throughput ceiling
FB23814092 already describes.

## Diagnostic difficulty worth flagging

Once defect 1 occurs, every tool that could identify the blocked thread hangs
as well: `spindump`, `log show`, `ps`, `pgrep`, `sample`, and `ioreg -l`.
Controls matter here — `sample` hangs on an unrelated `sleep` process, and
`ioreg -l` hangs on `IOHIDSystem`, so neither hang says anything about
storage. The only channels that survive are a plain IOKit
lookup/open/`ExternalMethod` and dtrace output that crosses an ssh connection
before the machine degrades.

Defect 2 is harder still, because the system actively reports success:
`cmp`'s own mmap reads fault against the same >16 KiB ceiling and return
plausible-looking byte counts, and filesystem reads serve page cache over
extents that were never written. Only raw ≤16 KiB device reads and a
driver-side per-operation trace are trustworthy witnesses.

## What would help

- Confirmation of what `IOBreaker`/`IOBlockStorageServices` expect from a
  controller that completes every task it is handed, and why a zero-size
  stage is reachable at all.
- A zero-size stage failing the request rather than orphaning it — restoring
  26.6.1's behaviour — as an immediate mitigation for the hang.
- The pageout path surfacing rejection to the application instead of
  discarding it.
- The software-backend opt-in signalled in FB23814092. The
  `SCSIControllerDriverKit` API surface in the macOS 27 SDK is byte-identical
  to 25.5 (same methods, same keys, same constants), so as of that SDK it has
  not shipped.

## Note on the configuration

This controller matches a hardware-less provider (an `IOUserService` bootstrap
nub published via `RegisterService()`), which the newly expanded
`IOUserSCSIParallelInterfaceController` documentation in the macOS 27 SDK does
not describe — its "Matching Criteria" section names `IOProviderClass:
IOPCIDevice` for PCI controllers only. If a hardware-less software controller
is not intended to be supportable, that is itself a useful answer — but note
what forces the design: DriverKit provides no BSD sockets and no
Network.framework in any SDK through 27.0, so a network storage transport
*cannot* live in the dext. If a hardware-less controller is also unsupported,
there is no sanctioned path for a user-space storage transport on macOS at
all.
