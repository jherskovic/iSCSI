# Soak results — 0.4.0, chunk cache, 2026-08-16

Host: Jorge's Mac. Target 192.168.20.1,
`iqn.me.herko.planet-express:iscsi-driver-testing`, 43 GB LUN, 10GbE.
APFS ("Glorious iSCSI image", 52 MB used) mounted on the LUN throughout; the
soak writes raw at 12–14 GiB.

Counters from the periodic `CLOSE` summary, subsystem
`me.herko.iSCSIInitiator.fsext`, cumulative since mount. Query with
**`/usr/bin/log`** spelled absolutely — a `log` shell function shadows it and
returns nothing.

## Build 23 — readahead depth 32 (`readaheadBytes` 8 MiB)

### Run 1 — 256 KiB, 600 s

    sequential runs 2338, writes 1084, seeks 875
    blocks read 88506, written 17564
    no mismatches

Extension at the run boundary:

    reads=84312/21961003520B writes=4785/4589879296B flushes=5
    avgReq=260473B lastReq=262144B
    cache=93% (78486 hit, 5826 miss, 0 unanswered) maxDepth=32
    speculated=151955/39834091520B unused=74462 readAround=2568192B

### Run 2 — 1 MiB, 600 s

    sequential runs 1684, writes 769, seeks 633
    blocks read 64519, written 8720
    no mismatches

Cumulative at end:

    reads=145480/86100300288B writes=13366/13587709952B flushes=5
    avgReq=591835B lastReq=1048576B
    cache=91% (132808 hit, 12672 miss, 0 unanswered) maxDepth=32
    speculated=429421/112570138624B unused=135744 readAround=2568192B

Delta for run 2 alone:

| | value |
|---|---|
| requests / bytes | 61,168 / 64.14 GB |
| avg request | 1,048,576 B — exactly 1 MiB every request |
| writes | 8,581 / 9.00 GB |
| hits / misses | 54,322 / 6,846 → 88.8% |
| unanswered | 0 |
| speculated | 277,466 chunks / 72.74 GB, 22.1% unused |
| readAround | 0 bytes |

### Verdicts, build 23

**Coherence under write-through: PASS.** 1,853 writes across both runs, each
read straight back, zero mismatches and zero stale generations. Under
write-through the read-back is served from the cache `didWrite` patched, so this
is the path a patching bug would show in. Primary thing 0.4.0 owed.

**Split path verified on real hardware: PASS.** Every run-2 request was exactly
1 MiB against a 256 KiB `maxTransferBytes` (61,168 × 1,048,576 matches the byte
counter exactly) — 4 concurrent SCSI commands each, ~245,000 in all, reassembled
by index, every one verified. Previously only MockTarget, whose in-memory pipe
may complete in order and so cannot test what the index exists for.

**88.8% is not a regression from build 16's 92%.** Hit/miss is counted per
*request*: `hits + misses` equals the request count exactly in both runs (84,312
and 61,168). A 1 MiB request scores a hit only if all four covering chunks are
resident — 4x the miss exposure of a 256 KiB request. Build 16's 92% was over
650 KiB average requests. The three numbers in open-questions item 8 are not
comparable as stated.

**`readAround` = 0 for the whole 1 MiB run.** 1 MiB is exactly four aligned
chunks, so a miss fetches the covering span with nothing left over. Read-around
cost is an alignment property, not a request-size one. At 256 KiB it was
2.57 MB against 21.96 GB served (0.012%). Contrast the VM boot: 3.1 GB for
549 MB served, 5.5x — cheap on streams, expensive only under scatter.

**Speculation is expensive at 256 KiB.** 49% of speculative chunks unused, 1.81x
the read bytes on the wire. At 1 MiB, 22.1% and 1.13x — larger requests clear
the 256 KiB `minStreamBytes` gate in one read and ramp against a stream four
times likelier to still be running. This is what motivated halving the depth.

Wall rates: 147.5 blocks/s (256 KiB) and 107.5 blocks/s (1 MiB), against build
16's 55.4 and 58.7. Suggestive only — the verifier is partly Python-bound and
build 16's host is unrecorded. The soak has never been a throughput test; the
"1099 MB/s" in open-questions item 8 comes from the bench table in
queue-depth.md, not from this script.

## Build 24 — readahead depth 16 (`readaheadBytes` 4 MiB)

Change: `readaheadBytes` 8 → 4 MiB, so
`chunkCap = min(maxSlots 32, 4 MiB / 256 KiB) = 16`. `readaheadMaxSlots` stays
32 as the XPC/buffer rail and can no longer bind, since `chunkBytes` is never
below 256 KiB. Confirmed live: `maxDepth=16` in the CLOSE summary.

Baseline before the run (fresh mount, pre-soak noise from the APFS probe):

    reads=534/4338176B writes=1078/1122107392B flushes=5
    avgReq=8123B lastReq=16384B
    cache=98% (527 hit, 7 miss, 0 unanswered) maxDepth=16
    speculated=16/4194304B unused=15 readAround=1536000B

### Mid-run snapshot, 256 KiB (3.68 GB in, run still going)

    reads=14565/3682480640B writes=2525/2565734400B flushes=5
    avgReq=252830B lastReq=262144B
    cache=93% (13584 hit, 981 miss, 0 unanswered) maxDepth=16
    speculated=19300/5059379200B unused=6332 readAround=1536000B

Deltas against the baseline, against build 23's full 256 KiB run:

| | depth 32 (b23) | depth 16 (b24) |
|---|---|---|
| hit rate | 93% | 93.1% |
| unused speculation | 49.0% | 32.8% |
| spec bytes / read bytes | 1.81x | 1.37x |
| wasted bytes / read bytes | 0.87x | 0.44x |
| unanswered | 0 | 0 |

**Halving the depth held the hit rate and halved the wasted bandwidth.** That is
the result the change was aimed at.

### Final, 256 KiB, full run

    reads=91368/23815152128B writes=5012/4785831936B flushes=5
    avgReq=260650B lastReq=262144B
    cache=93% (85022 hit, 6346 miss, 0 unanswered) maxDepth=16
    speculated=124513/32640335872B unused=40717 readAround=1794048B

Deltas against baseline, beside build 23's 256 KiB run at the same scale:

| | depth 32 (b23) | depth 16 (b24) |
|---|---|---|
| bytes read | 21.96 GB | 23.81 GB |
| hit rate | 93% | 93.02% |
| unused speculation | 49.0% | 32.7% |
| spec bytes / read bytes | 1.81x | 1.37x |
| wasted bytes / read bytes | 0.87x | 0.45x |
| unanswered | 0 | 0 |
| readAround | 2.57 MB | 258 KB |

**Verdict: the halving is free.** Hit rate is unchanged (93.02% vs 93%) while
wasted speculation falls from 49% to 33% and wasted bandwidth per byte read
roughly halves. The mid-run snapshot at 3.68 GB read 32.8% / 1.37x and the full
run 32.7% / 1.37x, so these are steady-state values, not ramp artifacts.

`readAround` fell 10x (2.57 MB → 258 KB), which was not predicted: a shallower
window claims fewer partially-covered spans, so fewer misses pay for a
read-around that a speculative chunk would have covered.

Script output for the same run:

    sequential runs 2538, writes 1179, seeks 966
    blocks read 96256, written 18339
    no mismatches

**Correctness holds at depth 16.** 1,179 writes read straight back, zero stale
generations.

Full comparison of the two 256 KiB soaks, both 600 s:

| | depth 32 (b23) | depth 16 (b24) |
|---|---|---|
| seq runs / writes / seeks | 2338 / 1084 / 875 | 2538 / 1179 / 966 |
| blocks read / written | 88,506 / 17,564 | 96,256 / 18,339 |
| mismatches | none | none |
| hit rate | 93% | 93.02% |
| unused speculation | 49.0% | 32.7% |
| wasted bytes / read bytes | 0.87x | 0.45x |
| readAround | 2.57 MB | 258 KB |
| unanswered | 0 | 0 |

8.8% more blocks read in the same wall time, same hit rate, half the wasted
bandwidth. Same array-state caveat applies to the throughput half.

### 1 MiB at depth 16

    sequential runs 1381, writes 624, seeks 514
    blocks read 52316, written 7497
    no mismatches

    reads=141025/75851260416B writes=12433/12540592128B flushes=5
    avgReq=537856B lastReq=1048576B
    cache=91% (129095 hit, 11930 miss, 0 unanswered) maxDepth=16
    speculated=326865/85685698560B unused=68105 readAround=5971968B

Delta (52.04 GB read, avgReq 1,047,910 B):

| | depth 32 (b23) | depth 16 (b24) |
|---|---|---|
| hit rate | 88.8% | 88.8% |
| unused speculation | 22.1% | 13.5% |
| spec bytes / read bytes | 1.13x | 1.02x |
| readAround | 0 | 4.18 MB |
| mismatches | none | none |

Hit rate identical to three significant figures at both request sizes, waste
down at both. **The halving is free.** `readAround` rose from 0 to 4.18 MB,
0.008% of bytes served — a shallower window leaves a few more partially-covered
spans for misses to pay for, which is the expected direction and negligible.

## Build 25 — per-target `WorkloadProfile`, 2026-08-17

The budget is now `TargetRecord.workloadProfile` → `WorkloadProfile` →
`readaheadBudget(session:)` over XPC → `ReadaheadPolicy`. `maxDepth` in the
CLOSE summary is the end-to-end check that the daemon's value reached the
extension rather than the fallback.

### Random access (1 MB, depth 4), 256 KiB soak

Plumbing confirmed before the run: `maxDepth=4` during the APFS probe alone.

    sequential runs 3996, writes 1800, seeks 1451
    blocks read 151643, written 23591
    no mismatches

    reads=144163/37656519168B writes=6649/6258688000B flushes=5
    avgReq=261207B lastReq=262144B
    cache=93% (134182 hit, 9981 miss, 0 unanswered) maxDepth=4
    speculated=148461/38918160384B unused=16458 readAround=2568192B

Delta: 143,632 requests / 37.65 GB, hit rate 93.06%, 148,457 chunks speculated,
11.1% unused, 1.03x spec bytes, `readAround` 0.

### All three rungs, 256 KiB

| | depth 4 (1 MB) | depth 16 (4 MB) | depth 32 (8 MB) |
|---|---|---|---|
| blocks read / 600 s | 151,643 | 96,256 | 88,506 |
| hit rate | 93.06% | 93.02% | 93% |
| unused speculation | 11.1% | 32.7% | 49.0% |
| wasted bytes / read bytes | 0.115x | 0.45x | 0.87x |
| readAround | 0 | 258 KB | 2.57 MB |
| mismatches | none | none | none |

**Depth 4 wins on every axis, including throughput** — 57% more blocks read than
depth 16 and 71% more than depth 32, at an identical hit rate. The prediction
that a shallow window would cost sequential throughput was wrong.

The mechanism that fits: hit rate never moved, so the deep window was not buying
residency, only queue occupancy. Wasted speculative commands sit at the target
ahead of real reads, and this soak destroys streams constantly (21% writes, 17%
seeks by count), so at depth 32 roughly half the queue is work that will never
be used.

### Sequential (8 MB, depth 32), 256 KiB soak, same day

Plumbing confirmed: `maxDepth=32` once the ramp fired.

    sequential runs 5563, writes 2525, seeks 2029
    blocks read 212033, written 29903
    no mismatches

    reads=201349/52646773248B writes=8391/7788560384B flushes=5
    avgReq=261470B lastReq=262144B
    cache=93% (187583 hit, 13766 miss, 0 unanswered) maxDepth=32
    speculated=363005/95159582720B unused=177056 readAround=2310144B

Delta: 200,815 requests / 52.64 GB, 93.15% hit, 48.8% unused, 1.81x spec bytes.

### The confound was real, and it inverted the conclusion

**The 17 August depth-32 run read 212,033 blocks against depth 4's 151,643 on
the same day. Deeper is faster. The earlier "depth 4 wins on throughput"
conclusion was an artifact of comparing 17 August against 16 August.**

Depth 32 alone: 88,506 blocks on 16 August, 212,033 on 17 August — 2.4x, same
code, same depth. Array state dominates throughput outright.

What reproduced across the two days at depth 32:

| | 16 Aug | 17 Aug |
|---|---|---|
| hit rate | 93% | 93.15% |
| unused speculation | 49.0% | 48.8% |
| spec bytes / read bytes | 1.81x | 1.81x |
| blocks read | 88,506 | 212,033 |

Hit rate and `unused` land within noise; only throughput moved. Treat *only*
same-session throughput comparisons as meaningful.

### Same-session comparison, 17 August

| 256 KiB | depth 4 (1 MB) | depth 32 (8 MB) |
|---|---|---|
| blocks read / 600 s | 151,643 | 212,033 |
| hit rate | 93.06% | 93.15% |
| unused speculation | 11.1% | 48.8% |
| wasted bytes / read bytes | 0.115x | 0.882x |
| readAround | 0 | 0 |
| mismatches | none | none |

The setting is a real trade rather than a free win: depth 32 buys roughly 40%
more throughput for about 8x the wasted bandwidth. That is a defensible thing to
offer a user, which is what the feature exists for.

### Mixed (4 MB, depth 16) — first attempt died on EIO

The first mixed run stopped at ~150 s with `OSError: [Errno 5]`. Not a data
failure — zero mismatches; the script exits on any I/O error.

    08:21:49  connection lost (POSIX 60, Operation timed out); recovering
    08:21:49  recovery attempt 1/5
    08:22:00  recovery attempt 2/5
    08:22:00.908  extension: daemon call timed out after 30s  -> EIO
    08:22:01.238  recovered (1 time(s) so far)

Three things, all separate from the workload feature:

1. **Session recovery worked against real hardware.** test-playbook.md lists
   ERL0 recovery as MockTarget-only; this is the first time it has run in
   anger on the real target. Recovered in ~12 s over two attempts.
2. **The extension's timeout and the daemon's recovery are not coordinated.**
   The call gave up **330 ms** before recovery succeeded. A timeout that
   exceeded the recovery budget, or knew recovery was in flight, would have
   turned a failed volume I/O into a slow one. Looks like a real defect.
3. Re-attaching logged three `connection lost (no active connection)` /
   recovered pairs within 8 ms at 08:25:17. Unexplained, benign here, worth a
   look.

### Mixed (4 MB, depth 16) — re-run, clean

    sequential runs 5582, writes 2535, seeks 2040
    blocks read 212710, written 29965
    no mismatches

    reads=201874/52784595456B writes=8398/7804026880B flushes=5
    avgReq=261472B lastReq=262144B
    cache=93% (188060 hit, 13814 miss, 0 unanswered) maxDepth=16
    speculated=275134/72124727296B unused=89139 readAround=1794048B

Delta: 201,872 requests / 52.78 GB, 93.16% hit, 32.4% unused, 1.37x spec bytes.
Zero recovery events during the run.

### The complete set, 17 August, one array state

| 256 KiB | depth 4 (1 MB) | depth 16 (4 MB) | depth 32 (8 MB) |
|---|---|---|---|
| blocks read / 600 s | 151,643 | 212,710 | 212,033 |
| hit rate | 93.06% | 93.16% | 93.15% |
| unused speculation | 11.1% | 32.4% | 48.8% |
| spec bytes / read bytes | 1.03x | 1.37x | 1.81x |
| wasted bytes / read bytes | 0.115x | 0.443x | 0.882x |
| readAround | 0 | 0 | 0 |
| mismatches | none | none | none |

**The curve flattens at depth 16.** 4 MB and 8 MB are within 0.3% on throughput
— noise — while 8 MB puts twice the wasted bandwidth on the wire. On this
workload 8 MB buys nothing. Depth 4 gives up 28.7% of throughput to save that
bandwidth, which is exactly the trade the random rung exists to offer.

What this does *not* say: that 4 MB is too high. The depth 4 → 16 gap is large
and nothing between them was measured. 2 MB is depth 8, squarely in that gap.
Recommendation: keep mixed at 4 MB, reconsider what the 8 MB sequential rung is
for, and measure 2 MB before lowering any default.

### Superseded note

**Confound, since resolved — see above.** Depth 16 and 32 were measured on
2026-08-16 evening; depth 4 on 2026-08-17 morning. Array state moves these
numbers by up to 7x and the 16 August array was digesting ~50 GB of destructive
writes. Hit rate and `unused` are array-independent, but `unused` falling with
depth is arithmetic rather than a finding, so the throughput claim is the one at
risk. Re-running the 8 MB and 4 MB rungs today puts all three in one session on
one array state and settles it.

## Caveats

- Array state: every number after ~09:30 on 2026-08-16 came off an array still
  digesting ~50 GB of destructive writes. Throughput readings today are suspect;
  hit rate and the speculation ratios are the array-independent ones.
- The 636 MB/s-at-4-MiB figure in the old `readaheadBytes` comment was measured
  against the slot-per-request readahead the chunk cache replaced. It does not
  predict what depth 16 costs now.
- The VM-verdict half of open-questions item 8 stays open — needs a guest boot,
  and both test VMs are powered off.

---

## Build 26 — rungs lowered to 512 KB / 2 MB / 4 MB, 2026-08-17

`WorkloadProfile` now maps random→512 KB (depth 2), mixed→2 MB (depth 8),
sequential→4 MB (depth 16). All four depths have been observed live in
`maxDepth`: 2, 4, 8 and 16 across builds 25–26.

### 512 KB (depth 2), 256 KiB soak

    sequential runs 5346, writes 2426, seeks 1943
    blocks read 204057, written 28935
    no mismatches

    reads=193857/50682987008B writes=8106/7537950720B flushes=5
    avgReq=261445B lastReq=262144B
    cache=93% (180448 hit, 13409 miss, 0 unanswered) maxDepth=2
    speculated=188744/49478107136B unused=11209 readAround=2310144B

Delta: 193,324 requests / 50.68 GB, 93.07% hit, 5.9% unused, 0.98x spec bytes,
0.058x wasted. Zero recovery events during the run.

### Every depth measured on 17 August

| depth | budget | blocks / 600 s | hit rate | unused | wasted/read |
|---|---|---|---|---|---|
| 2 | 512 KB | 204,057 | 93.07% | 5.9% | 0.058x |
| 4 | 1 MB | *151,643* | 93.06% | 11.1% | 0.115x |
| 16 | 4 MB | 212,710 | 93.16% | 32.4% | 0.443x |
| 32 | 8 MB | 212,033 | 93.15% | 48.8% | 0.882x |

Waste falls cleanly and monotonically with depth. Hit rate is flat at 93% across
a 16x range of depth — the strongest single result here, and it reproduced
across two days.

### The depth-4 point is an outlier and should not be used

Depth 2 read 204,057 blocks and depth 4 read 151,643. Shallower cannot be 35%
faster than deeper. Every run after the first clusters at 204k–213k; the
depth-4 run sits 28% below the pack and was the first soak of the morning.

Run-to-run variance at a fixed setting is small: the two depth-16 runs reached
14,792 MB and 14,862 MB at the 150 s checkpoint, under 0.5% apart. So 151,643
does not fit, and the earlier claim that "depth 4 gives up 28.7% of throughput"
was built on it and is withdrawn.

**Revised conclusion: across depth 2–32, throughput is flat within ~4% and only
wasted bandwidth changes.** Unexplained — nothing distinguishes that run but
being first. One repeat at 512 KB or 4 MB would settle whether to discard the
point or take the non-monotonicity seriously.

### Re-attach connection churn reproduced

Five `connection lost (no active connection)` / recovered pairs inside 14 ms at
08:52:22, on re-attach. Same shape as the three seen at 08:25:17. Benign in both
cases, clearly repeatable, unexplained.

## The depth-4 outlier: resolved, array state

Re-measured at depth 4 on a throwaway build 27 (`sequential` temporarily
pointed at 1 MiB, to be reverted), ~4 hours after the original run:

    sequential runs 5897, writes 2680, seeks 2169
    blocks read 224882, written 31177
    no mismatches

    reads=213831/55918793216B writes=8761/8120172544B flushes=5
    avgReq=261509B lastReq=262144B
    cache=93% (199014 hit, 14817 miss, 0 unanswered) maxDepth=4
    speculated=220529/57810354176B unused=24428 readAround=1794048B

| depth 4 | 08:05 | 09:2x |
|---|---|---|
| blocks read / 600 s | 151,643 | 224,882 |
| hit rate | 93.06% | 93.05% |
| unused speculation | 11.1% | 11.1% |
| spec bytes / read bytes | 1.03x | 1.03x |
| wasted bytes / read bytes | 0.115x | 0.115x |

**Every array-independent metric reproduced to the digit while throughput moved
48%.** The 151,643 point is discarded, and the conclusion is array state rather
than depth — as hypothesised before the measurement was taken.

This also validates the counters: `unused` landing on 11.1% twice, hours apart
across a 48% throughput swing, makes it a property of the depth setting alone.

### Throughput tracks the clock, not depth

MB read at the 451 s checkpoint, in run order:

    08:05  depth 4    28,520
    08:17  depth 32   42,146
    08:26  depth 16   41,447
    08:52  depth 2    40,791
    09:2x  depth 4    44,734

Each rung was measured once, in sequence, so run order confounds every
throughput comparison in this document. Any firm throughput number needs
interleaving (A/B/A/B in one session), not one run per setting.

### What survives

| depth | budget | unused | wasted/read | hit rate |
|---|---|---|---|---|
| 2 | 512 KB | 5.9% | 0.058x | 93.07% |
| 4 | 1 MB | 11.1% | 0.115x | 93.06% |
| 8 | 2 MB | not measured | | |
| 16 | 4 MB | 32.4% | 0.443x | 93.16% |
| 32 | 8 MB | 48.8% | 0.882x | 93.15% |

Hit rate flat across a 16x depth range; waste roughly linear in depth. Both
reproduced across two days and a 2.4x throughput swing. The shipping rungs rest
on these, not on blocks/600s. Depth 8 — the default — is still unmeasured.

---

## Build 28 — adaptive depth control, 2026-08-17

The rungs are gone. `ReadaheadDepthController` sets the depth cap from settled
speculation outcomes: weighted waste over the last three seconds of *activity*
(0.6/0.3/0.1), evaluated every active second, halving the cap above 15% waste
and adding one below 6%. `workloadProfile` survives as a hand-editable override
with no UI.

Two accounting changes made it possible. Waste is now counted only when a
speculative chunk reaches a terminal state — read at least once before leaving
the cache, or evicted having never been wanted. The old
`chunksSpeculated - speculatedUsed` counted everything in flight as waste, and
deeper windows hold more in flight, so it reported more waste exactly when depth
rose: a controller fed that number drives depth to the floor on a workload where
deep readahead is working.

### 256 KiB soak, no override

    sequential runs 7025, writes 3175, seeks 2572
    blocks read 268556, written 35479
    no mismatches

    reads=254963/66697097728B writes=10020/9235054592B flushes=5
    avgReq=261595B lastReq=262144B
    cache=93% (237335 hit, 17628 miss, 0 unanswered) maxDepth=8 cap=3
    speculated=256158/67150282752B unused=22381
    settled=233668used/22371wasted readAround=3526656B

Cap trajectory across CLOSE samples: 8 (seed) → 4 → 3, then held at 3.
Delta: 254,428 requests / 66.69 GB, 93.07% hit, 8.74% settled waste, 1.01x
speculated bytes, 0.088x wasted bytes per byte read.

### Against the fixed rungs, same day

| | d2 | d3 adaptive | d4 | d16 | d32 |
|---|---|---|---|---|---|
| blocks / 600 s | 204,057 | 268,556 | 224,882 | 212,710 | 212,033 |
| hit rate | 93.07% | 93.07% | 93.06% | 93.16% | 93.15% |
| wasted / read | 0.058x | 0.088x | 0.115x | 0.443x | 0.882x |
| mismatches | none | none | none | none | none |

The loop found an equilibrium no rung could express — depth 3 — sitting between
the 512 KB and 1 MB rungs on waste at an unchanged hit rate.

### What this does and does not establish

**Does:** the controller runs, converges, holds, and costs nothing in hit rate
or correctness. `cap=` and `settled=` make it observable from a soak.

**Does not — throughput.** 268,556 is the day's highest, but this ran last and
the array trended faster all morning (depth 32 alone moved 2.4x day over day).
Throughput here is consistent with the cluster; nothing more.

**Does not — the bias fix.** Settled waste (8.74%) and cumulative unused (8.73%)
came out identical, because at depth 3 almost nothing is in flight. The
divergence the fix exists to prevent appears at depth 16–32, which this run
never visited. A long clean sequential pass — which would drive `cap` toward the
ceiling — is the case that would exercise it, and has not been run.

**Not evidence about the thresholds.** The landing at 3 rather than 4 is
additive-increase/multiplicative-decrease asymmetry: one bad second halves the
cap and recovery is +1 per second, so equilibrium sits below the deadband's
midpoint by construction.

### Migration gap found

The target still carried `workloadProfile: "sequential"` from the build-27
depth-4 measurement, so the first attach on build 28 came up pinned at cap=16
with the controller inert (`settled=0used/0wasted`). Correct behaviour for an
override, but nothing in the UI can now show or clear one. Only this machine
ever had that picker, so it is not a shipping problem — but whether a stale
override should survive the picker's removal is an open decision.

### Sequential pass — the case the soak cannot reach

`readahead-soak.py` is 21% writes and 17% seeks by count, so it keeps resetting
the ramp and holds the controller near the floor. It can never exercise the
condition the terminal-state accounting exists for. A pure read pass can
(`scratchpad/seqread.py`, read-only, F_NOCACHE, no verification):

    read 100.9 GB in 240s (421 MB/s), 2 wrap(s)

    reads=641071/167633527808B ... cache=97% (622919 hit, 18152 miss, 0 unanswered)
    maxDepth=32 cap=32 speculated=640740/167966146560B unused=22413
    settled=618231used/22381wasted readAround=16171008B

Delta over the pass:

| | |
|---|---|
| requests / bytes | 386,106 / 100.9 GB |
| hit rate | 99.86% (523 misses) |
| cap | 3 → 32, held |
| settled | 384,563 used / **9** wasted = 0.0023% |
| cumulative `unused` | **+32** |
| readAround | 12.4 MB (0.012%) |

**The old counter's bias is exactly the depth, and this measures it.** Across
384,582 speculative chunks, `chunksSpeculated - speculatedUsed` rose by 32 — the
window in flight at any instant — while settled accounting found 9 chunks
genuinely wasted.

Why that would have collapsed the loop rather than merely skewing it: at the
~1,600 chunks/s this pass sustains, 32 phantom chunks is ~2% of a one-second
window and harmless. At a VM guest's ~80 chunks/s the same 32 is ~40% — over the
15% trigger, so an immediate halving; and halving depth does not shrink the
ratio fast enough to escape, so it ratchets to the floor. The controller would
have cut depth hardest exactly where traffic was slow and speculation was
working. Settled accounting reads 0.0023% under the same conditions.

This is the failure mode no unit test could reach, and the reason the accounting
fix had to land before the controller.

Both halves of AIMD are now confirmed end to end: the soak's write/seek mix
drove `cap` to 3, a clean stream took it to the 32 ceiling and held it.

### Stale overrides are now cleared on load

`TargetStore.load()` strips any `workloadProfile` and rewrites the file, logging
what it cleared. This retires the override in practice — a hand-edit is erased
before it can take effect — so the enum and its XPC call are vestigial and could
be deleted. Left in place for now.
