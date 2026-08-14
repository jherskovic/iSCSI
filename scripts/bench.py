#!/usr/bin/env python3
"""Backend A throughput benchmark: large sequential I/O with verification.

Complements soak.py, which is deliberately small-file and read-modify-write
heavy (latency-bound, aimed at correctness). This is the throughput case:
large sequential transfers at the stack's maximum I/O size, which is what
"transmission speed" for a network disk actually means.

Integrity is still checked — a fast wrong answer is not an improvement — but
with a rolling SHA-256 computed while streaming, so verification does not
require holding gigabytes in memory.

    bench.py --dir /Users/herko/mnt7 --file-gib 4 --files 8 --rounds 2

Reports per-phase and overall averages. Total bytes moved = 2 x file-gib x
files x rounds (each byte is written once and read once).
"""
import argparse
import hashlib
import os
import sys
import time

CHUNK = 1 << 20  # 1 MiB: the stack's max I/O size, so this is the best case


def pattern(block_index: int) -> bytes:
    """A cheap, non-compressible-ish 1 MiB block that varies per index.

    Deliberately not os.urandom per block: at these volumes the RNG becomes the
    bottleneck and would be measured instead of the storage path.
    """
    seed = (block_index * 2654435761) & 0xFFFFFFFF
    base = seed.to_bytes(4, "little") * (CHUNK // 4)
    return base


def write_file(path: str, size: int) -> tuple[float, str]:
    h = hashlib.sha256()
    start = time.time()
    with open(path, "wb", buffering=0) as f:
        written = 0
        i = 0
        while written < size:
            blk = pattern(i)[: min(CHUNK, size - written)]
            f.write(blk)
            h.update(blk)
            written += len(blk)
            i += 1
        f.flush()
        os.fsync(f.fileno())
    return time.time() - start, h.hexdigest()


def read_file(path: str) -> tuple[float, str, int]:
    h = hashlib.sha256()
    start = time.time()
    total = 0
    with open(path, "rb", buffering=0) as f:
        while True:
            blk = f.read(CHUNK)
            if not blk:
                break
            h.update(blk)
            total += len(blk)
    return time.time() - start, h.hexdigest(), total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--file-gib", type=float, default=4.0)
    ap.add_argument("--files", type=int, default=8)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--keep", action="store_true", help="do not delete files between rounds")
    args = ap.parse_args()

    size = int(args.file_gib * (1 << 30))
    w_bytes = w_time = r_bytes = r_time = 0.0
    mismatches = 0

    print(f"=== bench dir={args.dir} file={args.file_gib} GiB x{args.files} "
          f"rounds={args.rounds} chunk={CHUNK//1024} KiB", flush=True)

    for rnd in range(args.rounds):
        digests = {}
        for i in range(args.files):
            path = os.path.join(args.dir, f"bench-{i}.bin")
            dt, dg = write_file(path, size)
            digests[path] = dg
            w_bytes += size
            w_time += dt
            print(f"[r{rnd} w{i}] {size/1e9:.2f} GB in {dt:6.2f}s = "
                  f"{size/dt/1e6:7.1f} MB/s", flush=True)

        os.sync()

        for i in range(args.files):
            path = os.path.join(args.dir, f"bench-{i}.bin")
            dt, dg, total = read_file(path)
            r_bytes += total
            r_time += dt
            ok = dg == digests[path]
            if not ok:
                mismatches += 1
            print(f"[r{rnd} r{i}] {total/1e9:.2f} GB in {dt:6.2f}s = "
                  f"{total/dt/1e6:7.1f} MB/s  verify={'OK' if ok else 'MISMATCH'}", flush=True)

        if not args.keep:
            for i in range(args.files):
                try:
                    os.remove(os.path.join(args.dir, f"bench-{i}.bin"))
                except FileNotFoundError:
                    pass

    total_bytes = w_bytes + r_bytes
    print("=== RESULTS", flush=True)
    print(f"    wrote {w_bytes/1e9:8.2f} GB in {w_time:7.1f}s = {w_bytes/w_time/1e6:7.1f} MB/s avg",
          flush=True)
    print(f"    read  {r_bytes/1e9:8.2f} GB in {r_time:7.1f}s = {r_bytes/r_time/1e6:7.1f} MB/s avg",
          flush=True)
    print(f"    total {total_bytes/1e9:8.2f} GB moved, "
          f"combined avg {total_bytes/(w_time+r_time)/1e6:7.1f} MB/s", flush=True)
    print(f"    verify mismatches: {mismatches}", flush=True)
    print("BENCH-PASSED" if mismatches == 0 else "BENCH-FAILED", flush=True)
    return 0 if mismatches == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
