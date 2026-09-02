# Open questions

Things known to be untested, unexplained, or deferred, with what is known about
each and how to attack it. Ordered by what a failure would cost, not by how
interesting it is.

Current as of 0.4.4 (build 34), 2026-08-18.

---

## 1. Sparkle's refusal to update while a volume is attached

**Never exercised.** The code refuses to install while anything is attached and
resumes when the last volume detaches — including a Finder eject, which is a
separate path that was broken until recently. Neither half has run against a
real update.

This is first on the list because it is the only open item whose failure mode is
data loss: replacing the FSKit extension under a live mount pulls the process
answering a mounted filesystem's reads and writes out from under it.

**How to test.** Attach a volume, then take an update. Expect a dialog naming
the volume, offering "Detach and Install", with nothing installed and no
relaunch. Then detach — via Finder eject, not the app, since that is the path
that had the bug — and it should install and relaunch on its own.

Cheap to fold into whatever ships next. It needs one attached volume and one
release.

## 2. Unbuffered I/O fails

`F_NOCACHE` reads of a file on a mounted APFS volume return EIO, while ordinary
buffered I/O on the same file is fine. Reading the extension-served `lun0.img`
with `F_NOCACHE` works, so the failure is above the extension rather than in it.

Databases and VM images routinely open files this way. Since the volume is
currently being used to store VMs, this may already be reachable in practice.

Unmeasured: whether writes fail the same way, and whether it is alignment,
buffer alignment, or something in the DiskImages layer.

## 3. Everything is measured against one target

TrueNAS on Intel, one LUN, one 10GbE link. The protocol implementation should be
standard-conforming, but "should" is doing a lot of work and every number in
`docs/queue-depth.md` comes from that one machine.

Specifically worth re-running elsewhere: the command-size cliff (below), the
readahead byte budget, and the FUA cost.

## 3a. Mutual CHAP cannot be exercised — the one target refuses it

The sharpest instance of item 3, and the reason it sits this high: it is the
only control that authenticates the *target* to us, on a transport with no
confidentiality and no integrity. Without it, nothing catches a stand-in
feeding this Mac a fabricated disk that macOS then mounts as APFS.

**Hidden in the UI since 0.4.1** behind `CHAP.mutualIsOffered`. Not because the
implementation is suspect. It is driven end to end by `AuthTraceTests` against
a peer that answers, and on the wire it produces RFC 7143 §12.1.3's literal
form — `CHAP_N CHAP_R CHAP_I CHAP_C` in one Login Request, mirroring the
encodings the target itself chose.

TrueNAS SCALE cannot answer. It writes `OutgoingUser` into `/etc/scst.conf`,
never loads it into `/sys/kernel/scst_tgt/`, and does not pick it up across an
iSCSI service restart, so `iscsi-scstd` logs

    CHAP target auth.: no outgoing credentials configured[ for discovery].

and refuses the login with `0x02/0x01`. That message comes from
`chap_target_auth_create_response` in `iscsi-scst/usr/chap.c`, which errors when
`account_get_first(conn->tid, ISCSI_USER_DIR_OUTGOING)` returns NULL — so the
target never composes an answer, it declines to. The ` for discovery` suffix is
`conn->tid` being zero: discovery and each target hold **separate** outgoing
accounts, which is why fixing one left the other failing.

The measured pair, same target and credentials, minutes apart:

    read-bench, no mutual pair   -> login, READ CAPACITY, 4 x 256 KiB reads, logout
    read-bench, mutual pair      -> 0x02/0x01 at the CHAP result

Two deductions worth not re-deriving. **Our `--mutual-user` never crosses the
wire** — `CHAP.respond` appends only `CHAP_I`/`CHAP_C`, and `mutualName` is used
locally in `verifyMutual` to check the name that comes back — so no client-side
peer-name setting can change the target's answer, and changing it did not.
And **SCST never requires the initiator to ask**: mutual is initiator-driven, so
a correctly configured target still accepts a one-way login. "It authenticates
without mutual even when set to Mutual CHAP" is not evidence of anything.

**How to attack.** A second target implementation is the whole answer — anything
that answers a mutual challenge clears this in one run of
`iscsictl discover --debug --mutual-user … --mutual-secret-file …`, whose auth
trace narrates each step. Failing that, whether TrueNAS ever loads `OutgoingUser`
into sysfs is a bug to file against them, not something fixable here.

## 3b. There is no TLS option to add — settled

Asked and closed on 2026-08-17. RFC 7143 defines exactly three `AuthMethod`
values — Kerberos, SRP, CHAP — and **no TLS binding at all**. The transport
protection the standard specifies is IPsec, per RFC 3723 as updated by RFC 7146.
There is nothing for an initiator to implement that a conforming target would
understand, and SCST has no TLS support either, so even a non-standard mode
would need something on the NAS terminating it.

What remains available is unchanged and is what the README recommends: run it on
a trusted segment or inside a WireGuard/IPsec tunnel. The README used to claim
"the protocol permits TLS and this implementation does not offer it yet"; it does
not permit it, and that sentence is gone.

---

## 4. The command-size cliff

With several commands outstanding, 1 MiB commands collapse and 256 KiB commands
do not — same bytes in flight:

    16 x 1 MiB   = 16 MiB outstanding ->  340 MB/s
    64 x 256 KiB = 16 MiB outstanding -> 1169 MB/s

Reproducible with 150s of settle between runs, so not cache saturation. Not
explained. 1 MiB is exactly this target's negotiated `MaxBurstLength`, which is
suggestive and may mean the boundary is per-target rather than universal.

`maxTransferBytes` now caps commands at 256 KiB so the shipping path never
issues one large enough to matter, which makes this a curiosity rather than a
bug — until a target negotiates something smaller.

**How to attack.** `iscsictl read-bench --chunk N --max-transfer N --queue-depth
D` isolates it. A packet capture at the boundary would probably settle whether
the target or the initiator's receive path degrades.

## 5. Writes are FUA-bound

Measured 4.5x: 336.5 MB/s without FUA, 74.8 with, and ~87 MB/s through the whole
stack. Every write carries FUA because FSKit never signals a barrier, so the
daemon cannot know when a filesystem wanted a flush, and an acknowledged write
sitting in a volatile target cache is a lie APFS will act on.

No amount of pipelining recovers this. Buffering writes to gain depth reopens
exactly the hole FUA closes.

It moves if either:

- FSKit gains a barrier signal (Apple's move; see the header of
  `iSCSIFSExtension.swift`), or
- the user can declare their target's cache non-volatile — battery-backed or
  UPS-protected — and accept the consequence. That is a UI and a stored setting,
  not a protocol change, and it is the only half available from here.

**Pipelining a large write is now worth 2.1x under FUA and 2.6x cached**
(2026-08-17), which does not change this item's trade but moves both sides of
it: a request larger than `maxTransferBytes` issues its chunks together instead
of one round trip at a time. It does nothing for the small writes that dominate
a running VM, which is where FUA hurts most. Numbers and method in
`docs/performance.md`.

**The second half is built** (post-0.3.8): `TargetRecord.flushIntervalSeconds`
drops FUA in favour of a periodic SYNCHRONIZE CACHE (1–60 s), or none at all
for a declared-non-volatile cache; both flush on detach, and the UI warns —
honestly, about corruption rather than staleness — every time a target is
moved off write-through. Tests cover the wire behaviour against MockTarget's
volatile cache (`FlushPolicyTests`). What remains open here is measuring the
recovered throughput against real hardware, and it inherits item 3's caveat:
one target, currently a tired one.

## 6. `unregister()` finishing is not launchd finishing

`SMAppService.unregister`'s completion means the daemon process is dead. It does
not mean launchd has released the job: registering immediately afterwards throws
EPERM with nothing recorded. Measured, on an unloaded machine, ~1.4s and three
attempts before it took.

Handled by retrying up to eight times with capped backoff (~6.2s, a 4.4x margin
over what was observed), which is a timing window rather than a signal. If a
future macOS widens it, this returns — and `settle gave up after N rounds` says
so in one line.

Worth checking whether a `SMAppService.status` transition or a Background Task
Management notification can be waited on properly.

---

## 7. Never exercised at all

- **Mutual CHAP.** Implemented, unit-tested, never run against hardware — and
  now known *why*: it could not run. The daemon had no API to store a mutual
  secret, so `CHAP.Credentials.mutualSecret` was nil on every path the app could
  reach, `wantsMutual` was always false, and `verifyMutual` returned
  immediately. The verification code was correct the whole time and simply
  unreachable. There is an API and a UI field for it now, so this is finally
  testable against real hardware; that test has still not been run.

  Found in the security audit (2026-08-16), along with the reason one-way CHAP
  was not working either: secrets are filed under the target record id, and
  login looked them up by CHAP *username*, so the lookup missed — and a missing
  secret was not an error but a silent downgrade to `AuthMethod=None`.
- **Root daemon reading the keychain before login** (R3 in the original plan).
  Only matters if auto-attach at boot is ever built; the daemon currently only
  needs secrets after a user is logged in.
- **The death latch.** Three unanswered daemon calls mark a volume dead and fail
  everything after immediately. Built in response to the eight-hour wedge,
  reasoned about carefully, and never triggered in anger.

## 7a. RFC-compliance strictness deliberately not taken (2026-08-25)

The 2026-08 RFC 7143 review fixed every deviation it found, with four
exceptions left lenient on purpose. Each is overridable if strictness turns
out to matter:

- **Minimum/Maximum result-function validity is not enforced.** A target that
  answers a Minimum key *above* our offer is folded down to `min(ours,
  theirs)` instead of failing the login. Real targets (LIO) echo their own
  configured value rather than the fold; enforcing §13's "selected value
  cannot exceed the offered value" would refuse to log in to them.
  `NegotiationEngine.fold` carries the rationale.
- **Login-phase StatSN tolerance.** A login response that fails to advance
  StatSN is tolerated when its data segment is empty and T=0
  (`LoginStateMachine`); §11.13.4 says every response advances it. Pinned by
  `HostileTargetTests` as deliberate leniency toward non-conforming targets.
- **A `TargetAddress` before any `TargetName` in a SendTargets reply is
  silently dropped** (`Discovery.parse`) rather than treated as an error.
- **CHAP challenge minimum length.** Only non-emptiness and the §12.1.3
  1024-byte cap are enforced; RFC 1994's length recommendations are not.

Also deferred: `expCmdSNSeen` is tracked and unused (nothing hangs off
ExpCmdSN acknowledgment at ERL0).

## 8. Readahead depth is now chosen automatically — measured

Closed, and replaced by a different mechanism than the one this item
anticipated. The full run log is `docs/soak-results-0.4.0.md`.

`PrefetchChunkCache` was soaked at 256 KiB and 1 MiB against real hardware.
Zero mismatches at both sizes, including write-through's read-back path, which
the generation stamps are the sharpest test of. The multi-command split path is
verified too: every 1 MiB request was exactly four 256 KiB SCSI commands
reassembled by index — ~245,000 of them — against hardware that completes out of
order, where before it had only ever run against MockTarget's in-memory pipe.

The tuning question that followed turned out to be the wrong question. A
per-target "type of workload" setting shipped briefly (builds 25–27) offering
1/2/8 MB readahead budgets, then 512 KB/2 MB/4 MB. Measurement killed it:

    depth  budget   unused   wasted/read   hit rate
      2    512 KB     5.9%       0.058x      93.07%
      4      1 MB    11.1%       0.115x      93.06%
     16      4 MB    32.4%       0.443x      93.16%
     32      8 MB    48.8%       0.882x      93.15%

Hit rate is flat across a 16x range of depth, so depth was never buying
residency — only queue occupancy at the target, where speculation that a write
or a seek will discard sits ahead of reads that are real. The only thing depth
reliably changed was wasted bandwidth. A setting whose options differ only in
how much bandwidth they waste is not a choice worth offering a user, so
`ReadaheadDepthController` now sets it: weighted waste over the last three
seconds of *activity* (0.6/0.3/0.1), evaluated once per active second, halving
the cap above 15% and adding one below 6%. Additive increase against
multiplicative decrease, so it converges rather than hunts. It is driven by the
read path rather than a timer, so an idle volume schedules nothing.

Measured end to end: the write-and-seek-heavy soak drives it to depth 3 (8.7%
waste, 93.1% hits, no mismatches); a pure 100 GB sequential pass takes it to the
32 ceiling and holds it there at 99.86% hits and 421 MB/s.

**What is still open here** is the VM verdict — whether a guest's scattered
reads cluster inside 256 KiB chunks well enough to host VMs on Backend A. That
needs a guest, and it has not been run since the chunk cache landed. Nothing
above bears on it: the soak is not a VM, and the controller cannot conjure
locality that isn't there.

**What is settled and must not be "simplified" away:** speculation waste is
counted only when a chunk reaches a terminal state — read before it left the
cache, or evicted having never been wanted. `chunksSpeculated - speculatedUsed`
is the same number minus the window in flight, and the sequential pass measured
that error at *exactly the depth*: 384,582 speculative chunks, cumulative
`unused` up by 32, settled waste 9. Feeding the cumulative figure to a
controller that reduces depth when waste rises inverts the loop — at a VM
guest's ~80 chunks/s, 32 phantom chunks is 40% waste, an immediate halving, and
halving does not shrink the ratio fast enough to escape the ratchet. See
docs/queue-depth.md.

## 8a. The extension's timeout does not know recovery is in flight

**Found by accident, and it failed real I/O.** During a soak the TCP connection
dropped; the daemon recovered in ~12 s across two attempts, and the extension's
fixed 30 s call timeout fired **330 ms before** recovery completed:

    08:21:49.003  recovery attempt 1/5
    08:22:00.170  recovery attempt 2/5
    08:22:00.908  extension: daemon call timed out after 30s   -> EIO
    08:22:01.238  recovered (1 time(s) so far)

The volume survived — one timeout, not the three that latch it dead — but the
caller got EIO for a session that was about to be fine. The two timescales are
independent: the extension counts a wall clock while the daemon is mid-recovery
and about to succeed.

Worth fixing as either a timeout that exceeds the recovery budget, or a signal
that recovery is in progress so the wait can be extended rather than abandoned.
The second is better and costs an XPC message.

Silver lining: this is the first time ERL0 session recovery has run against real
hardware in anger. It worked. `docs/test-playbook.md` had it as MockTarget-only.

## 8b. Re-attach logs a burst of connection-lost/recovered pairs

Reproducible, benign so far, unexplained. Detaching and re-attaching logs three
to five `connection lost (no active connection); recovering` / `recovered`
pairs within 8–14 ms:

    08:52:22.061  connection lost (no active connection); recovering
    08:52:22.065  connection lost (no active connection); recovering
    08:52:22.069  connection lost (no active connection); recovering

Nothing downstream misbehaves, but a teardown that trips the recovery machinery
several times in milliseconds is either wasted work or a sign the teardown order
is wrong, and the death latch counts consecutive failures.

## 9. Deferred

- **Detach offers to eject** (built 2026-08-16, untested in the UI): Detach on
  a mounted volume now asks "Eject and Detach?" instead of silently falling
  through to a force-eject. The menu bar's Eject/Detach All and the updater's
  detach-and-install skip the question — their click is the consent, and the
  alert lives in a window those paths may not have open. Worth one manual
  pass: Detach with a VM running should ask; Cancel must leave it mounted.

- **Tailscale failure modes.** A `newfs_hfs` over Tailscale blocked ~4 minutes
  in uninterruptible wait. Explicitly parked. The wedge fixes in 0.3.6 —
  cancellable sends, a deadline that survives uncancellable work, and the death
  latch — may have fixed it outright, which would be worth confirming before
  investigating further.
- **A clean re-benchmark.** Every number taken after ~09:30 on 2026-08-16 is
  from an array still working through ~50 GB of destructive writes: 157 MB/s at
  queue depth 8 against 1164 earlier. The headline figures predate that and
  should be reconfirmed on a rested target.

  Since sharpened into something stronger, and worse (2026-08-17). Array state
  does not merely add noise to throughput — it dominates it. The *same build at
  the same depth* read 88,506 blocks on 16 August and 212,033 on 17 August, a
  2.4x swing; within one morning a fixed depth moved 48%, and the day's runs
  drifted upward with the clock regardless of what was being tested. A whole
  afternoon's conclusion — "depth 4 gives up 29% of throughput" — was an
  artifact of run order and had to be withdrawn.

  The rule that follows: **one run per setting measures the array, not the
  setting.** Any throughput claim needs interleaving (A/B/A/B inside one
  session) before it is worth writing down. Waste ratios and hit rates, by
  contrast, reproduced to the digit across both days and the 2.4x swing, which
  is why the readahead work rests on those and not on MB/s.

---

## 10. NVMe/TCP: what was deferred (2026-09-01)

NVMe-oF support landed as the NVMe/TCP twin of the iSCSI engine
(`docs/architecture.md`, "NVMeKit"), verified against TrueNAS SCALE 25.10's
`nvmet` from the test VM: discovery, connect with both digests, identify,
namespace listing, reads. What it deliberately does not do:

- **No in-band authentication.** NVMe 2.0's DH-HMAC-CHAP (TP 8006) is not
  implemented; a subsystem that demands it gets a clear error ("turn off host
  authentication for this subsystem"). Access control is the subsystem's
  allowed-hosts list, keyed on the host NQN the app shows. Same threat model
  the README states for iSCSI: a trusted segment or a tunnel. Unlike item 3b,
  this door is real — NVMe/TCP has a standard TLS 1.3 profile (TP 8011) and
  `nvmet` supports it — so both are worth doing when a target insists.
- **One I/O queue.** More would need a connection and a CID space per queue.
  Nothing measured yet says the single queue is the ceiling; the iSCSI side
  is single-connection for the same reason and reaches line rate.
- **No Abort.** `nvmet` does not implement Abort usefully, so a command that
  outlives its deadline drops the queue pair and the next command rebuilds it
  — the NVMe form of the iSCSI task-timeout policy.
- **Discovery on the data port.** The IANA discovery port is 8009; TrueNAS
  serves discovery on 4420 and leaves 8009 closed, so the app's default
  follows TrueNAS. Ask the user for the port, as with iSCSI.
- **Both queues go down together.** Losing either connection destroys the
  controller. Reconnecting an I/O queue to a surviving admin queue would be
  cheaper; it has not been needed.
- **`nvmet`'s SUCCESS flag.** It sets SUCCESS on the last C2HData only when
  the host disabled SQ flow control at Connect (CATTR), which this initiator
  never does; the flag is still handled, and the mock can emit it.
- **Untested against anything but `nvmet`.** As item 3 says of iSCSI. Other
  targets may pad data (CPDA ≠ 0, refused here as Linux does), advertise
  ICDOFF ≠ 0 (every write then goes by R2T), or set MDTS.
- **Namespaces with per-block metadata** (LBAF with MS ≠ 0) are refused with
  a geometry error; a zvol never has them.
- **ANA / multipath** is ignored: one portal, one path.
- **Host identity is the platform UUID's derivative.** A VM cloned with its
  UUID presents the same host NQN. `removeAllData` does not touch it.

## A note on method

Four things were got wrong during this work and three had the same cause:
inferring a number instead of asking the code for it. FSKit's request size was
derived from throughput arithmetic and was wrong twice; the reinstall bug was
theorised about through two failed fixes; the extension was believed silent when
the queries were malformed.

A fifth, on 2026-08-17, had a different cause and is worth its own line:
comparing measurements taken at different times and calling the difference a
result. Depth 4 looked 29% slower than depth 16 because it ran an hour earlier
on a colder array. The tell was there and was noticed and was then
under-weighted — the caveat had already been written down before the run. When
one number in a table comes from a different hour than the others, it is not in
the same table.

A sixth, later the same day, is the most useful of them: **a probe that does not
reproduce the process context measures the probe.** No CHAP secret had ever been
saved, and a probe run under `sudo` reproduced the failure as `-34018`
(`errSecMissingEntitlement`), which pointed convincingly at `iscsid` having no
`CODE_SIGN_ENTITLEMENTS` in `project.yml` while every other target has one. That
was wrong. `sudo` inherits the user session, so the probe had a `secd` to talk to
and failed the entitlement check first. The daemon, in the system domain, gets
past that check and finds `com.apple.securityd.xpc` absent from its bootstrap
namespace — `-25291`, `errSecNotAvailable`. Same call, same uid, two different
errors, and only the second one is the bug: the data-protection keychain is
served by a **per-user agent** and a LaunchDaemon cannot use it at all, ever.
Secrets now go to the System keychain (`KeychainStore.swift` carries the detail).

The tell was available and was not read: the probe was root-in-a-user-session,
which is not the thing being debugged. What settled it was the daemon logging its
own `OSStatus` — the same move as the other five.

Each was solved within minutes of making the code report what it was doing. The
diagnostics in `DaemonStore.summary` and `DaemonController` exist for that
reason, and `docs/queue-depth.md` records the measurement traps — reading
unwritten LUN regions, reading back zeros, and benchmarking the page cache —
that produced confident, plausible, wrong numbers without ever failing loudly.
