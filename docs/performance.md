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

## What is actually limiting each direction

- **Reads** are transport-bound at ~98 MB/s.
- **Writes** are target-bound. FUA makes each write a synchronous commit, and
  the target confirms a volatile write cache; on ZFS that is a ZIL commit per
  command, which is why writes neither scale with concurrency nor improve with
  larger requests. The fix is target-side (an SLOG device), not initiator-side.

Remaining initiator-side headroom is roughly 3.5% — the gap between 1 MiB and
4 MiB chunks — and it is not reachable without raising the FSKit volume's
reported `ioSize` and rebuilding the extension. Not worth it for 3.5%.

`ISCSIBlockDevice` is a Swift `actor`, so every read and write for a session is
serialized. Combined with a ~15 ms FUA commit, that puts a hard ceiling on
writes regardless of link speed: one command at a time, each waiting for a full
commit.

iSCSI allows many outstanding commands (the CmdSN window). Pipelining them
should raise write throughput substantially without touching durability — each
command still carries FUA, so each is still durable when acknowledged.

Care needed: concurrency must not reorder writes in a way that breaks the
guarantees above, and must not weaken the read-modify-write serialization in
`DaemonStore` that protects partial-block updates.

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
