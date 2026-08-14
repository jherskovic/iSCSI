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

## Next lever: concurrency

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
