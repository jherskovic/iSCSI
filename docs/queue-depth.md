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
