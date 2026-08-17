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

## The soak

`scripts/readahead-soak.py`, 30 minutes against the 10GbE target, page cache
bypassed with `F_NOCACHE` so every read reaches the extension:

    sequential runs 9532, writes 4321, seeks 3389
    blocks read 362981, written 45261
    no mismatches

Every read verified, not just the last one. The writes are each read straight
back, which is the tightest window a stale slot has to survive in; the seeks
land at random offsets, so slots fetched for the previous position must not
satisfy them.

This is what moves the invalidation and seek paths from argued-correct to
measured-correct. The checksum tests before it only ever exercised a pure
sequential read, which is the case readahead is built for and therefore the
case least likely to expose it.

Two ways this test lied before it worked, both worth remembering because both
looked like passes:

Its first run reported 104 GB read at 2438 MB/s with zero mismatches — twice
what the link can carry. The page cache was answering every read and the
extension was never consulted. That is the third time in this investigation a
cache produced a confident wrong number; the others are recorded above.

And it had never failed, which is not the same as being able to. A deliberately
planted stale block is detected and named: "STALE, generation 3 instead of 5".

## Correction: FSKit asks for 1 MiB, not 256 KiB

Once the extension reported its own numbers, the request size turned out to be
1 MiB:

    reads=81/84934656B req=1048576B depth=8 readahead=97% (79 hit, 2 miss, 0 unanswered)

84934656 / 81 = 1048575 bytes per read. Every "256 KiB" statement above about
what FSKit requests is wrong.

The inference that produced it: build 13, with readahead fixed at four slots,
reached 391.5 MB/s, and the raw path at queue depth 4 with 256 KiB commands
reached 393.4 MB/s. Two numbers within half a percent of each other, from a
model that predicted them. It was a coincidence, and it was treated as
confirmation because it was the answer being looked for.

What survives is the reasoning that mattered, which never depended on the
number being 256 KiB: counting requests rather than bytes under-fills the pipe
whenever the request size differs from what the budget was tuned against, and a
budget in bytes is right either way. What does not survive is the specific
figure, and the tidiness of the story that produced it.

The measured configuration is now: 1 MiB requests, an 8 MiB budget giving depth
8, and a 97% hit rate. Depth 8 at 1 MiB sits directly on the edge of the cliff
above — 8 was fine at 1164 MB/s and 16 collapsed to 340 — which the byte budget
happens to land on correctly rather than by design. The 256 KiB
`maxTransferBytes` cap is what actually removes the risk: each 1 MiB request is
now split into four concurrent 256 KiB commands, so the SCSI layer never issues
a command the cliff applies to.

Reading a number beats deriving one. This whole section exists because the
extension was not asked what it was doing until after every conclusion had been
drawn.

## Correction to the correction: the request size is the caller's

"FSKit asks for 1 MiB" was measured while a Python loop read in 1 MiB pieces.
The soak, whose reads are 256 KiB, produced `avgReq=260735B` on the same
extension; a second volume in the same window averaged 978 KB. FSKit passes the
caller's request size down rather than imposing one of its own.

So both the original 256 KiB claim and its 1 MiB correction were the same
mistake made twice: reading one workload's number as a property of the layer.
There is no fixed request size to design against, which is exactly why the
readahead window is budgeted in bytes. A window counted in requests would be
right for whichever workload it was tuned on and wrong for the next.

## What the soak measured, and what it did not

30 minutes against build 16, page cache bypassed, every read verified:

    sequential runs 2632, writes 1205, seeks 999
    blocks read 99694, written 18600
    no mismatches

with the extension reporting `readahead=92% (88242 hit, 6658 miss, 0
unanswered)` over 24.7 GB. The invalidation-on-write and seek paths are
measured under real load, not argued.

It did **not** exercise concurrent chunk splitting. The soak reads in 256 KiB
blocks and `maxTransferBytes` is 256 KiB, so every request is exactly one SCSI
command and `read()` never takes its multi-chunk path. That path remains
verified only against MockTarget, where completions may well arrive in order —
which is precisely the condition the reassembly-by-index logic exists to
survive. Re-running the soak with a 1 MiB block size would cover it.

## The split path, verified against real hardware

The earlier soak could not exercise concurrent chunk splitting: its 256 KiB
reads equalled `maxTransferBytes`, so every request was one command. Re-run at
1 MiB:

    sequential runs 2801, writes 1234, seeks 1015
    blocks read 105710, written 12608
    no mismatches

and the extension's own accounting for the same run:

    reads=195475/130188771840B writes=17487/17858969600B
    readahead=92% (181069 hit, 14406 miss, 0 unanswered)

130.2 GB over 195,475 requests averaging 650 KiB — against a 256 KiB command
cap, that is ~2.5 SCSI commands per request, issued together and reassembled by
index. Every one verified. Reassembly ordering is no longer resting on
MockTarget, whose in-memory pipe may well complete in order and so cannot test
the condition the index exists for.

The 92% hit rate is what the workload implies rather than a shortfall: a quarter
of the operations are writes, which discard the window, and a fifth are seeks,
which break the stream. Zero unanswered across 195k requests is the number that
says the daemon kept up.

One more measurement of request size, and the last needed to settle the point.
The soak reads and writes in 1 MiB units, and the extension saw writes arrive at
990 KiB average but reads at 552-650 KiB: something above splits reads and
passes writes through whole. Combined with the 256 KiB and 953 KiB averages seen
from other workloads, the request size is not a property of FSKit to be designed
against. It is whatever the caller and the layers above happen to produce, which
is why the readahead window is budgeted in bytes and computed per request.

## The window is now earned, not granted

Everything above measured pure sequential streams, and for those the window
opened at full depth as soon as two consecutive reads were consecutive. Hosting
VM images exposed the cost side, which none of the numbers above could see:
guest I/O is short sequential bursts that jump, and each burst tripped the
trigger, opened the whole window, and then jumped — stranding up to 8 MiB of
speculative reads that cannot be recalled once issued. The daemon and target
execute them to completion anyway, queued in front of the I/O that is real.
Worse, a write emptied the slot map without resetting the stream, so the next
read of a continuing run looked sequential and re-issued the entire window on
top of its still-running orphans: every write interleaved into a sequential run
could double the window's traffic. Subjectively, a sluggish VM; on the wire,
milliseconds of stale speculation ahead of every real request.

So depth is now earned exponentially (`ReadaheadPolicy`, unit-tested in
iSCSIKit): nothing until a run has been consecutive for 256 KiB, then 2 slots,
4, 8, … up to the same byte budget and slot cap as before. Any out-of-sequence
read resets the ramp and the gate, and a write forgets the stream entirely —
which is also what closes the duplicate-window hole. A 256 KiB-per-request
stream still opens its window on the second read, so the steady-state
throughput numbers above should stand (unverified as of this writing); a VM
guest's 16 KiB reads need sixteen in a row before anything is speculated.

The counters can finally see the cost, not just the benefit. `hit/miss` count
claims, so a stranded window appeared in neither; `summary` now also reports
`speculated=<count>/<bytes>`, `wasted=<issued - hits>`, and `maxDepth=<deepest
window opened>` — `depthCap` is a constant for a given request size and says
nothing about what the ramp actually reached. A good hit rate with a large
`wasted` is readahead hurting latency while looking helpful.

The byte gate was not in the first version of the ramp, and the first real VM
run is why it exists. With the gate at "two consecutive requests", a VM boot
plus a ~40 GB image copy measured, from the extension's own counters: a
12-minute window of interleaved 16 KiB reads and writes that wasted **100%**
of ~6,200 speculative reads (hits frozen while `wasted` climbed — two small
reads between writes kept re-opening a window the next write threw away), and
one bursty minute that issued 8,101 speculations / 498 MB and wasted 72% of
them even though the burst was real. Overall: 3.6% hit rate, 82% of 653 MB of
speculation wasted, against 1.5 GB of real reads. Two consecutive 16 KiB reads
are 32 KiB of evidence, and 32 KiB of evidence is worth nothing. The remaining
burst-minute waste — windows discarded whole whenever the request size changes
— is a separate problem the gate does not address.

## The gate was necessary and nowhere near sufficient

The second VM run, with the gate in, settled where the time actually goes.
Speculation collapsed as designed — 2,403 chunks issued against 16,647 the run
before, and `maxDepth=32` proved real sequential bursts exist and ramp fully —
but the boot was still minutes long, and the counters say why: 11,575 reads,
774 hits (6.7%, all in the first minute), and ~10,800 misses at ~80 reads/s.
Every miss is one 16–32 KiB read paying a full XPC + SCSI round trip, ~12 ms,
serially, because FSKit hands down one operation at a time. That is the floor
readahead-as-speculation cannot touch: speculation only helps streams, and a
boot is locality without streams.

So the slot-per-request design is gone, replaced by `PrefetchChunkCache`
(iSCSIKit, tested against an in-memory LUN). Reads are served from 256 KiB
aligned chunks; a miss fetches the whole covering span in one round trip
(read-around, cost visible as `readAround=` in the summary) and keeps it in a
32 MiB LRU cache, so a guest's neighbouring small reads become memory copies
instead of round trips. Claims match by range, not request size, which
removes the size-change discards outright. Speculation still exists, still
gated on 256 KiB of proven consecutive stream, and now issues 256 KiB chunks
— which also retires the 1 MiB-command cliff concern, since speculation never
issues a command larger than a chunk.

One deliberate semantic change rode along: a write drops only the chunks it
overlaps, not the whole cache. Dropping everything per write forfeited
read-around exactly where a VM needs it (guests interleave writes into every
read run). The ramp still resets in full on every write. Keeping unrelated
chunks assumes this initiator is the LUN's only writer — the same
single-initiator assumption every prior readahead design here already made.

That drop-the-overlap rule has since been replaced by write-through: writes
are patched *into* the overlapping cached chunks instead of invalidating
them, in three acts (`willWrite` / `didWrite` / `writeFailed`, the last being
the conservative drop for a write whose outcome is unknown). The bytes are
authoritative — they are exactly what the target just acknowledged — so
write-then-read-back becomes a hit, and a guest's journal traffic stops
punching refetch-sized holes in the cache. Overlapping *pending* speculation
is still dropped at both edges of the write, and the write-generation guard
still keeps a racing miss fetch from caching era-ambiguous bytes.

First VM run against the chunk cache (16 MiB, 2026-08-16): the guest reached
the desktop — it never had before — with a 54% cumulative hit rate (99%
during the early sequential phase) against the 6.7% of the gated slot design,
and ~100–120 reads/s served against the old ~80/s round-trip floor. Still
subjectively sluggish. The suspect number: `readAround` hit 3 GB against
549 MB served, 5.5x amplification, where perfect chunk locality predicts
~2,100 misses and the run took 11,330 — which reads as the 16 MiB cache
evicting chunks before the guest returns for their neighbours. The cache is
32 MiB now to test exactly that; if the amplification and hit rate barely
move, the scatter is real and the remaining gap is architectural, not
tunable.

They barely moved. The 32 MiB run, matched at the same point in boot: 56%
hits against 54%, ~11.6k misses against ~11.3k, 3.1 GB read-around against
3.0. Cache size is not the lever, so the eviction-churn hypothesis is dead —
but the same run showed 5,208 writes by minute six, and under drop-on-write
semantics every one of them punched a refetch-sized hole in the cache, which
made recently-written ranges (journal, filesystem metadata — precisely the
hot spots) guaranteed misses. That is what write-through (above) is aimed at.
If hit rate does not move materially under write-through either, the
remaining misses are genuinely scattered first-touches and the wall is
Backend A's one-operation-at-a-time delivery — an architecture question, not
a cache-tuning one.

## The rungs that were offered, measured, and withdrawn

Write-through fixed the hole the second VM run exposed, and the next question
was what depth to run at. That briefly became a user-facing setting: a
per-target "type of workload" picker (builds 25–27) mapping random / mixed /
sequential onto readahead byte budgets, first 1/2/8 MB and then 512 KB/2 MB/4 MB.

Measuring it removed it. One 256 KiB soak per depth, real hardware:

| depth | budget | unused | wasted/read | hit rate | mismatches |
|---|---|---|---|---|---|
| 2 | 512 KB | 5.9% | 0.058x | 93.07% | none |
| 4 | 1 MB | 11.1% | 0.115x | 93.06% | none |
| 16 | 4 MB | 32.4% | 0.443x | 93.16% | none |
| 32 | 8 MB | 48.8% | 0.882x | 93.15% | none |

Hit rate does not move across a 16x range of depth. Depth was never buying
residency; it was buying queue occupancy at the target, where speculation that a
write or a seek is about to discard sits in front of reads that are real. The
only thing it reliably changed was how much bandwidth was thrown away.

That is not a choice worth putting in front of a user — nobody knowingly picks
the option that wastes more for the same result — so the picker is gone and
`ReadaheadDepthController` decides.

### The controller

Weighted waste over the last three seconds of **activity** (0.6 / 0.3 / 0.1,
most recent first), evaluated once per active second: above 15% the cap halves,
below 6% it gains one, and in between it holds. Additive increase against
multiplicative decrease, which converges instead of hunting; equilibrium
therefore sits below the deadband's midpoint by construction.

Two details that are load-bearing rather than incidental:

**It has no clock of its own.** Evaluation happens on the read path, and each
read contributes `min(gap since previous read, 100 ms)` toward the next second.
An idle volume schedules no wakeups, advances no window, and is steered by
nothing — and under load, where reads are milliseconds apart, the cap never
binds so the window tracks wall time exactly.

**Weights apply to counts, not to per-second ratios.** Otherwise a second
holding three settled chunks outvotes one holding three hundred.

Measured at both ends of its range. The soak's write-and-seek mix (21% writes,
17% seeks by count) drives it to depth 3 — 8.7% waste, 93.1% hits, no
mismatches. A pure 100.9 GB sequential pass takes it to the 32 ceiling and holds
it: 99.86% hits, 421 MB/s, `readAround` 0.012%.

### Why waste is counted at eviction, not at speculation

`chunksSpeculated - speculatedUsed` is the obvious waste metric and it cannot be
used to steer depth. It scores every speculative chunk that has not *yet* been
read as wasted, including ones sitting in cache whose reader is 200 ms behind —
so its error is the size of the window in flight, which is the very quantity
being controlled.

The sequential pass measured that error exactly. Over 384,582 speculative
chunks at depth 32:

    cumulative unused   +32      <- the in-flight window, no more and no less
    settled              9 wasted / 384,563 used   = 0.0023%

Feeding the cumulative figure to a controller that cuts depth when waste rises
inverts the loop. At the ~1,600 chunks/s that pass sustains, 32 phantom chunks
is ~2% of a one-second window and harmless; at a VM guest's ~80 chunks/s the
same 32 is ~40%, over the trigger, so depth halves — and halving does not shrink
the ratio fast enough to escape, so it ratchets to the floor. The controller
would cut depth hardest exactly where traffic is slow and speculation is working
perfectly.

So a speculative chunk is counted only when it reaches a terminal state: read at
least once before it left the cache (`resolvedUsed`), or evicted having never
been wanted (`resolvedWasted`). Chunks still resident are undecided and count
for nothing. Every removal from the map goes through one helper so a new removal
site cannot silently skip the verdict.

The lag this introduces — a chunk resolves when it is evicted, which under light
load can be seconds — is real and deliberate. It is *unbiased*, which is what a
control loop needs; the cumulative counter is fast and wrong in a direction that
correlates with the control variable.

### What the throughput numbers in this section are worth

Less than they look. See the note under item 9 of `docs/open-questions.md`: the
same build at the same depth moved 2.4x between two consecutive days, and 48%
within one morning. Every table above that reports MB/s or blocks/600s is one
run per setting, which measures the array as much as the setting. The waste
ratios and hit rates reproduced across both days and the 2.4x swing; those are
the numbers the design rests on.
