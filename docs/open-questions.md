# Open questions

Things known to be untested, unexplained, or deferred, with what is known about
each and how to attack it. Ordered by what a failure would cost, not by how
interesting it is.

Current as of 0.3.8 (build 21), 2026-08-16.

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

## 8. The chunk cache is built and unmeasured under load

Both problems the second VM run isolated — size-change discards throwing away
real sequential windows, and the ~80 reads/s serial round-trip floor that
made a guest boot take minutes — are now addressed by one mechanism:
`PrefetchChunkCache` (see the end of docs/queue-depth.md). Reads are served
by range from 256 KiB chunks, misses read-around and populate a 32 MiB LRU
cache, and speculation is chunk-wise behind the existing byte gate.

**The miss latency has never been attributed.** The ~11–12 ms per cache miss
was reasoned about as XPC + SCSI round trips, but the target is a RAID-Z1
vdev on spinning disks, whose random small-read ceiling is roughly one
disk's worth of seeks — 100–150 IOPS at 7–10 ms each. The observed 45–55
misses/s fits a seek-bound array at least as well as it fits a
software-bound stack, and the 2.7 ms round trip measured earlier was
*sequential* 256 KiB, which ZFS prefetch and ARC flatter. If the array owns
most of the miss, no initiator architecture — Backend B included — makes a
scattered-read boot fast on this pool, and an SSD pool (or a ZFS
special/L2ARC vdev) changes the story more than any code here. Two cheap
discriminators: give `iscsictl read-bench` a random-offset mode and measure
16 KiB random reads at queue depth 1 straight against the LUN (bypassing
FSKit, XPC, and the cache — ~3 ms says the stack, ~10 ms says the array);
or watch `zpool iostat -v 1` on the NAS during a VM boot and see whether
the disks are pegged at their seek rate.

What is owed now is measurement, not mechanism:

- **The VM verdict.** Under the guest workload, `cache=%` should multiply
  and misses collapse *if the guest's reads cluster within 256 KiB chunks*.
  If they genuinely don't — hit rate stays low and `readAround=` shows bytes
  paid for nothing — the honest conclusion is that Backend A's one-op-at-a-
  time delivery cannot host VMs, and the answer is architectural, not more
  readahead tuning.
- **The sequential regression check.** `readahead-soak.py` at 256 KiB and
  1 MiB against the build-16 numbers (1099 MB/s, 92% hits). The soak
  **writes**, so it runs on the test-rig scratch volume, never on a volume
  holding real VM images.
- **Coherence under the soak.** Write semantics have now changed twice:
  first drop-the-overlap, now write-through — acknowledged bytes are patched
  into overlapping cached chunks (`didWrite`), with drops only for pending
  fetches and failed writes (single-initiator assumption, stated in
  queue-depth.md). The soak's write-then-read-back and generation stamps are
  the sharpest test of this — under write-through the read-back is served
  from the patched cache, so a patching bug is exactly what the generation
  stamps would catch. It has not run against the chunk cache yet.

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

---

## A note on method

Four things were got wrong during this work and three had the same cause:
inferring a number instead of asking the code for it. FSKit's request size was
derived from throughput arithmetic and was wrong twice; the reinstall bug was
theorised about through two failed fixes; the extension was believed silent when
the queries were malformed.

Each was solved within minutes of making the code report what it was doing. The
diagnostics in `DaemonStore.summary` and `DaemonController` exist for that
reason, and `docs/queue-depth.md` records the measurement traps — reading
unwritten LUN regions, reading back zeros, and benchmarking the page cache —
that produced confident, plausible, wrong numbers without ever failing loudly.
