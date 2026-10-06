# Flush per request: feasibility (2026-10-06)

Origin: GitHub issue #2. A user measured a local patch that writes the
commands of one request without FUA, issues one SYNCHRONIZE CACHE, and
acknowledges the request only once the flush completes: **107.5 → 119–122 MB/s
(+11–13%)** through FSKit on TrueNAS 26.0 beta, single NVMe pool, no SLOG. The
maintainer's reply set the conditions: opt-in, the four pitfalls handled, and
no default-on without a real power cut on at least one target.

This page is what the `per-request-sync` branch built to answer "can we do
that safely, and what does it cost to carry". **Short answer: yes, and not
much. It fits in the two block devices, about 230 changed lines of
production code (comments included) across both protocols. Two of the four pitfalls are handled by the existing
structure with no new code. The gain is bounded by the FSKit request shape,
and on ZFS by the per-byte ZIL cost, so it is a modest sequential-write win
and nothing for small writes.**

## What was built

`WriteDurability` (in `BlockDevice.swift`) replaces the devices' `writeThrough`
flag with three modes: `.cached`, `.forceUnitAccess` (what ships), and
`.flushPerRequest`. The old `writeThrough:` initialisers remain and map onto
the first two. Under `.flushPerRequest`:

- **A request that fits in one command carries FUA, exactly as today.** A
  write plus a flush is two round trips. FUA is one round trip, and both leave
  nothing in the cache.
- **A larger request** goes out as its commands without FUA, with the existing
  bounded pipelining. Once all of them have status, one SYNCHRONIZE CACHE(16)
  (IMMED clear, LBA 0, zero blocks: the whole LUN) or NVMe Flush is issued, and
  `write` returns only when it completes.
- **An epoch is read before the first command and again after the flush.** If
  it moved, the whole request is written again with FUA.
- **On a positive WCE=0** (SCSI caching page, cached per epoch) **or VWC=0**
  (NVMe Identify Controller, re-read on every association) there is nothing to
  batch, and the request is written with FUA throughout, exactly as today.

`FlushPolicy.flushPerRequest` selects it at login in `DaemonCore`. It counts as
durable at acknowledgement: no detach flush, and `SessionInfo.writeThrough` is
true. `iscsictl write-bench --flush-per-request` and `iscsictl nvme write-bench
--flush-per-request` measure it raw. **No stored record and no UI can reach
it yet.** See "What shipping would still need".

## The pitfalls, one by one

| pitfall (issue #2) | handled by | evidence |
|---|---|---|
| transparent recovery hides a lost cache | epoch check + FUA replay (new) | `PerRequestFlushTests`, both protocols, with negative controls |
| a failed flush must fail the request and drop the cache range | **existing structure** | the flush runs inside the XPC `write` call |
| `ioLock` held until the flush completes | **existing structure** | the same |
| SYNCHRONIZE CACHE(10)-only targets, WCE=0, NVMe VWC=0 | fallback; FUA when not volatile (new) | `PerRequestFlushTests` |

### Transparent recovery

The epoch is a generation, not an error, as the maintainer asked. The device
never sees the error anyway, because `ISCSISession.execute` and
`NVMeController.execute` swallow it and retry. Two new counters, each bumped
by every login that produces a usable connection, including the first:
`ISCSISession.connectionGeneration` and `NVMeController.associationGeneration`.
`recoveryCount` would have done in every path that exists today. The new
counters are bumped in `establish()` itself, so they stay correct whatever
path a future change uses to rebuild a connection.

Reading the epoch *before* the first command means a reconnect anywhere in the
window is caught: during a write, between the writes and the flush, or under a
task-timeout retry of the flush itself. The replay needs no epoch check of its
own: an acknowledged FUA command is durable however many reconnects follow.
The false positive costs one extra write of one request after each reconnect.

**Beyond the issue's list:** `ISCSIBlockDevice.executeAbsorbingUnitAttention`
silently retried every UNIT ATTENTION. A 29h UA (POWER ON, RESET, OR BUS DEVICE
RESET OCCURRED) is how SCSI reports that a target lost state, which can include
its cache, *without* the connection dropping. Every absorbed UA now counts
toward the iSCSI epoch. It counts every UA, not just ASC 29h. A UA is rare,
and a false positive costs one replay. Counting 2A/01 (MODE PARAMETERS
CHANGED) also refreshes the cached WCE answer. NVMe/TCP
has no in-band equivalent: a controller reset ends the association, and the
generation covers that.

Both recovery scenarios are scripted against `RAMDisk`'s volatile cache. In
each, the target acknowledges the four writes into cache, then loses the cache
when the flush arrives:

- **dropConnection**: the connection drops unanswered; the session recovers
  and the flush succeeds on the new connection.
- **unitAttention**: the connection stays up; the flush gets UA 06/29/00, is
  absorbed and retried, and returns GOOD.

Both scenarios end in a power cut, after which the data must still read back.
Each has a negative control: the same fault under a plain write plus flush
reads back zeros, which shows the fault really does destroy data. Two mutation
checks confirm the replay is what saves it:

- with the epoch comparison forced true, all three replay tests lose the data;
- with UA counting disabled, only the UNIT ATTENTION test does.

### Failure semantics and `ioLock`: already true

`DaemonStore.write` holds `ioLock` across the synchronous XPC `write` call, and
on any thrown error it calls `cache.writeFailed` (drops the RAM-cache overlap)
and closes the disk tier's write window. Because the flush runs *inside*
`device.write`, before the XPC reply:

- a failed flush fails the XPC call, so the existing error path drops the range;
- the lock is not released until the flush, and any replay, are done.

Nothing in the extension changed. The rule that keeps it true: **the flush
belongs in the device, never in `DaemonCore` or above.** Moving it to a
separate XPC call would break both properties.

### Target variation

- **SYNCHRONIZE CACHE(10) fallback.** On 05/20/00 (INVALID COMMAND OPERATION
  CODE) for the 16-byte form, the device switches to the 10-byte form for good.
  This also applies to `flush()`, so interval and detach flushes benefit. **The
  2^32-block concern does not arise:** it applies to a *ranged* flush, and this
  one is LBA 0 with zero blocks, which SBC defines as "through the last block"
  whatever the LUN's size. Ranging the flush to the request would buy nothing
  on ZFS, where a flush commits the whole zvol's log either way, and would
  bring the problem back.
- **WCE=0 / VWC=0.** The maintainer's note was that the extra command buys
  nothing there. So the mode sends no flush, but it writes with FUA rather than
  without. **Skipping the flush and writing without FUA was the first version,
  and it was weaker than what ships.** A cache switched on at the target with
  no UNIT ATTENTION to tell us, an admin toggle being the obvious case, would
  have left acknowledged writes volatile. Shipping FUA is immune to that, and
  FUA costs a write-through target nothing. Only a positive "not volatile"
  takes this path. No caching page, or a failed MODE SENSE, counts as volatile.
  The answer is cached per epoch, because a MODE SENSE per request would cost
  the round trip this mode exists to save. A stale answer in either direction
  is now harmless.
- **A target that reports WCE=0 and caches anyway** defeats FUA as well, so
  this mode is no worse there. The same holds for SCST `nv_cache=1` or ZFS
  `sync=disabled`, both of which return GOOD to FUA and to a flush without
  committing.

### Concurrency

Requests are independent. One request's flush covers its own completed writes,
and possibly another request's half-written ones, which does no harm.
`nvme write-bench --queue-depth 2 --flush-per-request` against the simulator
showed 512 uncached writes, 128 flushes and nothing dirty. Overlapping
requests are ordered by `ioLock`, as today. The FUA replay is a late write
of the request's own data, so it relies on that lock too.

**One interaction worth recording.** The replay happens after a reconnect,
which is exactly when open question 8a applies: the extension's fixed 30 s XPC
timeout can fire while the daemon is still recovering. When it does, the
extension reports EIO, drops the cache range and releases `ioLock`, while the
daemon keeps working on the request. Whatever of that request still lands
afterwards, a retried chunk today or the FUA replay under this mode, can land
after a newer write to the same blocks. The hazard is not new, but this mode
adds one more late write in the same window. Fixing 8a (extend the wait while
recovery is in flight) closes both.

## What to expect from it

The lever is narrower than "batch the flushes":

- **Only requests larger than one command change.** FSKit delivers one request
  at a time, so at most `request ÷ maxTransferBytes` commands share a flush:
  four for a 1 MiB request at 256 KiB. Small writes, the 4–64 KiB that dominate
  a running VM and the place FUA hurts most (open question 5), are one command
  each and keep FUA. **This does nothing for them.**
- **On ZFS the cost is per byte.** FUA throughput on our TrueNAS was flat from
  64 KiB to 16 MiB commands (`write-performance-strategies.md`), the signature
  of a ZIL commit per synced byte. A flush per request is still a ZIL commit of
  the same bytes. What it saves is N−1 commit round trips and device cache
  flushes per request, which is about the +11–13% the reporter measured. The
  reporter also saw fewer NAS flushes per GB, consistent with this.
- **A target with a cheap per-command FUA and a cheap flush gains little.** The
  mode pays off where each FUA is a separate expensive commit and a flush can
  coalesce several.

### Measuring it on the NAS

Not yet run: it writes to the target, and the only NVMe/TCP scratch namespace
is name-testing (`ssd-vms` and `seattle-vms` are live VM storage). From a VM on
the storage subnet, against name-testing only:

```sh
swift build -c release --product iscsictl
B=$(swift build -c release --show-bin-path)
for mode in --fua --flush-per-request; do
  $B/iscsictl nvme write-bench 192.168.20.1 --subsystem <name-testing NQN> \
    --chunk 1048576 --max-transfer 262144 --queue-depth 1 --megabytes 2048 $mode
done
```

Depth 1 and 1 MiB is the FSKit shape: one request at a time, four commands
each. Alternate the modes, three runs each, and discard the first run as a
warm-up, as in `performance.md`. The iSCSI equivalent is `iscsictl write-bench
… --chunk 1048576 --max-transfer 262144 --fua | --flush-per-request` against a
scratch LUN.

Simulator numbers say nothing about this: the simulator's FUA is *cheaper* than
its cache (`performance.md`). It was used for the wire counts only: 256 MiB as
1 MiB requests gave 1024 uncached commands, 256 flushes, zero FUA and nothing
dirty afterwards.

## What shipping would still need

1. **Persistence.** A new *optional* `TargetRecord` key, e.g.
   `flushPerRequest: Bool?`, read in `ISCSIXPCService.login` only when
   `flushIntervalSeconds` is nil. It degrades safely in both directions: an
   older daemon ignores the unknown key and writes through with FUA, and an
   older app that re-saves the record drops the key, with the same result. Do
   not encode it in `flushIntervalSeconds`. That field's rule, that a nonsense
   value becomes write-through, is a deliberate guard against hand edits, and
   reusing it would blur the guard.
2. **UI.** A fourth choice in the target editor's durability control, worded
   as "as durable as FUA, faster for large sequential writes, no help for small
   ones". The Sessions pane says "On (FUA on every write)" whenever
   `writeThrough` is true. For this mode that is wrong about the mechanism but
   right about the guarantee. Fixing the label means an optional field on
   `SessionInfo`, gated for older daemons like every 0.7.x addition.
3. **A real power cut** on at least one target, the maintainer's condition for
   anything beyond opt-in. Mocked recovery proves the logic, not the target.
4. **A measurement through FSKit** on a VM, from an RC built by the dry-run
   workflow, to confirm that the raw-bench gain survives the stack.

## Files

- `Sources/iSCSIKit/Session/BlockDevice.swift`: `WriteDurability`,
  `ISCSIBlockDevice.writeFlushingOnce`, epoch, UA counting, WCE cache,
  SYNCHRONIZE CACHE(10) fallback
- `Sources/NVMeKit/Session/NVMeBlockDevice.swift`: the twin
- `Sources/iSCSIKit/Session/Session.swift`, `Sources/NVMeKit/Session/NVMeController.swift`:
  generation counters
- `Sources/iSCSIKit/XPCModels.swift`: `FlushPolicy.flushPerRequest`,
  `durableAtAcknowledgement`
- `Sources/iSCSIDaemon/DaemonCore.swift`: policy → device mode
- `Sources/MockTarget/`: flush failure, SYNCHRONIZE CACHE(16) rejection, cache
  loss at flush (by drop or by UA), WCE=0 and VWC=0 knobs
- `Tests/IntegrationTests/PerRequestFlushTests.swift`: 16 tests across three
  suites
