# Resilience under adverse conditions

## Why a local target

Every fault worth testing was previously untestable. The NAS is someone else's
machine: its connections cannot be dropped on cue, it cannot be made to swallow
commands while still answering pings, its negotiation parameters cannot be
changed, and its power cannot be cut. The earlier crash test cut power to the
*initiator* instead, where FUA and non-FUA writes behave identically — so it
could not discriminate the one thing it was built to check.

`iscsi-target-sim` (`Sources/iscsi-target-sim`) is a real iSCSI target that runs
beside the initiator. It reuses the `MockTarget` protocol engine the integration
tests already drive, adds a TCP listener and a loopback control socket, and
serves either RAM or a sparse file so a LUN can be larger than memory.

It is not a production target: one LUN, one connection per session, no session
reinstatement, no persistent reservations, no ERL>0.

## The write-cache model

This is the substantive part. A target with `WCE=1` acknowledges a write as soon
as it is in cache; only FUA writes and `SYNCHRONIZE CACHE` reach stable media.
`MockTarget` never read the FUA bit (CDB byte 1, bit 3), so it could not model
that at all. Now it does:

| verb | effect |
|---|---|
| `drop` | kill the TCP connections. Nothing else changes; cached writes stay cached. |
| `reboot` | drop, then commit the cache. An orderly restart: nothing is lost. |
| `crash` | drop, then **discard** the cache. Target power loss with `WCE=1`. |

Two deliberate choices in the cache:

- **Nothing writes back on its own** — no timer, no background flush. A cache
  that flushes when it feels like it makes every crash test a coin flip.
  Deterministic is worth more than realistic here. The one exception is a size
  cap so a long non-FUA soak cannot exhaust memory, and it bumps
  `pressureCommits` so a test can assert its window stayed clean.
- **The cache answers reads.** Volatile is not the same as invisible. A read
  must see a cached write, or every read-after-write looks like corruption for
  a reason that has nothing to do with the initiator.

## Does `writeThrough` actually buy durability?

Yes, and now provably. `CrashConsistencyTests` asserts **both arms**, because
"FUA writes survived a crash" proves nothing on its own — if nothing were ever
cached, or if `crash()` did not discard, the positive test would pass for the
wrong reason.

| arm | result |
|---|---|
| `writeThrough=on`, crash | 0 blocks cached, 0 lost, data intact |
| `writeThrough=off`, crash | every block cached, all lost, data back to zeros |
| `writeThrough=off` + explicit `flush()`, crash | data intact |
| flush, then write, then crash | everything before the barrier survives; only the tail is lost |
| non-FUA write, then FUA rewrite, then flush | the FUA value wins — a stale cached copy must not be resurrected |

## Two hangs found and fixed

**Nothing ever timed out a SCSI task.** `SessionPolicy` had a NOP keepalive and
recovery backoff, but a target that accepts commands and never answers them
still answers pings — so the connection looked healthy while every I/O waited
forever. The existing hostile-target tests only appeared to cover this because
the *tests* wrapped each call in a deadline; the library did not.

Under Backend A that hang is worse than an error: it propagates through
DiskImages into APFS and becomes a wedged volume rather than a failed write.
`ISCSISession.execute` now runs under `policy.taskTimeout` (30 s, matching the
conventional SCSI command timeout; `ISCSI_TASK_TIMEOUT_SEC=0` restores the old
behaviour). On expiry the task is aborted and retried on a *fresh session* —
resubmitting on the same connection just buys another timeout. When the retries
are gone the connection is dropped so the next caller starts clean, and
`SessionError.taskTimedOut` is surfaced.

**That fix could not have worked on its own.** `abortOnCancel` waited for the
`ABORT TASK` *response* before resolving the cancelled task, so a target sick
enough to ignore commands could ignore task management too — and then the
cancellation itself hung, leaving the new deadline nothing to land on. The
caller is now unblocked first and the abort sent best-effort under its own 5 s
bound. Confirmed by reverting the fix and watching the test hang until it was
killed.

## The scenario matrix

`scripts/vm-resilience.sh`, run on the VM as root, drives the whole Backend A
stack (FSKit extension → DiskImages → APFS) against the simulator.

| scenario | what it asks |
|---|---|
| `baseline` | Does the stack work over the simulator at all? |
| `drop` | Connections die mid-write; ERL0 recovery must resubmit and the data must still verify. |
| `stall` | Commands swallowed, NOPs answered. Must surface an **error** within the deadline. |
| `crash` | Target power loss mid-write. `blocksLost=0` is the assertion, and the filesystem must come back consistent. |
| `pause` | Portal stops accepting past recovery exhaustion. Blocking during the outage is allowed; staying dead after it ends is not. |
| `corrupt` | With `DIGEST=CRC32C`, payload bytes flipped on the wire must never reach the application. |

### Results (2026-08-14, macOS 26.6.1)

All six pass. What each actually showed:

- **baseline** — 64 MiB written and verified. The target-side counters are the
  interesting part: `fuaWrites=199 cachedWrites=0 dirtyBlocks=0`. Seen from the
  target, the entire stack writes through. That is independent confirmation of
  the `writeThrough` setting from the far side of the wire.
- **drop** — 192 MiB written while connections were killed underneath it; every
  file verified byte-exact.
- **stall** — the write returned `OSError: [Errno 5] Input/output error`. That
  is the whole point: a bounded error propagated all the way up through
  DiskImages and APFS to the application, where before the deadline it would
  have hung. Clearing the fault, the next write succeeded.
- **crash** — power cut mid-write, `blocksLost=0`, `fsck_apfs -n` reported *"The
  volume appears to be OK"*, and all pre-crash files verified. **APFS survives
  target power loss because FUA covers every write** — the claim `writeThrough`
  exists to make, finally demonstrated end to end rather than argued.
- **pause** — the writer blocked for the full 60 s outage (allowed; open-iscsi
  blocks for two minutes by default) and returned 3 s after the portal came
  back, having written all 2.4 GiB successfully. A 60-second target outage is
  survived transparently.
- **corrupt** — with `HeaderDigest=true DataDigest=true` negotiated and every
  Data-In payload corrupted, reads failed with EIO and **no corrupted byte
  reached the application**. After clearing the fault, every file verified. The
  NAS negotiates digests off, so this is the first time the CRC32C path has run
  under load.

### Three scenarios that could not fail, and why that mattered

Worth recording, because each would have produced a green run that meant
nothing:

- **`fsck_apfs` refuses a mounted volume** and exits non-zero. The crash
  scenario ran it after mounting and swallowed the status, so the only
  filesystem-consistency check in the suite was a no-op. It now runs between
  attaching and mounting.
- **The stall scenario treated "errored in 90 s" and "killed after 240 s" as
  the same outcome** — and a wedge is precisely the failure it exists to catch.
  The step runner now returns 124 when it had to kill a step, and the scenario
  fails on a wedge *and* on an unexpected success (a write that succeeds means
  the fault never reached the data path).
- **The drop scenario never checked that it dropped anything.** Loopback is
  fast enough that a short write finishes before the first drop lands, and
  `dropped=0` four times over tests nothing. It now sums what was actually
  killed and fails if that is zero.

A fourth was a bad claim rather than a bad assertion: the `pause` scenario held
the portal down for the entire measurement window and then asserted the write
did not block. A network disk that is genuinely unreachable is *allowed* to
block — open-iscsi blocks for two minutes by default. The claim worth testing is
the one after it: once the portal returns, the stack must make progress again.

## Session recovery under load: two defects in the NVMe/TCP recovery path (2026-09-02)

Found by monitoring a live NVMe/TCP mount on the development host — the FSKit
backend over `nqn.…:ssd-vms`, 4 h of ordinary use with a VM running off it.
The daemon reported **37 session recoveries**, taking its cumulative counter
from 7 to 43, while every layer above stayed up: no unanswered requests, no
EIO, no give-ups. The volume never noticed. Both defects below are independent
of whatever provoked the drops, which is a separate and still-open question.

### A slow command is indistinguishable from a dead link

`NVMeController.execute` wraps every command in `withDeadline(policy.taskTimeout)`
— 30 s by default. On expiry it calls `recover(after: nil)`, which drops the
queue pair, rebuilds it, and emits
`connectionLost(reason: "no active controller")`. The daemon logs that as

    …:ssd-vms: connection lost (no active controller); recovering

**Nothing was lost.** The socket was fine; one command was merely slow. The
observable is a healthy queue pair being torn down and rebuilt, described in
the log as a connection failure — which is what made the incident look like a
flapping network for most of a day.

Of the 37 events, 26 were `(no active controller)` — this path. The other 11
were `(closed)`, which is the *other* self-inflicted route: the Keep Alive task
(`nopInterval` 10 s, `nopTimeout` 10 s) calls `queue.close()` itself when a Keep
Alive misses its deadline, and the next command then fails `ConnectionError.closed`.
So **neither message means the peer hung up.** Both are local timeouts.

The counts fit the budget: `taskRetries` 2, `maxRecoveryAttempts` 5, and only
10 events escalated to a logged `taskTimedOut` — the rest were absorbed by
retry, which is why nothing above the daemon saw an error.

Whether 30 s is the right deadline is a policy question. The defect is that
expiry is reported as connection loss and handled by teardown, so an
operator cannot distinguish "the link died" from "the target was busy", and
the recovery counter — the metric the diagnostics pane shows — conflates them.

### `recover()` has a reentrancy hole, and it fired

`NVMeController` is an actor. `recover()` guards against concurrent recovery:

```swift
if let existing = recoveryTask {          // NVMeController.swift:297
    try await existing.value
    return
}
onEvent?(.connectionLost(...))
await dropQueues()                        // <-- suspension point
…
recoveryTask = task                       // :323
```

`recoveryTask` is only assigned at :323, after an `await`. Two callers can
therefore both pass the guard at :297, both log `connectionLost`, both call
`dropQueues()`, and both start a recovery task. Actor isolation does not
prevent this: it is exactly the reentrancy an `await` permits.

It is not theoretical — the incident log caught it:

    09:41:40.690699  recovery attempt 1/5
    09:41:40.690771  recovery attempt 1/5     <- 72 µs later
    09:41:40.697526  recovered (10 time(s) so far)
    09:41:41.211807  recovered (11 time(s) so far)

Two in-flight commands hit their deadline together, raced through the guard,
and each rebuilt the session — inflating the recovery count by one and running
`dropQueues()` twice against a pair the other was rebuilding.

**Fixed (2026-09-02).** Everything that suspends now lives inside the recovery
task, and `recoveryTask` is assigned immediately after the task is created,
with no `await` between the guard and the assignment. The iSCSI session had the
identical hole — its suspension point was `await old.close()` — and got the same
treatment, with the teardown extracted into `tearDownForRecovery()`.

`Tests/IntegrationTests/RecoveryCoalescingTests.swift` covers both: eight
commands in flight when the connection dies, asserting one `connectionLost`,
one `recovered`, and `recoveryCount == 1`. Before the fix the NVMe case
reported **2 and 2** — the production signature exactly. The iSCSI case passed
before the fix as well as after: the hole was real in that code, but this shape
does not reliably trip its timing, so that half is a regression guard rather
than a reproducer.

A third instance of the same shape is present and deliberately left alone:
`readCapacity()` in both block devices checks `capacityKnown`, awaits, then
sets it, so two concurrent first calls each issue an Identify / READ CAPACITY.
Both write identical values, so the cost is one redundant round trip on first
use and never a wrong answer. Coalescing it would put a task handshake on the
path every read and write takes.

### What was ruled out, and how

The first hypothesis was flush starvation: the drops clustered in an 18-minute
window whose I/O was **60:1 write-to-read**, ten `periodic SYNCHRONIZE CACHE
failed (taskTimedOut)` lines appeared at a 30-second cadence, and windows with
the *same* write volume but a healthy read component dropped nothing. The
proposed mechanism was that a sustained write queue delays the periodic flush
past `taskTimeout`.

**Measured, and false.** `flushprobe` (scratch harness, deliberately not
committed — it lives on the 26.6.2 VM at `~/flushprobe-src/`, source plus a
prebuilt binary, *outside* `~/iSCSI` so an `rsync --delete` from the host
cannot orphan it; to rebuild, drop it in `Sources/flushprobe/` and add an
executable target depending on `iSCSIKit`, `NVMeKit`, `iSCSIDaemon`)
drove the scratch namespace from the 26.6.2 VM at 192.168.0.44 straight through
`NVMeController` — no daemon, no FSKit — at QD 8 with 1 MiB writes and a timed
flush every 30 s:

| phase | write rate | volume | flush latency (n=9) | recoveries |
|---|---|---|---|---|
| A: writes only | 231.8 MiB/s | 68 GiB / 300 s | min 0.29 · median 0.61 · max **0.73** | **0** |

That is ten times the incident's sustained rate with zero reads, and the worst
flush came in at **0.73 s against a 30 s deadline** — a 40× margin. Sustained
write load does not starve the flush, and `NVMeController` itself is sound at
that rate. The control phase (mixed 1:4 reads) was not run: it existed to
contrast with a phase A that never reproduced.

What the negative does *not* do is explain the correlation, which was real.
Three candidates remain, and the harness bypassed all three: concurrent
multi-session pressure on the same ZFS pool (the incident had live VMs *and* an
install against `ssd-vms`; the test was one stream against `name-testing`); an
allocating write pattern rather than an overwrite of a fixed window; and the
`hdiutil → FSKit → XPC → DaemonCore` path above the controller — note that the
four `daemon call timed out after 30s` lines are the *extension's XPC call*
timing out, not a wire timeout, so a serialization point in the daemon would
produce exactly this signature with a healthy wire.

Rig note: the harness ran on macOS 26.6.2 (25G83) against the same target the
host uses; the host is 27.0. Same daemon code, different OS.

### Candidate 2 (pool contention across sessions): also measured, also false

Four independent `flushprobe` processes — four controllers, four queue pairs,
four flush timers — each on its own 8 GiB window of the scratch namespace:

| | aggregate write | worst flush | recoveries |
|---|---|---|---|
| 1 session | 231.8 MiB/s | 0.73 s | 0 |
| 4 sessions | **408.8 MiB/s** | **1.05 s** | **0** |

120 GiB in 300 s. Aggregate throughput nearly doubled, so the link was not the
constraint in the single-session run either. Session multiplicity cost 0.3 s of
flush latency and produced no recoveries: still a 28× margin on the deadline.

### Candidate 1 (a serialization point above the controller): refuted by reading

- `DaemonCore` is an actor, but `write`/`read`/`flush` each `await` the device,
  which releases the actor at the suspension point. It does not serialize I/O.
- `NVMeBlockDevice` is an actor with the same property, and splits a 1 MiB
  write into 256 KiB chunks with up to 8 in flight.
- The measurement settles it independently: 231 MiB/s through exactly this
  stack, minus the XPC hop, with sub-second flushes.

**And the XPC timeouts are downstream, not upstream.** During recovery,
`execute` awaits `recoveryTask.value`, so every in-flight command blocks until
the session is rebuilt. The four `daemon call timed out after 30s` lines are
therefore a *consequence* of the recoveries, not their cause — which removes
the reason for suspecting this layer at all.

### What the evidence actually shows: the flush itself never completed

The count-based reading above ("11 initiating `(closed)` events, 26 follow-ons")
was wrong, and the timestamps say so. Ordering every loss event against the
`periodic SYNCHRONIZE CACHE failed` lines gives a rigid repeating triple:

    10:10:43  lost(no active controller)          flush attempt 1, 30 s deadline
    10:11:13  lost(no active controller)          flush attempt 2, 30 s deadline
    10:11:44  lost(closed) + SYNC CACHE FAILED    attempt 3, retries exhausted
    10:12:44  … the next tick starts the cycle again

That shape repeats for the whole 18-minute storm. Every one of the ten
`SYNCHRONIZE CACHE failed (taskTimedOut)` lines lands in the same second as a
`(closed)` event, and `(closed)` is always the **third and final** event of a
cycle — never the first. So:

- **`(closed)` is not the trigger; it is the terminal state.** The Keep Alive
  story — a missed 10 s Keep Alive closing the admin queue and cascading — is
  refuted by ordering. By the third attempt the queues have already been
  dropped and rebuilt twice by the two preceding `recover()` calls, so the last
  submit finds a closed queue. It is a consequence of the retries.
- **The cycle arithmetic recovers the configuration.** Three attempts is
  exactly `taskRetries = 2` (attempts 0, 1, 2) at a 30 s deadline each; the
  121 s super-cycle is those ~91 s plus a 30 s gap, which puts the target's
  flush interval at 60 s.
- **Four `(no active controller)` events stand alone** (08:45:13, 08:57:53,
  09:41:10, 09:41:40 — the first is 26 minutes before any `(closed)`). Those
  are single deadline expiries that succeeded on retry, which is why nothing
  above the daemon noticed them.

**So the trigger is that SYNCHRONIZE CACHE did not complete within 30 seconds,
three times running, every 60 seconds, for 18 minutes.** Not a slow flush —
an unanswered one. Against measured flush latencies of 0.29–1.05 s under ten
times the write load, this is not queueing on the initiator side; the target
stopped answering the command.

That is consistent with the write-dominated window (a large dirty ZFS
transaction group has a great deal to commit) but it is a target-side
condition, and neither stress test could have produced it: both drove an
unloaded pool from a quiet initiator. Establishing it needs evidence from the
NAS — `zpool iostat`, txg sync times, and nvmet's own view of the outstanding
flush during such a window — not more load from this end.

Two initiator-side defects stand regardless of what the target was doing:

- **A command that exceeds `taskTimeout` is reported and handled as connection
  loss.** The session is torn down and rebuilt when nothing was wrong with it,
  and the recovery counter — the number the diagnostics pane shows — cannot
  distinguish a dead link from a busy target. During this incident it read 43.
- **`taskRetries` retries the flush by rebuilding the session**, so a target
  that is slow to flush costs three session teardowns per tick. A flush that
  needs longer than 30 s is a plausible thing for a loaded NAS to do; treating
  it as a transport failure is not a plausible response.

Status: the trigger is characterised but **not established** — it is
target-side, and this repository has no measurement from that side.
