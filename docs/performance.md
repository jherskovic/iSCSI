# Backend A performance

All figures from the SIP-off test VM (4 cores, 16 GiB) against the TrueNAS
scratch LUN over the LAN, APFS on the attached disk image.

## Baseline: 137 GB, verified (2026-08-13)

`scripts/bench.py --file-gib 4 --files 8 --rounds 2`, 1 MiB sequential I/O,
SHA-256 verified on read-back, `writeThrough` (FUA) on:

| phase | volume | average |
|---|---|---|
| write | 68.72 GB in 1202 s | **57.2 MB/s** |
| read | 68.72 GB in 764 s | **90.0 MB/s** |
| combined | **137.44 GB** | **69.9 MB/s** |

Zero verify mismatches.

Per-file rates: reads are flat at ~90 MB/s throughout. Writes start at ~65 MB/s
and settle to ~49 MB/s in the second round, i.e. they degrade as the volume
fills and is rewritten — worth remembering when comparing runs, since a short
benchmark on a fresh volume flatters the write number.

## Where the time goes

**The stack is latency-bound, not CPU-bound.** During sustained I/O:

```
iscsid 13.9%   kernel_task 8.3%   iSCSIFSExtension 2.3%   fskitd 1.2%
```

on a 4-core machine — nothing is close to saturated. So throughput is set by
round-trip count and per-command latency, not by processing cost.

At ~57 MB/s with 1 MiB per command that is roughly 15 ms per write, which is
the signature of **FUA forcing a synchronous commit at the target** on every
command. The target confirms a volatile write cache
(`write cache ENABLED` at login), so on ZFS each FUA write is a ZIL commit.

Cost of that durability, same 128 MiB test:

| configuration | write |
|---|---|
| `writeThrough=off` (no FUA) | 117 MB/s |
| `writeThrough=on` (FUA) | 76.9 MB/s |

Disabling FUA is *not* an acceptable optimisation: with no barrier signal from
FSKit (see `backend-a-fskit-notes.md`), FUA is the only thing making an
acknowledged write durable against target power loss.

## Optimisations applied

### CRC32C: 17.4x (done)

The digest covers every byte in both directions. The old implementation was a
byte-at-a-time table loop over a generic `Sequence<UInt8>`, which also defeated
any contiguous fast path. Replaced with the CRC32C instruction (arm64
`__builtin_arm_crc32cd`, x86-64 `_mm_crc32_u64`), 8 bytes per instruction,
slice-by-8 fallback.

Measured over 256 MiB: **8456 MB/s vs 487 MB/s**, identical output.

This did **not** move end-to-end throughput, exactly as the CPU numbers
predicted. It removes a ceiling rather than raising the floor: at 487 MB/s the
digest would have become the limit as soon as concurrency raised the transfer
rate.

## Where the ceiling is

`iscsictl read-bench` reads straight over iSCSI — no FSKit extension, no
DiskImages, no filesystem — which separates our stack from the transport.
Uncached regions, sequential:

| chunk | raw iSCSI read |
|---|---|
| 256 KiB | 85.3 MB/s |
| 1 MiB (what the stack uses) | 94.5 MB/s |
| 4 MiB | 97.8 MB/s |
| 8 MiB | 98.1 MB/s |

The transport plateaus at **~98 MB/s**. End-to-end reads through FSKit,
DiskImages and APFS measure **90.0 MB/s**, so:

- our layers cost about **4.5%** (94.5 → 90.0 at the same 1 MiB chunk),
- and the stack runs at **~92% of the achievable maximum**.

Read cost by layer, same 512 MiB region:

| path | throughput |
|---|---|
| FSKit + daemon (`lun0.img` directly) | 102 MB/s |
| + DiskImages (`/dev/rdisk`) | 97 MB/s |
| + APFS (mounted volume) | 90 MB/s |

(These vary a few percent run to run because the target's ARC caches recently
written blocks — compare only measurements taken against cold regions.)

## Concurrency: measured, and it does not help

Tested directly rather than assumed, because `ISCSIBlockDevice` is an actor and
serialization looked like an obvious culprit:

| workload | 1 stream | 4 concurrent streams |
|---|---|---|
| write, 2048 MiB total | 49 MB/s | 51 MB/s |
| raw read, 1024 MiB total | 146 MB/s | 113 MB/s |

Writes are flat and reads get **23% worse** — parallel streams break the
sequential access pattern the target reads ahead on. Request size makes no
difference either: writes measured 76–78 MB/s at every block size from 64 KiB
to 16 MiB.

**Conclusion: the actor serialization is not the bottleneck, and pipelining
commands would buy nothing.** Rejected on evidence rather than implemented on
intuition — it would have added real risk (reordering, weakened RMW
serialization) for no measurable gain.

**Half of that is superseded — see the next section.** The measurement above is
sound and the conclusion drawn from it was too broad. Four independent *streams*
is not the same experiment as the chunks of *one* request going out together,
and the two results point opposite ways for a reason worth understanding.

## Splitting one write across concurrent commands: 2.1-2.6x (2026-08-17)

`ISCSIBlockDevice.read` has pipelined the chunks of a single request since the
readahead work. `write` sat three lines below it issuing the same kind of chunks
one at a time, paying a full round trip each. Making it match:

| mode | serial | pipelined | gain |
|---|---|---|---|
| FUA (what ships) | 53.7 / 58.6 / 57.8 -> **56.7** MB/s | 121.6 / 117.0 / 117.2 -> **118.6** | **2.09x** |
| cached | 329.8 / 321.5 / 306.1 -> **319.1** MB/s | 809.3 / 816.2 / 820.8 -> **815.4** | **2.56x** |

512 MiB per pass, 1 MiB requests split into four 256 KiB commands, against
`iscsi-driver-testing`. Interleaved A/B/A/B in one session, per the rule in
`open-questions`: the spread within each arm is 9% and 7%, an order below the
gap, and the worst pipelined run still beats the best serial one 2.00x and
2.45x. The pipelined arm is also the *steadier* of the two (1.4% spread in
cached mode against 7.4%), which is not what noise looks like.

**Why this does not contradict the section above.** Four concurrent streams
write four unrelated LBA regions and destroy the sequential pattern the array
reads ahead on — measured flat for writes and 23% *worse* for reads. Four
concurrent chunks of one request are contiguous by construction: the same
sequential run, in the same order, with the round-trip stall between commands
removed. One scatters the access pattern; the other only stops waiting. The
earlier experiment answered "should separate operations overlap" (no) and was
read as answering "should one operation be split" (which it never tested).

Correctness on hardware, not just throughput: `iscsictl verify --write --blocks
2048` round-trips 1 MiB — four concurrent commands — byte-exact at LBA 262144.

Note the FUA multiple is roughly preserved, 5.6x before and 6.9x after, so this
does not touch the trade in item 5 of `open-questions`; it makes both sides of
it faster.

## What is actually limiting each direction

- **Reads** are transport-bound at ~98 MB/s.
- **Writes** are target-bound. FUA makes each write a synchronous commit, and
  the target confirms a volatile write cache; on ZFS that is a ZIL commit per
  command, which is why writes neither scale with concurrency nor improve with
  larger requests. The fix is target-side (an SLOG device), not initiator-side.

Remaining initiator-side headroom is roughly 3.5% — the gap between 1 MiB and
4 MiB chunks — and it is not reachable without raising the FSKit volume's
reported `ioSize` and rebuilding the extension. Not worth it for 3.5%.

## Loopback: what the stack costs with no network in the way (2026-08-14)

Every number above was bounded by the LAN. `iscsi-target-sim` running beside the
initiator removes that, so what remains is our own per-command cost — and the
target's negotiation parameters are finally ours to change. RAM-backed LUN,
4 KiB blocks, 1 MiB commands, 1 GiB per run, digests off.

| FirstBurstLength | write | write + FUA | read |
|---|---|---|---|
| 64 KiB (what the NAS allows) | 869 MB/s | 959 MB/s | 2428 MB/s |
| 256 KiB | 958 MB/s | 1054 MB/s | 2440 MB/s |
| 1 MiB | 1055 MB/s | **1196 MB/s** | 2439 MB/s |

**Reads cost us almost nothing.** 2.4 GB/s here against 94.5 MB/s over the LAN:
the transport was ~96% of the read cost, which retires any suspicion that the
read path needed work.

**FirstBurstLength is worth 25% on writes** (959 → 1196 MB/s), and reads are
flat because they never involve R2T. This was Strategy 5, previously untestable
because it is the *target's* setting.

### We were the binding constraint

The first sweep negotiated 256 KiB even when the simulator offered a full
megabyte. `FirstBurstLength` folds by `numericMin`, and our own
`DesiredParameters.firstBurstLength` was 256 KiB — so raising the target's
value past that did nothing. It now asks for `1 << 20`, matching
`maxBurstLength`, which is what unlocks the 1054 → 1196 MB/s step.

The fold makes this safe: a target that cannot buffer a megabyte per command
answers with less and we honour it. **On the real NAS this changes nothing** —
it caps FirstBurstLength at 64 KiB, so the extra R2T round trip per megabyte
stays. The gain is available to targets that allow more.

Verified rather than assumed, because a throughput number alone would not have
caught a `bufferOffset` off-by-one in the unsolicited tail — writes would have
corrupted every megabyte at the same reported rate. Three integration tests
round-trip 2–4 MiB byte-exact at a negotiated 1 MiB first burst (fully
unsolicited, unsolicited-plus-R2T, and with an 8 KiB immediate segment so the
tail carries the most Data-Out PDUs), each asserting the negotiated value first
so it cannot pass while exercising the old 64 KiB shape. The full Backend A
stack was then re-run through the daemon at `FIRSTBURST=1048576`: baseline,
drop and crash all pass, `fsck_apfs` clean.

### One number here is a simulator artifact

FUA measures *faster* than non-FUA (1196 vs 1055 MB/s), which is backwards. It
is an artifact of the simulator's cache: a non-FUA write is stored as
per-block dictionary entries (256 inserts per MiB) while a FUA write is a
single copy straight to the backing store, so "caching" costs more than
"committing". Nothing about FUA being cheap should be read from this table —
the honest measurement of FUA's cost is the LAN one above (~1.5× on large
sequential, ~2.5× on small writes), where a real target really does commit.

## Hot-loop audit (2026-08-14)

Looked for byte-at-a-time work and avoidable copies on the data path.

**Already clean:** the PDU codec and framer operate on `Data` slices via the
slice-tolerant helpers in `Support/Endian.swift`, not by iterating bytes; the
receive loop feeds the deframer whole chunks from the transport;
`ISCSIBlockDevice.read` preallocates its output. The only per-byte loops in the
library are in IQN validation and trace formatting, neither of which is on the
data path.

**Two real costs found and removed, both per-PDU:**

1. `PDUSerializer.serialize` built `raw.data + padding` solely to compute a
   four-byte data digest — allocating and copying the whole data segment, up to
   a megabyte per PDU. Now chains the digest over the segment and its padding
   with `CRC32C.update`/`finalize`, with no copy.

2. `PDUDeframer.next` consumed each PDU with `buffer.removeFirst(total)`, which
   memmoves everything still buffered. That is quadratic when one read delivers
   many PDUs — the normal case on a fast link. Now advances a `consumed` index
   (O(1)) and reclaims the dead prefix in one memmove once it passes 64 KiB or
   half the buffer.

Both are correctness-neutral. The index change touches every offset in `next()`
including the digest verification, where an off-by-one would corrupt every PDU
after the first, so four tests cover multi-PDU appends, repeated compactions,
split PDUs with partial tails, and digest checks on later PDUs.

**Not worth vectorising.** CRC32C is the only genuine bulk-byte computation in
the stack and already uses the hardware instruction (8.4 GB/s). Everything else
that touches large buffers is a copy, where `memcpy` is already optimal, or a
network round trip, where the CPU is idle — `iscsid` sits at ~14% of four cores
under sustained load. There is no remaining loop where SIMD would pay.


## Post-optimisation re-benchmark (2026-08-14)

Same 137 GB run after the CRC32C, framer, and block-alignment work:

| phase | before | after |
|---|---|---|
| write | 57.2 MB/s | 56.6 MB/s |
| read | 90.0 MB/s | 90.6 MB/s |
| combined | 69.9 MB/s | 69.6 MB/s |

**No change, and that is the expected result.** This benchmark is 1 MiB
aligned, so it has no read-modify-write to eliminate; digests are negotiated
off, so CRC32C never runs; and the stack is latency-bound at ~14% CPU, so
cheaper framing frees capacity that was not the constraint. The optimisations
are real but invisible to this workload — which is the argument for keeping a
small-write soak alongside a sequential benchmark.

### Cost of FUA on small writes

The soak (4 workers, unaligned partial overwrites, 3 GB memory pressure) shows
the durability cost far more sharply than the sequential benchmark does:

| configuration | soak write | soak read |
|---|---|---|
| `writeThrough=on` (FUA) | 12–14 MB/s | 25–28 MB/s |
| `writeThrough=off` | ~31 MB/s | ~62 MB/s |

Roughly **2.5x**, against ~1.5x for large sequential writes. That follows from
the earlier finding that the cost scales with synced bytes rather than commands:
small writes pay a full commit for very little data.

This is the price of durability on a target with a volatile write cache, and it
is why the shipping default stays `writeThrough=on`.

### A false alarm worth recording

One soak run reported 13,267 verification mismatches, which looked like data
corruption. It was not: a previously backgrounded command had failed its mount
step but still launched a second `soak.py` against the same directory, and both
instances write the same fixed file names (`soak-0.bin` … `soak-3.bin`). Each
was reading back the other's data.

Confirmed by elimination: single-threaded clean (0/200), 4 threads clean
(0/600), soak without memory pressure clean (26,231 verifies), and the identical
failing configuration re-run with one instance clean (51,116 verifies). No
double mount was involved — the logs show exactly one `mount-complete` for the
volume.

Lesson for the harness: `soak.py` should use per-process unique file names so a
stray instance collides visibly rather than looking like corruption.
