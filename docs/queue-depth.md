# Queue depth, and why more connections were never the answer

Measured 2026-08-16 against `iqn.me.herko.planet-express:iscsi-driver-testing`
on a TrueNAS box over 10GbE (MTU 1500, no jumbo frames), 1 MiB chunks, no
digests, `MaxBurstLength` 1 MiB.

## The finding

A single connection reaches line rate. What it needed was more than one command
in flight at a time.

| queue depth | throughput |
|---:|---:|
| 1 | ~385 MB/s |
| 2 | ~1135 MB/s |
| 4 | ~1160 MB/s |
| 8 | ~1160 MB/s |
| 16 | ~1155 MB/s |

1160 MB/s is about 93% of a 10 Gb link. There is nothing left for a second
connection to win, so MC/S is not worth building.

This also explains the note in the README that multiple streams "conferred zero
speed benefits". They would. The caller issued one read, waited for it, then
issued the next, so every connection after the first sat idle waiting for the
same round trip. The connection was never the constraint — the number of
outstanding commands was.

At queue depth 1 the transfer size is the only lever, which is why throughput
climbed with chunk size (189 MB/s at 256 KiB, 349 at 1 MiB, 543 at 4 MiB): the
per-command latency of roughly 0.85 ms is paid whatever the size, and with one
command outstanding the link is idle for all of it.

## The protocol layer already did this

Nothing needed changing to make pipelining work. `ISCSIConnection.execute`
allocates an ITT, parks the caller in `pendingTasks` and suspends — which
releases the actor — and the CmdSN window bounds what the target has agreed to
accept. `read-bench --queue-depth N` keeps N reads outstanding with a sliding
window, and that alone produced the table above.

## Two measurement traps, both of which caught me

**Unwritten LUN regions are not storage.** The first sweep read regions the LUN
had never had written to it, and reported 1167 MB/s at queue depth 4 with a
clean saturation knee. The target was synthesising zeros without touching disk.
Benchmark a region that has had real data written to it, or the numbers describe
the target's ability to invent zeros.

**Zeros are not data.** `dd if=/dev/zero` then reading it back reported 25
GB/s — twenty times line rate — because APFS stores an all-zero file as a hole
and never asks the device for anything. Write incompressible data
(`os.urandom`), or measure nothing.

Both produced confident, plausible, wrong numbers. Neither failed loudly.

## Open: an intermittent collapse

Runs are bimodal. Most land at ~1155 MB/s; a minority collapse to ~330 MB/s,
which is close to the queue-depth-1 rate, as though pipelining stopped happening
for that run. First seen at queue depth 16 and reproducible three times, then on
a later sweep queue depth 16 was clean and 24 and 32 collapsed instead — so it
is not tied to a depth.

One suspect is in `ISCSIConnection.updateWindow`, which wakes *every* waiter
whenever `MaxCmdSN` advances, however little it advanced by. Waiters that find
the window still closed re-queue, so a window that opens one slot at a time
costs O(waiters) wakeups per slot. That would be a thundering herd, but it does
not obviously explain why the collapse is intermittent rather than worsening
with depth, so it is a suspect and not a conclusion.

Worth chasing before tuning anything else: a 3.5x cliff that lands at random is
worth more than the last 7% of line rate.

## Not measured: the shipping path

Everything above is `iscsictl`, which talks to the target directly. Whether the
FSKit path benefits depends on whether FSKit and DiskImages issue concurrent
reads to the extension, and if they do not, the queue stays at depth 1 no matter
what the layers below support. That needs measuring before any of this reaches
a user.

`fsync` does not help measure it: the extension gets no barrier signal (see the
header of `iSCSIFSExtension.swift`), so a write that returns has not necessarily
reached the target, and with 128 GB of RAM a 24 GiB file is still comfortably a
cache measurement.

## Measured: the shipping path is serial

Reading the extension-served `lun0.img` directly — no APFS, no DiskImages, and
from a freshly mounted volume so the page cache is empty:

    FSKit path: 1074 MB in 5.21s = 206 MB/s

with the interface counters agreeing (196–253 MB/s inbound throughout). So the
answer to the open question above is that FSKit does **not** issue concurrent
reads. The whole product runs at queue depth 1.

206 MB/s is worse than the 385 MB/s that `iscsictl` gets at queue depth 1,
because the extension adds an XPC round trip per read on top of the SCSI one.
Against the 1160 MB/s the link demonstrably supports, that is a 5.6x gap, and
none of it needs a second connection to close.

The extension does not cause the serialisation: `DaemonStore.read` takes no
lock, and its `ioLock` is held only by `write`, for read-modify-write. Requests
arrive one at a time from above.

Which makes readahead the fix. FSKit hands down one sequential read at a time
and waits for each, so the only way to get commands in flight is for the
extension to ask for data before it is asked for it.

## What readahead actually bought

Measured through the FSKit path, reading `lun0.img` from a freshly mounted
volume, checksum verified identical every time:

| build | readahead | throughput |
|---|---|---:|
| 0.3.6 | none | 219.7 MB/s |
| 0.3.7 b13 | fixed 4 slots | 391.5 MB/s |
| 0.3.7 b14 | 4 MiB budget (16 slots) | 636.2 MB/s |
| 0.3.7 b15 | 8 MiB budget (32 slots) | 1099.0 MB/s |

1099 MB/s is 94% of the 1165 MB/s the same target and link sustain from
`iscsictl`, and 5.0x the unmodified path. Each step was predicted from the
previous one's arithmetic rather than guessed: b13's number identified the
request size, b14's identified the XPC round trip, and b15 covered it.

Worth stopping there. What remains is the last 6% plus whatever the target has
in it, and more slots costs memory and moves closer to the command-size cliff
below for nothing.

Correctness was checked at every step by reading a known 256 MiB region and
comparing SHA-256 against the same read through the unmodified build. It
matched every time. That checks the pattern readahead optimises — a pure
sequential read — and does *not* exercise interleaved writes invalidating
slots, or seeks mid-stream. Those are argued correct in the code and have not
been measured.

The fixed-4 number is what confirmed the request size: 391.5 MB/s through the
extension against 393.4 MB/s for the raw path at queue depth 4 with 256 KiB
commands — near enough identical, and the raw path was told what size to use.
So FSKit asks in 256 KiB pieces, and counting requests rather than bytes was
filling the pipe to a quarter of what it wanted.

## The collapse is about command size, not depth

The bimodal cliff turned out to be reproducible once the target was given time
to settle between runs, and it does not track queue depth or bytes outstanding:

| commands | outstanding | throughput |
|---|---|---:|
| 16 x 1 MiB | 16 MiB | 340 MB/s |
| 64 x 256 KiB | 16 MiB | 1169 MB/s |

Same bytes in flight, opposite result. Nothing degrades at 256 KiB out to 64
outstanding; 1 MiB commands fall off a cliff somewhere between 8 and 16. 1 MiB
is exactly the negotiated `MaxBurstLength`, which is suggestive and not yet
explained.

Two consequences. The `updateWindow` thundering-herd theory above is probably
wrong — that would scale with the number of waiters, not the size of each
command. And **1 MiB is the wrong default command size for this initiator**:
`ISCSIBlockDevice` uses `maxTransferBytes: 1 << 20` and `iscsictl` defaults to
it, where 256 KiB reaches the same 1165 MB/s with no cliff at any depth tested.

## Writes are not a queue-depth problem

| | throughput |
|---|---:|
| raw, no FUA | 336.5 MB/s |
| raw, FUA | 74.8 MB/s |
| through FSKit | ~87 MB/s |

Every write carries FUA, deliberately: FSKit sends no barrier, so the daemon
cannot know when the filesystem above wanted a flush, and an acknowledged write
that is still in a volatile target cache is a lie APFS will act on. The comment
at `DaemonCore.login` says so. The cost is now measured rather than assumed:
4.5x.

No amount of pipelining recovers it, because buffering writes to get depth is
exactly the durability hole FUA exists to close. Writes get faster when FSKit
provides a barrier, or when the target's cache is battery-backed and the user
says so — not before.
