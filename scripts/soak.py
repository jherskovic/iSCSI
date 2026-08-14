#!/usr/bin/env python3
"""Backend A soak: sustained mixed I/O with end-to-end verification.

Runs ON the VM against a mounted APFS volume that sits on an iSCSI LUN served
through the FSKit extension. fio is not available there (no Homebrew), and this
targets the paths that actually broke in this project, which fio would not:

  * unaligned, odd-sized writes, to hammer the read-modify-write path in
    DaemonStore -- the alignment bug lived exactly there and was invisible to
    page-cache-aligned access
  * repeated overwrite of the same regions, so a lost RMW update shows up as a
    checksum mismatch rather than silently correct-looking data
  * a mix of block sizes spanning the 4Kn boundary
  * optional memory pressure, because writing dirty pages back *through* a
    userspace filesystem is the classic loopback-deadlock shape

Every file is verified by SHA-256 against locally computed expected content, so
corruption is caught rather than assumed absent.

    soak.py --dir /Users/herko/mnt7 --seconds 900 --workers 4
"""
import argparse
import hashlib
import os
import random
import sys
import threading
import time

STOP = threading.Event()
STATS_LOCK = threading.Lock()
STATS = {"written": 0, "read": 0, "files": 0, "verifies": 0, "errors": 0, "rmw": 0}


def bump(**kw):
    with STATS_LOCK:
        for k, v in kw.items():
            STATS[k] += v


def content(seed: int, size: int) -> bytes:
    """Deterministic pseudo-random content, so expected bytes are reproducible
    without holding them all in memory twice."""
    rnd = random.Random(seed)
    return rnd.randbytes(size)


def worker(idx: int, root: str, seconds: float):
    deadline = time.time() + seconds
    rnd = random.Random(1000 + idx)
    # Include the pid: two soak instances pointed at the same directory would
    # otherwise share file names, overwrite each other, and report the result
    # as data corruption. That happened once and cost real time to diagnose.
    path = os.path.join(root, f"soak-{os.getpid()}-{idx}.bin")

    # Sizes deliberately straddle the 4096-byte LUN block size, including sizes
    # that are not multiples of it, to force read-modify-write.
    sizes = [4096, 8192, 65536, 1 << 20, 512, 1536, 5000, 12345]

    while not STOP.is_set() and time.time() < deadline:
        try:
            size = rnd.choice(sizes)
            seed = rnd.randrange(1 << 30)
            data = content(seed, size)

            # 1) whole-file write + verify
            with open(path, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            bump(written=size, files=1)

            with open(path, "rb") as f:
                got = f.read()
            if hashlib.sha256(got).digest() != hashlib.sha256(data).digest():
                print(f"[w{idx}] MISMATCH whole-file size={size}", flush=True)
                bump(errors=1)
                continue
            bump(read=len(got), verifies=1)

            # 2) unaligned partial overwrite -> exercises RMW, then verify the
            #    whole file so a botched edge block is caught.
            if size > 1024:
                off = rnd.randrange(1, min(size - 512, 4095) or 1)
                patch_len = rnd.choice([1, 7, 511, 513, 1000])
                patch_len = min(patch_len, size - off)
                patch = content(seed ^ 0x5A5A, patch_len)
                with open(path, "r+b") as f:
                    f.seek(off)
                    f.write(patch)
                    f.flush()
                    os.fsync(f.fileno())
                expected = bytearray(data)
                expected[off:off + patch_len] = patch
                bump(written=patch_len, rmw=1)

                with open(path, "rb") as f:
                    got = f.read()
                if got != bytes(expected):
                    print(f"[w{idx}] MISMATCH after RMW off={off} len={patch_len} size={size}",
                          flush=True)
                    bump(errors=1)
                    continue
                bump(read=len(got), verifies=1)
        except Exception as e:  # noqa: BLE001 - a soak must report, not die
            print(f"[w{idx}] ERROR {type(e).__name__}: {e}", flush=True)
            bump(errors=1)
            time.sleep(1)


def pressure(seconds: float, mb: int):
    """Hold a large allocation and keep touching it, so the page cache is under
    pressure while dirty disk-image pages are written back through a userspace
    filesystem."""
    deadline = time.time() + seconds
    try:
        buf = bytearray(mb * 1024 * 1024)
        while not STOP.is_set() and time.time() < deadline:
            for i in range(0, len(buf), 4096):
                buf[i] = (buf[i] + 1) & 0xFF
            time.sleep(0.5)
    except MemoryError:
        print("[pressure] MemoryError, backing off", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--seconds", type=float, default=900)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--pressure-mb", type=int, default=0)
    args = ap.parse_args()

    if not os.path.isdir(args.dir):
        print(f"no such directory: {args.dir}", file=sys.stderr)
        return 2

    print(f"=== soak start dir={args.dir} seconds={args.seconds} workers={args.workers} "
          f"pressureMB={args.pressure_mb}", flush=True)

    threads = [threading.Thread(target=worker, args=(i, args.dir, args.seconds), daemon=True)
               for i in range(args.workers)]
    if args.pressure_mb:
        threads.append(threading.Thread(target=pressure,
                                        args=(args.seconds, args.pressure_mb), daemon=True))
    for t in threads:
        t.start()

    start = time.time()
    last = dict(STATS)
    # Progress every 30s. A stalled line (no byte movement) is the signal that
    # the stack has wedged, which is exactly what this is watching for.
    while any(t.is_alive() for t in threads):
        time.sleep(30)
        with STATS_LOCK:
            now = dict(STATS)
        el = time.time() - start
        dw = (now["written"] - last["written"]) / 30 / 1e6
        dr = (now["read"] - last["read"]) / 30 / 1e6
        print(f"[{el:6.0f}s] write {dw:7.1f} MB/s  read {dr:7.1f} MB/s  "
              f"files={now['files']} rmw={now['rmw']} verified={now['verifies']} "
              f"errors={now['errors']}", flush=True)
        last = now
        if el > args.seconds + 120:
            print("=== overran deadline, stopping", flush=True)
            STOP.set()
            break

    with STATS_LOCK:
        f = dict(STATS)
    el = time.time() - start
    print(f"=== soak done in {el:.0f}s", flush=True)
    print(f"    written={f['written']/1e6:.1f} MB  read={f['read']/1e6:.1f} MB", flush=True)
    print(f"    files={f['files']} rmwPatches={f['rmw']} verifies={f['verifies']} "
          f"errors={f['errors']}", flush=True)
    print("SOAK-PASSED" if f["errors"] == 0 and f["verifies"] > 0 else "SOAK-FAILED", flush=True)
    return 0 if f["errors"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
