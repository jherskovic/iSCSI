# Feedback draft: APFS on a DriverKit virtual SCSI controller wedges the block layer

Draft for Feedback Assistant, alongside the existing **FB23814092**
(single-physical-segment limit for software SCSI controllers). Not yet filed —
filing needs the project owner's account.

**Suggested title:** APFS on an `IOUserSCSIParallelInterfaceController` wedges
the whole block device after the first access; raw I/O to the same device hangs

**Area:** Storage / DriverKit (`SCSIControllerDriverKit`)
**Platform:** macOS 26.6, Apple Silicon VM (UTM, Apple Virtualization), SIP off

---

## Summary

A DriverKit virtual SCSI controller serving a RAM buffer from inside the dext —
no hardware, no network, no storage backend of any kind — wedges the entire
block device the moment a *second* access is made to a mounted APFS volume on
it. After that, all I/O to the device blocks forever, including raw `dd` and
flush ioctls that bypass APFS entirely, and the machine degrades until only a
power cycle recovers it.

The controller is provably healthy throughout: it answers IOKit calls in 0 ms
and its own counters show every task it was handed completed exactly once, with
nothing outstanding.

The same driver serves ExFAT indefinitely without trouble, and APFS on an
`hdiutil` RAM disk is fine. It takes APFS **and** this driver together.

## Reproducer

Self-contained; no target, daemon, or network required.

1. Build the dext with `ISCSI_DEXT_SCRATCH_DISK 1` (serves a 512 MiB RAM buffer
   from the dext's own memory; every SCSI command is answered inline and no task
   is ever queued to anything else).
2. `newfs_apfs -v scratchTest /dev/diskN`
3. `mount_apfs /dev/diskNsM /Users/<you>/mnt` — deliberately **outside**
   `/Volumes`, so no system daemon touches the volume and the sequence is
   deterministic.
4. Touch the volume twice, e.g. `ls -a /Users/<you>/mnt` then
   `stat /Users/<you>/mnt`.

`scripts/vm-scratch-apfs.sh` in this repo automates exactly that and takes
`FS=apfs|exfat|exfat-part`.

**Observed:** the first access completes; the second blocks forever. So does a
subsequent `dd if=/dev/rdiskN bs=4096 count=1`. The order does not matter —
running `stat` first and `ls` second gives the same result with the roles
swapped, so it is positional, not operation-specific.

**Expected:** both accesses complete, as they do for ExFAT on the same driver
and for APFS on an `hdiutil` RAM disk.

## What distinguishes the failing configuration

| configuration | result |
|---|---|
| APFS on this driver (RAM buffer, 512-byte blocks, no daemon) | **wedges** |
| APFS on this driver (iSCSI-backed, 4096-byte blocks) | **wedges** |
| APFS on an `hdiutil` RAM disk | works |
| ExFAT on this driver, whole disk | works |
| ExFAT on this driver, GPT slice (same media nesting as APFS) | works |

## Evidence that the controller is not the stalled party

Captured during a wedge, with `getattr`, raw `dd` and a flush ioctl all blocked:

- A user-client open, a 16 MiB memory map, and an `ExternalMethod` dispatch to
  the dext each return in **0 ms**. A control against an unrelated service
  (`IOHIDSystem`) confirms IOKit itself is live.
- The dext's counters, read through that `ExternalMethod` rather than via
  logging: `parked=1372 fetched=1372 completed=1372 inflight=0`,
  `wdFail=0 aborted=0`, and a watchdog tick that is still advancing.
- No task-management function was ever issued to the controller
  (`cAborted == 0`), so the stack is not waiting on an abort either.

SCSI opcode histograms from the identical RAM-backed disk:

```
APFS  (wedges)  324 write  94 read  16 TUR  7 flush   total 441
ExFAT (works)   273 write  30 read  18 TUR  1 flush   total 322
```

Largest request is 16 KiB against an advertised single 64 KiB segment, so
nothing is being split or truncated.

## Ruled out by controlled test

Each of these was implemented or configured and re-tested; none changes the
outcome:

- **Barriers/flushes** — with `WCE=0` the daemon logs *zero* flushes and the
  wedge is unchanged.
- **Queue depth / re-entrancy** — `UserReportMaximumTaskCount = 1`, so at most
  one task is outstanding and the family cannot re-enter the controller mid
  completion. Still wedges.
- **UNMAP support** — every working configuration reports
  `DKIOCGETFEATURES` with unmap set while this device reported 0. Implementing
  VPD pages 0xB0/0xB2, `LBPME`, and `UNMAP` moved it to `0x10 [unmap]`
  (verified with `tools/dkflush.c`). Still wedges.
- **Command volume** — ExFAT pushes 303 data commands through the same driver
  without trouble.
- **Nested media** — ExFAT on a GPT slice, one `IOMedia` layer down exactly as
  APFS's container is, works.
- **Power management** — the framework declares no power callbacks.
- Short transfers, byte counts, completion accounting, media re-probe.

## Diagnostic difficulty worth flagging

Once the wedge occurs, every tool that could identify the blocked thread hangs
as well: `spindump`, `log show`, `ps`, `pgrep`, `sample`, and `ioreg -l`.
Controls matter here — `sample` hangs on an unrelated `sleep` process, and
`ioreg -l` hangs on `IOHIDSystem`, so neither hang says anything about storage.
The only channels that survive are a plain IOKit lookup/open/`ExternalMethod`
and output that crosses an ssh connection before the machine degrades.

That is itself part of the report: a driver-visible stall in this path is
currently very hard to diagnose from user space.

## What would help

A way to see which kernel thread holds the block-layer lock during the stall —
or confirmation of what `IOBlockStorageDriver` / `IOSCSIParallelFamily` expects
from a controller that this one is not providing, given that it completes every
task it is handed and continues to service IOKit requests normally.
