# macOS iSCSI Initiator (DriverKit)

A modern iSCSI initiator for macOS 26/27 on Apple Silicon. macOS ships no
initiator; the old open-source option is a dead kext. This project puts the
iSCSI/TCP protocol engine in a user-space Swift daemon and presents the LUN as
a real block device — via an FSKit/`hdiutil` backend (**working end-to-end**:
the block device comes from Apple's DiskImages framework, so it sidesteps the
DriverKit wedge entirely), and ultimately via a DriverKit virtual SCSI HBA once
Apple lifts the software-controller throughput limit (see
`docs/architecture.md`).

## Status

| Phase | What | State |
|------|------|-------|
| 0 | SwiftPM scaffolding, fuzz harness | ✅ done |
| 1 | PDU codec (all 17 PDU types), framer, CRC32C | ✅ done |
| 2 | Negotiation engine, login state machine, CHAP | ✅ done |
| 3 | Session/connection engine, scriptable MockTarget, hostile-script suite | ✅ done |
| 4 | `NetworkTransport` (TCP), `iscsictl`, iscsid daemon (BlockDevice + XPC) | ✅ **verified vs real TrueNAS**; daemon built + tested |
| 5 | FSKit + `hdiutil` block-device backend | ✅ **works end-to-end**: our module mounts, `hdiutil` attaches `lun0.img`, APFS formats/mounts, 32 MiB round-trip byte-exact, no wedge. Open: flush does not reach `synchronize` |
| 6 | DriverKit dext (virtual SCSI HBA) | 🚧 **real disk; ExFAT works end-to-end, APFS now formats and mounts**; see the open issues below |
| 7 | Fault-injection / soak / e2e scripts | ✅ scripts written (run once a LUN is mounted) |

151 tests pass (unit + integration + real-TCP-loopback); the PDU fuzzer runs
clean over millions of inputs. The full protocol stack is **verified end-to-end
against a real TrueNAS target** (login negotiation → INQUIRY → READ CAPACITY →
write + SYNCHRONIZE CACHE → read-back verify → logout).

The dext presents the LUN as a real block device on macOS 26.6: it attaches at
boot, the disk appears when the daemon logs in, and **ExFAT formats, mounts and
runs on it**. Data integrity is CRC-verified byte-exact across thousands of
ops including 16-way concurrent same-region storms, and the failure plumbing
is sound (~30k tasks: no double completions, no watchdog misfires, no leaks).

**The barrier bug is fixed.** APFS used to wedge the storage stack at mount
because the kernel never sent SYNCHRONIZE CACHE to this device — and the cause
turned out to be ours: presenting the LUN as *removable* media makes macOS's
SCSI block driver record `WriteCacheState = No` and elide every flush in-kernel
in a few microseconds, so APFS's barriers were silent no-ops. Presented as a
fixed disk, flushes reach the wire (`tools/dkflush.c` measures this directly),
`newfs_apfs` succeeds and the volume mounts. Full evidence and the measurement
table are in `docs/architecture.md` ("The flush gap").

Still open, and why this is not a daily driver yet:
- Removable was itself a workaround for the 45-second `ClearNotReadyStatus`
  trap that permanently kills a fixed disk not ready at probe. The dext
  currently papers over that with a diagnostic build flag
  (`ISCSI_DEXT_FIXED_DISK_PROBE`) that hardcodes geometry; the real fix is to
  gate controller matching on the daemon being attached.
- **After the first access to a freshly mounted APFS volume, the device stops
  serving I/O entirely** — and this has nothing to do with iSCSI. Built with
  `ISCSI_DEXT_SCRATCH_DISK 1` the dext serves a RAM buffer from its own memory
  (no daemon, no network, no target, every command answered inline) and APFS
  wedges identically. It needs APFS *and* our driver: APFS on an hdiutil RAM
  disk is fine, ExFAT on our driver is fine (whole disk or GPT slice), and the
  failure is positional — the first access completes, the second blocks, in
  either order. Raw `dd` and flush ioctls hang too, while the dext stays
  provably healthy: it answers IOKit calls in 0 ms and its counters show every
  task completed exactly once. Ruled out by controlled tests: barriers,
  truncation, byte counts, completion accounting, task-management functions,
  power management, concurrency, command volume, transfer size, and the nested
  media layer — see `docs/architecture.md` for the matrix and the method for
  each. `scripts/vm-scratch-apfs.sh` is the self-contained reproducer, and
  `docs/feedback-virtual-scsi-wedge.md` is a ready-to-file Feedback draft.
- `diskutil`'s partition-map rewrite still races a media re-probe
  (`Couldn't read partition map` / `failed to write superblock`).
- Wipe the scratch LUN (`iscsictl wipe …`) before attaching, or auto-mount
  drags you straight back into whichever of these is unfixed.

## Building the app + extensions (Xcode)

```sh
cd apps
xcodegen generate          # produces iSCSIInitiator.xcodeproj
open iSCSIInitiator.xcodeproj
# Set your signing Team in project.yml or the Signing pane, then build.
```
The DriverKit dext requires a SIP-off test VM to load — see `docs/vm-setup.md`
and `docs/entitlements.md`.

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
  MockTarget/        scriptable in-process target + TCP listener (test infra)
  iscsictl/          control CLI (discover, verify)
  iscsid/            daemon (Phase 4, stub)
  pdu-fuzz/          structure-aware fuzzer
Tests/
  iSCSIKitTests/     86 unit tests
  IntegrationTests/  43 tests: happy paths, hostile scripts, recovery, TCP loopback
scripts/fuzz.sh      ASan fuzz driver
docs/                architecture, entitlements, test playbook
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

See `docs/architecture.md` for the two-backend design and the DriverKit
throughput caveat, and `docs/test-playbook.md` for the full test strategy.
