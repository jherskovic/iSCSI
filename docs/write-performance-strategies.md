# Strategies for improving write performance

## What the measurements already rule out

Writes average **57.2 MB/s** over the 137 GB benchmark (65 MB/s on a fresh
volume, decaying to 49 MB/s as it fills), against **117 MB/s** with FUA
disabled and a **~98 MB/s** transport ceiling measured on reads.

Three obvious levers are already dead:

| lever | result |
|---|---|
| larger requests | flat 76–78 MB/s from 64 KiB to 16 MiB |
| concurrent streams | 49 → 51 MB/s (4 streams); reads got 23% *worse* |
| CPU / digest cost | `iscsid` at 14% of 4 cores; digests negotiated off entirely |

**The flat response to request size is the important clue.** If FUA cost a fixed
per-command latency, 16 MiB commands would amortise it and be far faster than
64 KiB commands. They are not. So the cost scales with *bytes*, not commands —
which is the signature of ZFS writing every synced byte twice (once to the ZIL,
once to the pool). Concurrency cannot help because the ZIL commit is the
serialisation point, and bigger commands cannot help because the amplification
is per byte.

That reframes the problem. It is not "our writes are slow"; it is **"we ask the
target to synchronously commit every byte we send."**

One honest caveat on the 117 MB/s figure: it exceeds the 98 MB/s read ceiling,
so it is partly absorbed by the target's async write cache and is a burst rate,
not a sustainable one. The true non-FUA sustained rate is probably nearer the
transport limit.

---

## Strategy 1 — Stop FUA-ing every write: TESTED AND FALSIFIED

**Result: `closeItem` is not a barrier. FUA stays.**

The extension was instrumented to log every write, open, close and
synchronize, and a workload issued five `fsync`s four seconds apart so the
correlation would be unambiguous:

```
FSYNC 0 issued at 03:06:21
03:06:21  write off=2807054336 len=16384   rmw=false
03:06:21  write off=2806005760 len=1048576 rmw=false
FSYNC 1 issued at 03:06:25
03:06:25  write off=2808102912 len=16384   rmw=false
03:06:25  write off=2807054336 len=1048576 rmw=false
```

**No `CLOSE keeping=0` follows any fsync.** Across the run there were five such
closes and every one happened at mount time; the only closes during the
workload were `keeping=1`, which retains read access and triggers no flush.

So `fsync` reaches us as ordinary writes and nothing else — the same conclusion
already established for `synchronize`, now confirmed for the close path too.
Had we dropped FUA and relied on close, every fsync'd write would have sat in
the target's volatile write cache indefinitely, which is exactly the durability
hole FUA exists to close.

**Worth testing, and worth not shipping.** The hypothesis was plausible and the
payoff would have been large — it would also have benchmarked beautifully and
lost data on a target power failure.

### Original hypothesis (kept for context)

**Expected gain: large (up to ~117 MB/s burst, likely ~95 MB/s sustained).**
**Risk: durability, if the assumption is wrong. Must be validated first.**

We FUA everything only because FSKit gives no barrier signal. But the extension
*does* receive one observable signal: DiskImages opens the backing file
`modes=3` and closes it with `keeping=0` around I/O batches, and we already
flush there.

If those closes line up with APFS's barriers, then flushing on close gives the
same guarantee at a fraction of the cost: ordinary writes go to the target's
cache at full speed, and each barrier becomes one `SYNCHRONIZE CACHE`.

**This must be proven, not assumed.** The validation does not need a power cut:

1. Instrument the extension to log every write, close, and flush with offsets.
2. Run a workload doing a known number of `fsync`s at known offsets.
3. Check that every `fsync` is followed by a close-with-`keeping=0` before any
   *subsequent* write reaches us.

If closes lag behind barriers, or batches span barriers, the idea is dead and
FUA stays. If they line up, this is by far the biggest available win.

---

## Strategy 2 — Align to the LUN block size: DONE, amplification eliminated

**Result: read-modify-write went from routine to zero.**

The volume now reports the block size measured from the LUN by SCSI READ
CAPACITY at login (4096 on this target) instead of a hardcoded 512. With
tracing on, every write is block-aligned:

```
writes=17  rmw_true=0
```

and a 32 MB workload written in 8 KiB blocks also produced zero. Previously
DiskImages issued 512-granularity I/O against a 4Kn LUN, so a partial write
cost an extra network round trip to read the edge blocks — read 4 KiB, write
4 KiB, to change 512 bytes.

The sequential benchmark cannot see this, being 1 MiB aligned, which is why the
soak's 235,278 read-modify-write patches were the evidence that mattered.

### Original reasoning (kept for context)

**Expected gain: potentially large for small-write workloads; none for the
sequential benchmark. Risk: low.**

The LUN is **4Kn**, but our FSKit volume advertises `blockSize = 512` in
`statfs`, and DiskImages reads the backing file at 512-byte granularity. Every
sub-4 KiB or misaligned write therefore becomes **read 4 KiB + write 4 KiB** in
`DaemonStore` — a network round trip and 8 KiB of traffic to write 512 bytes.

The soak performed **235,278 RMW patches**, so this path is heavily used by
anything that is not large and sequential. The benchmark, being 1 MiB aligned,
never touches it — which is exactly why the benchmark cannot see this cost.

Try: report `blockSize = 4096` (and a 4096 `ioSize` floor) from the volume, so
the layers above align naturally. Cheap to test, and it removes work rather than
deferring it. Measure with a small-random-write workload, not `bench.py`.

---

## Strategy 3 — Trim / UNMAP pass-through: NOT VIABLE

**Status: ruled out. FSKit exposes no discard operation.**

Searching every FSKit header turns up no hole-punch, discard, deallocate or
trim operation anywhere in the volume protocol surface. The only two candidates
are both dead ends:

- `FSItemDeactivationForPreallocatedItems` — described as "a sort of
  trim-on-close behavior", but it only releases space previously obtained via
  `FSVolumePreallocateOperations`. Our single fixed-size file never preallocates.
- `FSVolumeSeekRegionHandler` — read-only sparseness reporting (SEEK_HOLE /
  SEEK_DATA). It answers questions about holes; it cannot create them.

So APFS's trim stops at DiskImages and can never reach the extension. This is
structurally the same gap as the missing barrier signal: FSKit models a
filesystem's *contents*, and the file abstraction it hands an implementation has
no discard verb.

The consequence is worth stating plainly: **on a thin-provisioned zvol, a
Backend A LUN grows monotonically toward fully allocated and never shrinks.**
Reclamation has to happen out of band — recreating the LUN, or a target-side
tool — not through the data path.

*(Retained below for context: what this was intended to address.)*

Writes degraded by 25% as the volume filled and was rewritten. On a
thin-provisioned ZFS zvol that is the expected shape: nothing ever tells the
target that APFS freed blocks, so the zvol grows monotonically toward fully
allocated and the pool's free-space search gets harder.

Nothing in the chain currently passes discards down: the extension implements no
hole-punching hook, so APFS trim stops at DiskImages. Worth checking whether
DiskImages issues `F_PUNCHHOLE` on the backing file — if it does, handling it
and translating to SCSI `UNMAP` (already implemented in the dext work) would
restore steady-state performance.

This is the only strategy that targets the *decay* rather than the peak.

---

## Strategy 4 — Target-side: an SLOG, or a considered `sync` policy

**Expected gain: very large. Risk: none to correctness (SLOG); significant
(`sync=disabled`). Not our code.**

If Strategy 1 fails and FUA must stay, the ZIL is the bottleneck by
construction. A dedicated fast SLOG device on the pool is the standard fix and
would raise synchronous write throughput substantially without weakening any
guarantee.

`zfs set sync=disabled` on the dataset would also remove the penalty entirely
and is a genuine option **only** if the NAS is on a UPS and the owner accepts
the risk — it discards exactly the durability FUA is buying. Worth stating as a
deliberate policy choice rather than a tuning knob.

---

## Strategy 5 — Raise `FirstBurstLength`

**Expected gain: small (~5–8%), and only on the non-FUA path. Risk: none.**

Negotiated: `InitialR2T=No`, `ImmediateData=Yes`, `MaxBurst=1 MiB`,
**`FirstBurst=64 KiB`**. We ask for 256 KiB; the target's smaller value wins
(`numericMin`). So a 1 MiB write sends 64 KiB unsolicited and then waits for an
R2T for the remaining 960 KiB — one extra round trip per megabyte.

Raising `FirstBurstLength` on the target (to 256 KiB or 1 MiB) removes that.
It is target configuration, not code, and the gain only shows once writes are
not already dominated by ZIL commits.

---

## Strategy 6 — Bounded-window async mode (explicit trade, opt-in only)

**Expected gain: large. Risk: bounded data loss. Must never be the default.**

Let writes be cached and issue `SYNCHRONIZE CACHE` on a timer (say every 100 ms)
plus on close. This bounds loss to the window rather than eliminating it, in the
spirit of `commit=` on ext4 or async NFS.

This *is* a durability weakening and should be behind an explicit flag with the
window in its name (`ISCSI_SYNC_INTERVAL_MS`), documented as such. It is listed
because for a scratch or cache LUN it is a perfectly reasonable trade — but it
should be the user's decision, not a default.

---

## Not worth doing

- **Pipelining SCSI commands** — measured, no gain, and it would weaken the RMW
  serialisation. See `performance.md`.
- **Reducing XPC copies** — the stack is at 14% CPU; copies are not the cost.
- **Larger `maxTransferBytes`** — request size demonstrably does not matter.

## Suggested order

1. **Validate Strategy 1** (instrument close-vs-barrier). It is cheap, and its
   outcome decides whether anything else matters.
2. **Strategy 2** (4 KiB alignment) — independent, low risk, helps the workloads
   the benchmark hides.
3. **Strategy 3** (trim) — fixes the decay.
4. **Strategy 4/5** — target-side, needs the NAS owner.
5. **Strategy 6** — only if someone explicitly wants the trade.
