#!/usr/bin/env python3
"""Crash-consistency test for Backend A.

The property under test: data that was written and fsync'd before an abrupt
power loss must still be there, and the filesystem must still be consistent,
after the machine comes back.

This matters here specifically because FSKit signals no barriers. APFS issues
barriers to the disk image believing they are honoured, but nothing below the
image ever learns about them, so durability rests on the daemon's write policy
(FUA write-through) rather than on flushes. That is an assumption, and this
tests it rather than asserting it.

Two phases, with a real power cut in between — `utmctl stop --force` from the
host, not a clean shutdown:

    # before the cut
    crash-consistency.py prepare --dir /Users/herko/mnt7 --manifest /tmp/m.json
    # ... host force-kills the VM, reboots, remounts ...
    crash-consistency.py verify  --dir /Users/herko/mnt7 --manifest /tmp/m.json

File contents are generated from a seed, so the manifest holds only seeds and
sizes. It must be copied OFF the LUN before the cut — verifying against a
manifest that lived on the volume under test would prove nothing.
"""
import argparse
import fcntl
import hashlib
import json
import os
import random
import sys


def content(seed: int, size: int) -> bytes:
    return random.Random(seed).randbytes(size)


def full_fsync(fd: int) -> None:
    """Make fd's data durable the way macOS defines durable.

    On macOS fsync(2) only hands the data to the drive, which may hold it in a
    volatile cache; F_FULLFSYNC is the call that asks the drive to flush, and
    it is what this test claims to have done before the power cut. Plain fsync
    where F_FULLFSYNC does not exist (Linux), where fsync already means it.
    """
    if hasattr(fcntl, "F_FULLFSYNC"):
        fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
    else:
        os.fsync(fd)


def prepare(directory: str, manifest_path: str, count: int, size: int) -> int:
    if count < 1:
        print("PREPARE-FAILED: --count must be at least 1; an empty run proves nothing")
        return 1
    os.makedirs(directory, exist_ok=True)
    entries = []
    for i in range(count):
        seed = 900000 + i
        data = content(seed, size)
        path = os.path.join(directory, f"durable-{i}.bin")
        # Write, flush, and fully sync each file individually: after
        # F_FULLFSYNC returns, the data is required to survive a power cut.
        with open(path, "wb") as f:
            f.write(data)
            f.flush()
            full_fsync(f.fileno())
        entries.append({
            "path": path,
            "seed": seed,
            "size": size,
            "sha256": hashlib.sha256(data).hexdigest(),
        })

    # Also sync the directory, so the *names* are durable, not just contents.
    dfd = os.open(directory, os.O_RDONLY)
    try:
        full_fsync(dfd)
    finally:
        os.close(dfd)
    os.sync()

    with open(manifest_path, "w") as f:
        json.dump({"dir": directory, "entries": entries}, f, indent=1)
    print(f"PREPARED {len(entries)} files of {size} bytes, manifest={manifest_path}")
    print("MANIFEST-READY")
    return 0


def verify(directory: str, manifest_path: str) -> int:
    with open(manifest_path) as f:
        manifest = json.load(f)

    # An empty manifest verifies vacuously: zero missing, zero corrupt, and a
    # PASSED line for a run that checked nothing. Typically a prepare that
    # never ran, or a manifest from somewhere else.
    if not manifest.get("entries"):
        print(f"CRASH-CONSISTENCY-FAILED: {manifest_path} lists no files, so nothing was verified")
        return 1

    missing = corrupt = ok = 0
    for e in manifest["entries"]:
        path = e["path"]
        if not os.path.exists(path):
            print(f"MISSING {path}")
            missing += 1
            continue
        with open(path, "rb") as f:
            got = f.read()
        if hashlib.sha256(got).hexdigest() != e["sha256"]:
            print(f"CORRUPT {path} (size {len(got)} vs {e['size']})")
            corrupt += 1
        else:
            ok += 1

    total = len(manifest["entries"])
    print(f"=== verified {ok}/{total} intact, {missing} missing, {corrupt} corrupt")
    # Both failures are real, and they mean different things: missing files mean
    # fsync'd data or its directory entry did not survive; corrupt files mean it
    # survived partially, which is the worse outcome for a filesystem that
    # believed its barriers were honoured.
    if missing == 0 and corrupt == 0:
        print("CRASH-CONSISTENCY-PASSED")
        return 0
    print("CRASH-CONSISTENCY-FAILED")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", choices=["prepare", "verify"])
    ap.add_argument("--dir", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--count", type=int, default=64)
    ap.add_argument("--size", type=int, default=1 << 20)
    args = ap.parse_args()

    if args.phase == "prepare":
        return prepare(args.dir, args.manifest, args.count, args.size)
    return verify(args.dir, args.manifest)


if __name__ == "__main__":
    sys.exit(main())
