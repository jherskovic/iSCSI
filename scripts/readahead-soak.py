#!/usr/bin/env python3
"""Hunt for readahead serving stale or wrong blocks.

    scripts/readahead-soak.py <path-to-lun0.img> [--seconds 600]

The FSKit extension reads ahead of a sequential stream (see docs/queue-depth.md),
which means it holds blocks that were fetched before the caller asked for them.
That is only safe if every path which could invalidate them does:

  * a write must drop overlapping speculative reads, or a later read serves
    pre-write bytes;
  * a seek must not let a slot fetched for one offset satisfy another;
  * a request size change must not match slots issued for a different size.

Throughput cannot detect any of that, and neither can reading a file back once:
a pure sequential read is exactly the case readahead is built for. So this
interleaves writes and seeks into sequential runs and verifies *every* read.

Each block's contents are a function of (block index, generation), so the
expected bytes are known without storing them. A stale read is a read that
returns a previous generation, which is reported as such rather than as a
generic mismatch — that distinction is the whole diagnosis.

Destructive: it writes over the region it tests. Point it at a scratch LUN.
"""

import argparse
import fcntl
import hashlib
import os
import random
import sys
import time

BLOCK = 256 * 1024          # what FSKit was measured to request
REGION_OFFSET = 12 << 30    # clear of the checksummed region used elsewhere
REGION_BLOCKS = 8192        # 2 GiB


def content(block: int, generation: int) -> bytes:
    """Deterministic, unique per (block, generation), cheap to produce."""
    seed = hashlib.sha256(f"{block}:{generation}".encode()).digest()
    return (seed * (BLOCK // len(seed) + 1))[:BLOCK]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("--seconds", type=int, default=600)
    p.add_argument("--seed", type=int, default=1)
    args = p.parse_args()

    rnd = random.Random(args.seed)
    generation = [0] * REGION_BLOCKS
    stats = {"seq": 0, "rand": 0, "write": 0, "blocks_read": 0, "blocks_written": 0}
    failures = []

    fd = os.open(args.image, os.O_RDWR)
    # Without this the test is worthless, and worthless in a way that looks like
    # a pass: the page cache answers the reads, the extension is never asked for
    # anything, and readahead — the thing under test — does not run. A first
    # attempt reported 104 GB read at 2438 MB/s, twice what the link can carry,
    # with zero mismatches. It had verified the page cache.
    F_NOCACHE = 48
    fcntl.fcntl(fd, F_NOCACHE, 1)

    def write_blocks(start: int, count: int) -> None:
        for i in range(start, min(start + count, REGION_BLOCKS)):
            generation[i] += 1
            os.pwrite(fd, content(i, generation[i]), REGION_OFFSET + i * BLOCK)
            stats["blocks_written"] += 1

    def read_and_check(start: int, count: int) -> None:
        for i in range(start, min(start + count, REGION_BLOCKS)):
            got = os.pread(fd, BLOCK, REGION_OFFSET + i * BLOCK)
            stats["blocks_read"] += 1
            want = content(i, generation[i])
            if got == want:
                continue
            # Which previous generation came back, if any? "Stale generation N"
            # is a readahead invalidation bug; anything else is worse.
            stale = next((g for g in range(generation[i] - 1, -1, -1)
                          if got == content(i, g)), None)
            failures.append(
                f"block {i} (offset {REGION_OFFSET + i * BLOCK}): "
                + (f"STALE, generation {stale} instead of {generation[i]}"
                   if stale is not None else
                   f"WRONG DATA, matches no generation of this block"))
            if len(failures) >= 20:
                raise SystemExit("too many failures; stopping")

    print(f"  laying down {REGION_BLOCKS} blocks ({REGION_BLOCKS * BLOCK >> 20} MiB)")
    write_blocks(0, REGION_BLOCKS)

    print(f"  soaking for {args.seconds}s")
    deadline = time.monotonic() + args.seconds
    last_report = time.monotonic()
    while time.monotonic() < deadline and not failures:
        roll = rnd.random()
        if roll < 0.55:
            # A sequential run: what readahead exists for, and long enough that
            # the window is full well before the run ends.
            start = rnd.randrange(REGION_BLOCKS - 64)
            read_and_check(start, rnd.randint(8, 64))
            stats["seq"] += 1
        elif roll < 0.80:
            # A write in the middle of the region a stream is walking. If
            # invalidation is wrong, the read that follows serves pre-write
            # bytes.
            start = rnd.randrange(REGION_BLOCKS - 16)
            write_blocks(start, rnd.randint(1, 16))
            # Read it straight back: the tightest possible window for a stale
            # slot to survive.
            read_and_check(start, 4)
            stats["write"] += 1
        else:
            # A seek. Slots fetched for the old position must not satisfy this.
            read_and_check(rnd.randrange(REGION_BLOCKS), 1)
            stats["rand"] += 1

        if time.monotonic() - last_report >= 30:
            elapsed = args.seconds - (deadline - time.monotonic())
            mb = stats["blocks_read"] * BLOCK / 1e6
            print(f"    {elapsed:5.0f}s  {stats['seq']} runs, {stats['write']} writes, "
                  f"{stats['rand']} seeks, {mb:.0f} MB read, 0 failures")
            last_report = time.monotonic()

    os.close(fd)

    print(f"  sequential runs {stats['seq']}, writes {stats['write']}, "
          f"seeks {stats['rand']}")
    print(f"  blocks read {stats['blocks_read']}, written {stats['blocks_written']}")
    if failures:
        print(f"\n  {len(failures)} FAILURES:")
        for f in failures:
            print(f"    {f}")
        return 1
    print("  no mismatches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
