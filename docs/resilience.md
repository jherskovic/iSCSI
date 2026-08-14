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
