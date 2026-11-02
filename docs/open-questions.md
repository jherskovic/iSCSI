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

## 3c. Login redirects are followed, but never against a target that sends one

An EqualLogic group answers every normal login on its group address with
0x0101 "moved temporarily" and a member port's `TargetAddress`. Until
2026-10-07 the session surfaced that as an error, so no EqualLogic volume could
attach at all. The first report from an EqualLogic user was an access-control
refusal (0x02/0x02) logged against 192.168.1.30; if that is the group address,
the array checks access before it redirects. Inferred from that one log line,
not observed.

Logins now follow up to four hops, through `RedirectingLogin`, which both
`ISCSISession` and iscsictl's bare-connection commands use. A temporary
redirect applies to that login only, so recovery asks the configured portal
again; a permanent one is remembered for the rest of the session (§11.13.5),
never written to the record. The daemon connects to the new address with the
target's interface pin. `LoginRedirectTests` drives all of it against
MockTarget, and two `iscsi-target-sim`s (one with `--redirect-to`) drive
iscsictl over real TCP; both redirect on the first request. Not known: whether EqualLogic redirects before or after the CHAP
exchange (the state machine accepts a redirect at any stage), and what it does
when a member port goes away under a session — it asks the initiator to log
out and back in, which recovery should handle by returning to the group address.

**How to test.** An EqualLogic (or any target that redirects) with CHAP on.
The `auth:` log category records each redirect with its address.

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
  `iSCSIFSExtension.swift`). Re-checked on macOS 27.2 with both attach
  engines, 2026-11-01: still none (`docs/backend-a-fskit-notes.md`, "there
  is no barrier signal"), or
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
  needs secrets after a user is logged in. Attach at login was built
  (2026-10-22) in the app, after login, through the user's `fskit_agent`, so
  this stays moot
  (`docs/superpowers/specs/2026-10-22-auto-attach-at-login-design.md`).
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
the cap above 15%, adding one below 6%, and — since 0.7.0 — doubling it below
2%, so a clean stream reaches the ceiling in seconds rather than the ~24 that
+1 per second took (`docs/queue-depth.md`, "The controller"). Additive increase
against multiplicative decrease for anything that wastes, so it converges
rather than hunts. It is driven by the read path rather than a timer, so an
idle volume schedules nothing. On hardware (0.7.1 RC2, 2026-10-05, SIP-off VM
to the NAS over NVMe/TCP): an 8 GiB sequential read of the raw image ran at
its plateau (~700 MB/s) from the first one-second sample, and the unmount
summary showed `maxDepth=32 cap=32` with no speculation wasted.

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

## 8c. Three faults a live-NAS soak exposed — two fixed with tests, watch items noted (2026-09-11)

`docs/resilience.md` ("Three defects a live-NAS soak exposed") has the full
account. Fixed: recovery now **latches** after exhaustion in both engines
(§8a's "latch it dead" is now real), a dead client's XPC connection **releases
its sessions** (closes the leak that §8a's extension-timeout interacts with),
and the app's **blocking `attach`/`detach` subprocess calls now run off the
main actor** (the fix that stops the beach-ball — see the correction below).

Still open, in cost order:

- **The app-freeze fix was first pointed at the wrong function; now corrected,
  measured at the subprocess level, not yet sampled app-level.** The first fix
  moved `reconcile` off the main actor on the inferred belief that its `hdiutil
  info` call blocked. Measured on the SIP-off rig `herko@192.168.0.39`
  (2026-09-11) that is false: under a `pfctl`-wedged NAS, `getmntinfo`,
  `hdiutil info` and `statfs` all return at once, while `diskutil unmountDisk`
  and `hdiutil detach` hang indefinitely. Those hanging calls are in `attach`
  and `detach`, which ran synchronously on `@MainActor` — that is the real
  beach-ball (a Detach tap, or a `volumeDisappeared`-triggered detach on a
  wedged mount). The corrected fix moves `attach`/`detach`'s subprocess
  sequences onto detached tasks too; `reconcile`'s split is kept as hygiene.
  `resilience.md` §c has the measurement table. The app-level before/after
  (sample the app's main thread during a wedged attach/detach) was **attempted
  on .39 2026-09-11 and could not be completed**: the app there was placed by
  rsync, not installed from the DMG via Finder, and `FSClient.installedExtensions`
  (ExtensionKit) will not enumerate an appex placed that way, so the app is stuck
  on its Setup screen ("Filesystem extension registered" never goes green) and
  never lists an attachment to detach — even though `mount -F` resolves the
  module fine through the other code path. `lsregister -f -R -trusted` (the
  programmatic equivalent of the Finder drag), a reboot, bouncing pkd/fskitd,
  and removing a duplicate appex bundle (`/Applications/iSCSIApp.app`, which
  shipped the same module id) all failed to register it. This is a test-rig
  install artifact, not a product defect — a DMG-installed build registers
  normally — and it is orthogonal to the freeze fix. A clean app-level sample
  needs a Finder-installed build on a rig that can be wedged; that rules out the
  SIP-on acceptance box. The `attachmentsGeneration` resurrection-race guard
  (from making `reconcile` async) is now load-bearing, since `attach`/`detach`
  suspend too.

  **The Setup screen had the same bug (found 2026-10-04, fixed in 0.7.0 build
  41).** The "Register" step ran `lsregister -f -R -trusted` with
  `waitUntilExit()` on the main actor. On the SIP-off rig (now `.33`) just after
  boot — load ~20, the virtual disk saturated by boot-time indexing —
  `lsregister` ran for over 2.5 minutes and the window froze for all of it,
  even though `pluginkit` already listed the module as registered and enabled.
  It and the uninstaller's `pluginkit -r` now run on detached tasks; every
  subprocess the app waits on is off the main actor.
- **Latch has no self-heal, and it fails fast into the extension.** After
  recovery exhausts, the session stays dead until an explicit re-attach; an
  outage that outlasts five attempts will not reconnect on its own. The latch
  changed the *timescale* the extension sees, not just the eventual outcome:
  before it, each new I/O re-entered recovery and a returning NAS could heal
  the mount transparently after the window; now the daemon returns the failure
  **instantly**. A speculative readahead that gets that instant error is
  indistinguishable from an unanswered one at the cache boundary, so it counts
  toward the death latch — three of them mark the volume dead within a few
  operations and the extension unmounts, where a ~70 s blip used to self-heal.
  Direct reads/writes throw the error straight to APFS rather than tripping the
  latch, but the user-visible result is the same: exhaustion now means a fast
  unmount and re-attach, not a beach-balled heal. A background retry with capped
  backoff that clears the latch on success is the follow-up, and this combined
  effect is the reason to weigh promoting it from deferred before shipping.
  Today a re-mount is the recovery.
- **Flush-tick log after the latch.** Once latched, the periodic flush fails
  fast (no network, no recovery), but still logs one line per 30 s tick until
  the extension unmounts. How long that takes now depends on the traffic: read
  traffic trips the extension's death latch in a few operations, an idle mount
  much later or not until something else tears it down (the old "~90 s" estimate
  predated the fast-fail latch and is no longer reliable). Bounded, cosmetic;
  log once per dead session or stop the timer.
- **Flush vs. task timeout, still unmeasured.** The 2026-09-11 loss was a Keep
  Alive timeout as the NAS died, **not** a Flush outrunning the 30 s task
  timeout on a healthy target (that earlier claim was inferred from timing and
  the log refuted it). Whether a loaded-but-healthy NAS can take >30 s to
  SYNCHRONIZE CACHE, and whether the flush path should get its own longer
  deadline than a read/write, is untested. A watch item, not a known bug.

## 9. Deferred

- **Detach offers to eject** (built 2026-08-16, untested in the UI): Detach on
  a mounted volume now asks "Eject and Detach?" instead of silently falling
  through to a force-eject. The menu bar's Eject/Detach All and the updater's
  detach-and-install skip the question — their click is the consent, and the
  alert lives in a window those paths may not have open. Worth one manual
  pass: Detach with a VM running should ask; Cancel must leave it mounted.
  **Changed 2026-11-02, also untested in the UI:** consent to eject is no
  longer consent to force. Every detach is now plain first and verified
  afterwards (the device and the FSKit mount actually gone); a refused one
  throws instead of reporting success, and the attachment stays listed with
  whatever is still up. From the Detach buttons, the menu bar and
  "Detach and Install", a volume still in use gets Finder's question — a modal
  "Force Eject?" that defaults to Cancel. Target removal and uninstall never
  force; uninstall stops before deleting anything if a volume will not
  detach. A Finder eject forces only the layers beneath filesystems Finder has
  already unmounted (the wedged-image escape in docs/resilience.md). The
  updater now waits on *any* attachment or attach/detach in flight, not just
  a mounted filesystem. The manual pass: a Terminal `cd`'d into the volume
  should produce the Force Eject question naming Terminal; Cancel must leave
  the row attached; uninstall with it open must stop at step 1.
  **Passed 2026-11-02 on the macOS 27.2 VM (build 52.5):** the Force Eject
  question for a Terminal `cd`'d into the volume, Cancel leaving it attached,
  and uninstall stopping at step 1. On the macOS 26.7.2 VM (build 52.5) the
  Force Eject question, Cancel, and uninstall stopping at step 1 all passed
  the same day.

- **One disk, one writer** (built 2026-11-02, untested in the UI). Nothing
  stopped a LUN from being attached twice — by a second account under fast
  user switching (the login run checked; a manual Attach did not), or by the
  same account after editing an attached target's address, name or LUN, which
  moved its mount point and left the old mount running with no row to detach
  it. Two attachments are two filesystems writing one disk. Now: every attach
  checks the mount table for another mount of the same name and unit
  (`AutoAttachRun.otherMount`); the daemon holds each unit for the life of
  the extension's session and refuses a second (`DaemonCore.claimedUnits`,
  waiting up to 10 s for a claim a detach is still releasing); the editor
  locks address, port, name and unit while the target is attached or has a
  session; and the mount check lists this user's orphaned mounts under Other
  Attached Disks with an Eject button. Rows with only some layers up (a blank
  LUN's device) now offer Detach rather than Attach. The manual pass: edit an
  attached target and the fields should be locked; with a hand-made orphan
  (`mount -F` at a stray tag directory) the orphan should be listed and eject.
  **The editor lock passed 2026-11-02 on the macOS 27.2 and 26.7.2 VMs (build
  52.5), and the orphan listing on the 26.7.2 VM:** a hand-made `mount -F` at a
  stray tag directory was listed under Other Attached Disks and ejected. The
  daemon's claim held on the same VM: a hand `mount -F` of a LUN the app had
  attached (`iscsi://192.168.20.1/…/0`, session s5), spelled with an explicit
  `:3260`, logged `refusing a second session … held by s5` after the 10 s
  wait and failed in `loadResource` with "already attached on this Mac".
  mount(8) itself prints only a generic failure; the words reach the user
  only through the app's own pre-check. The second-account refusal is
  untested.
- **Who may use the daemon** (an external audit's S-01, deferred). The daemon
  checks the calling app's signature, not the calling user, and the target
  list and secrets are machine-wide. On a Mac with more than one account any
  account can attach, edit or delete every target and use its saved secret.
  The double-attach half is closed above; the rest needs a decision on
  whether shared Macs are supported. If they are: an optional owner on each
  record (old `targets.json` must still decode), the caller's UID from the
  connection, admin authorization for configuration changes and
  `removeAllData`, and a narrower interface for the extension.

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
`nvmet` from the test VM with `iscsictl nvme`: discovery, connect with both
digests, identify, namespace listing, reads at queue depth 8, writes by every
path (in-capsule, R2T-solicited, a 1 MiB write pipelined as four commands),
FUA and Flush with byte-exact readback, and Keep Alive carrying a session
past KATO. Then through the shipping stack on the SIP-off VM
(`scripts/vm-nvme-verify.sh`): `mount -F` with an `nvme://` URL, `hdiutil`,
APFS on the NAS namespace — integrity after a cache purge, fsync'd files,
`verifyVolume` clean, the daemon logging `write cache ENABLED, write-through
(FUA)` — and the crash-consistency pair against `iscsi-target-sim --nvme`:
write-through lost 0 blocks and verified 32/32 files after the target's
power cut; the no-flush control lost 9192 blocks and the volume with them.
Then six hours of verified mixed I/O on that path (`docs/soak-nvme-2026-09-01.md`):
3.5 M verified reads, 0 errors, 0 connection losses, memory flat.
What it deliberately does not do:

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
  follows TrueNAS. Ask the user for the port, as with iSCSI. Discovery
  leaves out entries whose TRSVCID is not a decimal port (NVMe/TCP 1.1
  §3.1.2) and ports whose TREQ says TLS is required, since there is no TLS
  here to offer them; a NAS that turns TLS on for a subsystem makes it
  vanish from the list rather than fail at attach.
- **Both queues go down together.** Losing either connection destroys the
  controller. Reconnecting an I/O queue to a surviving admin queue would be
  cheaper; it has not been needed.
- **`nvmet`'s SUCCESS flag.** It sets SUCCESS on the last C2HData only when
  the host disabled SQ flow control at Connect (CATTR), which this initiator
  never does; the flag is still handled, and the mock can emit it.
- **Untested against anything but `nvmet`.** As item 3 says of iSCSI. Other
  targets may pad data (CPDA ≠ 0, refused here as Linux does), advertise
  ICDOFF ≠ 0 (every write then goes by R2T), or set MDTS. Two paths were
  audited against the NVMe/TCP 1.1 text on 2026-09-10 and have only ever
  run against the mock, because `nvmet` never exercises them: decoding a
  conformant C2HTermReq (no digests, data at byte 24 — `nvmet` closes the
  socket instead of sending one) and the non-fatal data digest path
  (`nvmet` sends one C2HData per read and corrupts nothing).
- **Namespaces with per-block metadata** (LBAF with MS ≠ 0) are refused with
  a geometry error; a zvol never has them.
- **ANA / multipath** is ignored: one portal, one path.
- **Host identity is the platform UUID's derivative.** A VM cloned with its
  UUID presents the same host NQN. `removeAllData` does not touch it.

## 11. Interface pinning (0.7.0): what is unverified

Built and unit-tested; the binding mechanism was measured on the dev host
(`docs/superpowers/specs/2026-10-02-interface-pinning-design.md`). Not yet run:

- **Prefer mode's fallback, on the VMs.** Strict was run end to end on the
  SIP-on 26.6.2 VM with 0.7.1 RC2 (2026-10-05): name-testing pinned strict to
  `en2`, `connected via en2`; `en2` down for 30 s under a read loop — loss
  noticed 13 s in, recovery attempt 1/5, attempt 2/5 at its 10 s deadline,
  `en2` back, `connected via en2` and `recovered` 2 s later; the volume stayed
  mounted and a file written afterwards read back identical. Prefer's fallback
  and the Sessions window's fallback line are still unrun: that VM's other
  network has no route to the NAS.
- **IPv6.** Names are resolved before binding and the family follows what the
  interface holds, but nobody has an IPv6 portal to try it on.
- **No migration back.** A prefer-mode session that fell back stays on its path
  until its next reconnect. Deliberate; worth revisiting only if someone
  notices a session parked on Wi-Fi.

## 12. Local disk cache (0.7.0): what is unverified

Built and tested against an in-memory daemon and an in-memory cache file
(`docs/superpowers/specs/2026-10-02-local-disk-cache-design.md`). Not yet run:

- **On hardware, with the cache on — done (0.7.1 RC2, 2026-10-05).** A 4 GB
  cache on name-testing, SIP-off VM: `readahead-soak.py` for 600 s over its
  2 GiB region, **no mismatches** (25,347 runs, 11,472 interleaved writes,
  9,210 seeks, ~240 GB read), `diskCorrupt=0`, 894,060 of 1,008,956 lookups
  served from the local tier.
- **Whether it pays.** On a working set that fits — the soak's — it serves
  most reads (`diskSaved` 234 GB in 10 minutes). Unmeasured on a real one: the
  long VM session and a run over Tailscale; if they barely move `diskSaved`,
  the segmented-LRU split (80% protected) and the admission rule are the first
  suspects, not the size.
- **A new extension against an old daemon — found and fixed at the 0.7.1 RC.**
  The extension updates with the app; the daemon stays the old one until Setup
  reinstalls it. With the 0.7.1 extension and the 0.6.1 daemon (2026-10-05,
  SIP-off VM, `mount -F` before Reinstall), asking for the cache size — a
  method 0.6.1 does not have — made NSXPC drop the connection, the daemon
  logged out the session it carried, and every read failed with EIO after a
  5 s stall. The extension now asks `daemonInfo` first and asks for the cache
  only from build 40 on (`DaemonCapabilities`). Verified with 0.7.1 RC3
  (build 47) against the same 0.6.1 daemon: mounted in 0.05 s, logged "local
  cache not asked … 0.6.1 (39) predates it", read at 634 MB/s, and a 1 MiB
  write read back identical past the page cache. Any XPC method added later
  needs the same gate. The app has the same hazard in `discoverSubsystems`,
  which gained an `interfaceName` argument in 0.7.0; Setup holds the app until
  Reinstall, so it is noted rather than gated.
- **`F_NOCACHE`'s effect** on the tier's own reads is assumed, not measured.
- **Several volumes at 16 GB each** on a small boot disk: each tier is sized at
  attach and re-checks free space every 256 MiB it grows, stopping at the
  10 GiB reserve. Unexercised on hardware.
- **Space back at detach — yes, at once.** `df` 36.94 GiB before the soak,
  35.04 at its end, 36.93 right after the unmount; the same after the app's
  detach of an 8 GiB read.
- **SSD wear, measured.** An 8 GiB sequential read wrote 950 MiB locally
  (`spilled=3798` chunks) — the spill cap sheds most of a bulk read, so a
  100 GB copy does not write 100 GB. The churning soak wrote ~23 GB over its
  10 minutes (`spilled=93785`). Still worth stating before recommending the
  cache for write-heavy or churning workloads.

## 13. A mount refused at login, and a resource FSKit never lets go of

Seen twice at a login on the 26.6 VM (SIP on, 2026-10-22, attach at login).
Each time, the account's `fskit_agent` had outlived its previous logout.

1. **10:53:59 — the first `mount -F` after login failed.** `fskit_agent`
   survives logout. Its launch of the extension went through
   `com.apple.extensionkitservice` (pid 945, started at boot), and the launch
   failed with "connection to service with pid 945 … was invalidated"
   (ExtensionKit error 2). The mount reported "File system named iSCSI not
   found".
2. **10:54:13 — the retry's activate was refused.** The extension launched,
   `loadResource` succeeded and opened a daemon session, then fskitd logged
   "Can't start new task, previous task is running" and `mount` failed with
   `Resource busy`.
3. **From then on, every mount of that resource was refused.** fskitd logged
   "Can't start new task, resource state is 4" at 11:00:27. The instance kept
   the loaded resource and the session with nothing mounted. FSKit never sends
   `unloadResource`, not even on a normal detach.

The extension now exits when no `activate` follows a successful load within
30 s (`ActivationWatch`). Every measured activate came 4–13 ms after its
load (868 ms at boot). **Verified, 2026-10-22 15:31**: the fault recurred on a
login, and the guard handled it.

- 15:31:46: testb's `fskit_agent` failed to launch the extension through a
  launcher killed at the previous logout.
- 15:32:05: fskitd refused the activate.
- 15:32:20: a retry was refused with "resource state is 4".
- 15:32:35: the extension exited.
- 15:32:38: fskitd logged "Instance died".
- 15:32:51: the next attempt loaded, activated and attached.

A login costs about 65 s when this happens (launch failure 15:31:46 to
attached 15:32:52), and needs no window. One attempt
that raced the exit was refused, which is harmless.

It cannot be reproduced from ssh. Killing the launcher gives "Connection
interrupted", and launchd respawns it on demand. A stopped launcher is reaped
before a mount reaches it. Only a logout leaves the connection
*invalidated*. Grep after logins:

```sh
/usr/bin/log show --last 1h --predicate 'process == "fskitd" AND (eventMessage CONTAINS "previous task is running" OR eventMessage CONTAINS "resource state is")'
/usr/bin/log show --last 1h --predicate 'subsystem == "me.herko.iSCSIInitiator.fsext" AND eventMessage BEGINSWITH "no activate"'
```

The same login made a second fault visible. Attach at login read a daemon
session for the target as another user's, so the stranded session showed as
"In use by another session on this Mac" on every retry. "In use elsewhere"
now comes from the mount table instead (`AutoAttachRun.isInUseElsewhere`).

## 14. Enabling the extension for one account disconnects every account's volumes

On macOS 26.x the FSKit switch in System Settings does not move. Setup
therefore writes the enablement entry itself, then has the daemon run
`killall fskitd` (`refreshFSKitEnablement`) so the change takes effect. That
kill reaches every user. Seen on the 26.6 VM, 2026-10-22, with two accounts:

- 14:02:01: a second account's first-time Setup restarted fskitd. The first
  account's `fskit_agent` logged "exiting as fskitd died". The FSKit layer
  under its attached name-testing went with it.
- 14:04:46: `hdiejectd` failed to unmount that APFS volume (EIO).
- 14:04:54: a second attempt succeeded, and the image was detached.

Whatever that volume had not yet written was lost, as in a target power cut.
On 26.x the FAT and exFAT drivers are FSKit modules too (`com.apple.fskit.msdos`
shows in the same logs), so other accounts' USB drives are probably exposed as
well. That part is inferred, not observed. The consent prompt says nothing
about either.

One account is safe in practice: the extension cannot have mounted anything
while it was disabled for that account. The hazard is a Mac with several
accounts, which attach at login now makes ordinary.

To fix, in its own branch: before asking for the restart, read the mount table
(`AttachmentManager.mountTable()`) and refuse, with an explanation, while any
FSKit volume of any account is mounted. Also warn in the consent prompt.
Restarting the Mac remains the safe way.

## 15. LIO's placeholder LUN 0, when nothing at all is mapped

GitHub #3 (Synology DS423+, DSM 7.4.1, 2026-10): a 1 TB LUN attached as a
**32768-byte** disk — 64 × 512, which the app then offered to format. That
number is Linux LIO's "virtual LUN 0", an `rd_pages=8` ramdisk the target
answers LUN 0 with whenever the initiator has no LUN mapped there. Synology
numbers mapped LUNs from 1; TrueNAS maps the first extent at 0, which is why
it never showed up here. The placeholder's READ CAPACITY is perfectly valid,
so the geometry check passed it. It is write-protected in LIO, so the
reporter's data was never at risk — only the diagnosis was.

Since then `DaemonCore.login` runs REPORT LUNS and refuses a LUN the target
does not list, naming the ones it does (`DaemonUnitError`,
`loginRefusesLUNTheTargetDoesNotReport`), and the target sheet has a Find
button that asks the target what it has (`listUnits`, a session the daemon
opens and closes itself) and fills the field when there is one answer. Newer
kernels also mark the placeholder "not connected" in INQUIRY; DSM 7's does
not.

**What this does not catch:** a target with *no* LUN mapped for this
initiator. LIO's REPORT LUNS then lists LUN 0 — the placeholder itself — and
the login proceeds to a 32 KiB disk exactly as before. The honest next check
is INQUIRY: the placeholder identifies as `LIO-ORG` / `RAMDISK-MCP` (or the
`not connected` peripheral qualifier on kernels new enough to set it), while
a Synology LUN identifies as `SYNOLOGY`. Unverified against a real Synology;
the reporter's retest with LUN 1 is what will confirm the diagnosis above.

## 16. Read-around chosen per workload (unreleased): what is unverified

`ReadAroundController` replaced the fixed 256 KiB miss fetch after issue #4
(`docs/queue-depth.md`, "Read-around is chosen, not fixed"). Beyond in-memory
LUNs, it has run against the NAS over 10 GbE twice, both on 2026-10-31:

- **The cache alone**, through `iscsictl nvme cache-bench` over raw NVMe/TCP.
  Random 4 KiB reads went from 62x to 0.97x after one second, and clustered
  and sequential reads were unchanged.
- **Issue #4's fio jobs through a mounted volume**, against the installed
  0.8.0. The wire went from 62x to 0.94–1.56x on the random-read jobs (the
  1.56x includes the reads before the switch), and QD1 went from 382 to 606
  IOPS. Sequential reads were unchanged at 1.01x.

Not yet run:

- **Issue #4's matrix on 2.5 GbE**, the reporter's link, where each 256 KiB
  fetch cost four times as long on the wire. Expect the same ratios and a
  larger IOPS gain than on 10 GbE. Either way, IOPS stay bounded by the serial
  delivery in item 17, which is now the ceiling.
- **The VM boot, to check for a regression.** The run that justified
  read-around (54–56% hits, `readAround` ~3 GB against 549 MB served). The unit
  should stay at or near the whole chunk, and the boot should take no longer.
  If it drops to a small unit and the boot slows, the 128 KiB `roundTripBytes`
  is too low for that link, or the ghost undercounts that workload's reuse.
- **`roundTripBytes` is chosen, not measured.** 128 KiB is about one round
  trip on the reporter's link. On 10 GbE a round trip is worth nearer 1 MiB,
  so there the controller errs towards less traffic over fewer round trips. If
  that costs a 10 GbE user, measure the figure per mount: time `rawRead` calls
  of different sizes and fit fixed cost against per-byte cost.
- **The ghost leans towards large units.** It holds as many chunks as the real
  cache holds whole chunks, which is exact for the whole-chunk unit. Smaller
  units fit more entries, so some of their simulated misses would really have
  been hits. That is deliberate (it favours the behaviour that was measured),
  but it means the controller shrinks later than it could.
- **Disjoint pieces replace each other.** One range per chunk keeps coverage a
  comparison. A workload that keeps returning to two far-apart spots of one
  chunk, at a unit below the chunk, refetches them alternately. The controller
  should price that and pick the whole chunk; unmeasured.

## 17. Whether anything above the extension can issue reads concurrently

Issue #4 also measured QD16 at the same IOPS as QD1, with latency growing with
depth (3.1 → 45 ms): strictly one read at a time. `docs/queue-depth.md`
("Measured: the shipping path is serial") concluded that FSKit does not issue
concurrent reads, but that was measured with **one sequential reader**, which
never has two reads outstanding. It shows the path was serial for that caller,
not that FSKit serialises concurrent callers.

**Confirmed through a mount, 2026-10-31** (`docs/queue-depth.md`, issue #4's
fio jobs). With the amplification gone, QD1 gave 606 IOPS, QD16 574 and eight
`psync` threads 555. Latency grew with depth: 1.65 ms, then 27.9 ms (about
16 × 1.74 ms), then 14.4 ms (about 8 × 1.8 ms). With read-around fixed,
whatever serialises sets the ceiling: about 600 IOPS on 10 GbE.

Ruled out by measurement: the cache and the NVMe/TCP path under it. Over raw
NVMe/TCP, eight threads drove them to ten times the reads per second of one.
Ruled out by reading the code: `LUNStore`, which holds no lock across a read
(`ioLock` covers writes only).

Not in that bench, but built not to serialise: `DaemonStore`, XPC and the
daemon's service. Each call blocks only its own thread on a semaphore. The
daemon answers each call from its own `Task`. `DaemonCore.read` suspends at
its `await`, so the actor lets the next read in.
`readsOnDifferentChunksAreInsideTheDaemonAtOnce` now pins `DaemonStore`'s
part. It holds eight readers inside a fake daemon until the eighth arrives.

**Answered, 2026-10-31: there are two serialisers, and our handler is the
first.** The method:

- one build with a hidden switch: `?reads=async` on the mount URL makes
  `read(from:…)` return at once and reply from a concurrent queue;
- `inflight=<store reads>/<daemon reads>` in the summary, the most of each
  ever in flight at once;
- fio 4 KiB randread, `psync`, QD1 and eight threads, on name-testing over
  10 GbE, each layer in its own mount.

| layer | handler | QD1 | 8 threads | inflight |
|---|---|---|---|---|
| `lun0.img` (FSKit only) | blocking | 543 IOPS | 651 IOPS, 12.3 ms | 1/1 |
| `lun0.img` (FSKit only) | async | 531 IOPS | **9,820 IOPS, 0.81 ms** | **8/8** |
| `/dev/rdiskN` (DiskImages + FSKit) | blocking | 611 IOPS | 561 IOPS, 14.2 ms | 1/1 |
| `/dev/rdiskN` (DiskImages + FSKit) | async | 692 IOPS | 583 IOPS, 13.7 ms | **1/1** |
| APFS file (all of it) | blocking | 624 IOPS | 570 IOPS, 14.0 ms | 1/1 |
| APFS file (all of it) | async | 633 IOPS | 591 IOPS, 13.5 ms | 1/1 |

- **FSKit waits for the handler to return, not for its reply.** With the
  blocking handler it never handed over a second read. Replying
  asynchronously, it handed over eight at once, and `lun0.img` went from 651
  to 9,820 IOPS on eight threads. So the earlier finding that "FSKit does not
  issue concurrent reads" was the handler.
- **DiskImages is the second serialiser, and it alone sets the ceiling
  through a mount.** With async replies, the raw device and APFS still never
  had more than one read in flight. The `hdiutil` CRawDiskImage attach reads
  its backing file one request at a time. Async replies change nothing users
  see today: 591 against 570 IOPS is noise.
- **Async replies returned correct data.** `FSMutableFileDataBuffer` stayed
  valid until `reply` in every read checked: 117,338 random-size, unaligned
  reads from eight threads through `lun0.img`, and 9,590 through APFS, byte
  for byte against reference copies taken in blocking mode, no mismatches.
  That is evidence, not Apple's documentation.
- **Per-read cost is mostly not DiskImages or APFS.** QD1 is 1.6–1.9 ms at
  every layer, `lun0.img` included, against about 0.55 ms on the raw NVMe/TCP
  path. So FSKit, the extension, XPC and the daemon cost about 1.1–1.3 ms per
  read. Under eight-way load the mean fell to 0.81 ms per read, so much of
  that may be idle wake-up rather than work. Unmeasured.

**A different attach path does read concurrently, 2026-10-31.**
`diskutil image attach` (which `hdiutil` now says replaces `hdiutil attach`)
was run on the same build, read-only, against the raw device. The reads were
random 4 KiB over the first 256 GiB with no warm pass, which is cold for both
this Mac's page cache and the NAS's ARC. One mount per job:

| `diskutil image attach` | QD1 | 8 threads | inflight |
|---|---|---|---|
| blocking handler | 242 IOPS, 4.13 ms | 322 IOPS, 24.8 ms | 1/1 |
| async handler | 358 IOPS, 2.79 ms | **2,071 IOPS, 3.86 ms** | **8/8** |

- **Concurrency reaches the extension only with both changes:** this attach
  path, and async replies. Either alone stays serial. The absolute numbers are
  not comparable with the table above: that read a warm 1 GiB region, and this
  one read cold blocks the NAS fetched from its pool.
- **This attach reads `lun0.img` through the page cache.** A first run with a
  sequential warm pass measured RAM, not the network: 75,000–190,000 IOPS at
  0.013 ms, with only 1,061 reads reaching the extension. That cuts both ways.
  Re-reads cost nothing, which for a compile rereading `.rlib` files may matter
  more than IOPS. But the volume's data is held twice, once by APFS and once
  under it.
- **It reads whole 16 KiB pages,** arm64's page size. Each 4 KiB fio read
  reached the extension as about 16 KiB (QD1: 3,650 reads, 62.9 MB), so random
  4 KiB reads cost 4x on the wire before read-around adds anything. The
  wire/asked ratios above (5.7–6.7x) also include each fresh mount's first
  second at the whole-chunk unit.
- **Writes: it is a disk with a ~30 s volatile cache in this Mac's RAM.**
  This was checked against `iscsi-target-sim` (NVMe/TCP, file-backed, 512-byte
  blocks, default write-through), whose backing file holds exactly what the
  target has made durable. Each write or sync ran on the Mac, then the probe
  read the backing file the instant the call returned. After that, the target
  was frozen (`pause` new connections, then `crash` the live one) and a
  snapshot of the file was mounted locally and fsck'd: a power cut at that
  instant. Same installed 0.8.0, 2026-10-31:

  | | `hdiutil` (shipping) | `diskutil image attach` |
  |---|---|---|
  | device cache flush (`DKIOCSYNCHRONIZECACHE`) | on target at return | on target at return |
  | APFS `F_FULLFSYNC`, 6 files | 6/6 at return | 6/6 at return |
  | APFS plain `fsync` | 1/6 at return; all within 0.1 s | 0/6 at return; one measured at **27.8 s** |
  | raw write, no sync | within 0.05–0.1 s | **9.8 s**; another still absent at 15 s |
  | snapshot after the freeze | every synced file intact, fsck OK | every synced file intact, fsck OK |

  - **Flushes are honoured on both.** APFS stays crash-consistent, and
    `F_FULLFSYNC` data is durable when the call returns.
  - **Anything short of a full flush waits in RAM for tens of seconds.** That
    includes plain `fsync`, which is what most applications call. Losing the
    Mac (power, panic) or the volume (extension crash, network gone) in that
    window loses data that on `hdiutil` would have reached the NAS within
    0.1 s. Under macOS's contract this is allowed, since `fsync` never
    promised durability. But it is the risk the write-through default exists
    to keep small, and it is the per-target "flush every N s" relaxation's risk
    class, made the default.
  - **The shipping path is not strictly synchronous either.** `hdiutil`
    acknowledges a raw write before the target has it, by about 50 ms, and
    honours flushes. That is a correction to how write-through has been
    described: FUA governs the target's cache, not DiskImages'.
  - **Unverified: what happens to those dirty pages if the target goes away.**
    A page-cache writeback that fails has no caller to tell, so the loss may
    be silent where `hdiutil` would fail the next write. Untested.

**The write window closes if the volume sets the kernel's cache policy
itself, 2026-10-31.** The page cache that held those writes is this volume's
own. On macOS 27, FSKit lets a volume adopt `FSVolume.DataCacheHandler`
(`FSVolumeDataCacheHandler.h`, FSKit V3) and answer the kernel's request for
each item it opens. The experiment build adopts it behind `?cache=writethrough|readcache|nocache`
on the mount URL. While that is absent, `isDataCacheInhibited` keeps FSKit on
`OpenCloseOperations` as before. The final-close flush moved into the
protocol's `close`. The log shows FSKit asking `readWriteWithCache` for the
read-write open of `lun0.img` and the volume granting `writeThrough`. The
same durability check and window probe, against the simulator:

| `?cache=writethrough` | `hdiutil` | `diskutil image attach` | `diskutil`, no grant |
|---|---|---|---|
| raw write, no sync | arrived after 0.06 s | **on target at return** | 9.8 s / >15 s |
| APFS plain `fsync` | 0/6 at return | **6/6 at return** | 0/6, one at 27.8 s |
| APFS `F_FULLFSYNC` | 6/6 | 6/6 | 6/6 |
| snapshot after the freeze | synced files intact, fsck OK | synced files intact, fsck OK | synced files intact, fsck OK |

With `writeThrough` granted, `diskutil image attach` writes more strictly
than the shipping path. Every write reached the target before its call
returned.

Reads, on the cold 256 GiB region of name-testing, with async replies and a
fresh random seed per job, the three grants interleaved twice:

| `diskutil image attach` + async | QD1 | 8 threads | inflight | per read at the extension | wire ÷ fio, 8 threads |
|---|---|---|---|---|---|
| FSKit default | 311 / 313 IOPS | 2,221 / 2,290 IOPS | 8/8 | 16.5 KB | 5.8–6.0x |
| `cache=writethrough` (reads get `readCache`) | 324 / 317 | 2,119 / 2,149 | 8/8 | 16.5 KB | 6.0–6.1x |
| `cache=nocache` | 326 / 357 | 2,161 / 2,175 | 8/8 | **4.2 KB** | **3.8x** |

- **Concurrency survives every grant.** Throughput is equal on cold data,
  where the NAS's disks set the pace.
- **`noCache` removes the 16 KiB page rounding:** the extension saw the 4 KiB
  reads fio made. It also gives up the kernel's read cache, so re-reads cost a
  round trip again. Its write durability was not measured; the header says
  all I/O goes straight to storage.
- **Most of the remaining 3.8x is ours.** It is each 15 s run's first second at
  the whole chunk, plus a near-tie in `ReadAroundController`. Once the unit
  landed on 8–16 KiB, 4 KiB was cheaper by only about 8%, inside the 10%
  hysteresis, so it stayed. One scattered read per chunk costs 1.03 round
  trips at 4 KiB and 1.125 at 16 KiB.
- **A first, unfair run** reused fio's default seed (`randrepeat=1`). Each
  later run then read blocks the NAS had cached during the one before, and
  IOPS rose with run order (3,254 → 4,225 → 5,009). Discarded.

**On macOS 26 the newer engine has the same write window, and nothing
closes it, 2026-10-31.** Measured on 26.6.2 (SIP-on VM, the extension's
local `proto` store, so the store's own file shows when bytes arrive).
Extension unchanged: blocking handler and no cache grant, since
`DataCacheHandler` is macOS 27 only.

| | `hdiutil` | `diskutil image attach` |
|---|---|---|
| raw write, no sync | in the store after 0.06 s | after 2.35 s |
| raw write + `fsync` | after 0.06 s | after 0.77 s |
| raw write + `DKIOCSYNCHRONIZECACHE` | at return | at return |
| same 64 MiB read twice: bytes the extension served | 135.7 MB | 86.1 MB |

Repeated on 26.7.2 (25G332), same VM: `hdiutil` no-sync write at return,
`fsync` 0.06 s, flush at return, 135.7 MB served; the newer engine 1.94 s,
1.29 s, at return, 86.1 MB served. `setBlockSize:4096` still gave a 4096-byte
device with the GPT visible.

The newer engine page-caches `lun0.img` on 26 too. Flushes are honoured;
anything short of one waits. These windows are single samples against a local
store; on 27 the NAS-backed store measured 10–30 s. So "the newer engine
everywhere" would weaken write durability on 26, with no FSKit way to stop it.
Keep `hdiutil` on 26.

**4Kn LUNs: `diskutil` cannot, but the framework under it can.**
`diskutil image attach` has no block-size option, `--help-hidden` included.
On a simulator namespace with 4096-byte blocks it produced a 512-byte device,
although the volume reports `f_frsize` 4096. Dropping the CRawDiskImage key
does not reach the newer engine either: plain `hdiutil attach` still shows the
old DiskImages engine.

But `diskutil` is a client of `DiskImages2.framework`, whose attach request
has a block size. Listing the framework's Objective-C classes at runtime
shows:

- `DIAttachParams : DIBaseParams` (`initWithURL:error:`, `setAutoMount:`);
- `DIBaseParams` has a writable `blockSize` and a read-only
  `overrideBlockSize`;
- `+[DiskImages2 attachWithParams:handle:error:]` returns a `DIDeviceHandle`
  with the `BSDName`.

A test tool calls them by name. It is ad-hoc signed, holds none of
`diskutil`'s entitlements (`com.apple.diskimages.attach` among them), and runs
as the user. 2026-10-31:

| attach of a 4Kn LUN's `lun0.img` (simulator, 4096-byte blocks, GPT written at 4096) | device block size | partition map | APFS volume |
|---|---|---|---|
| `diskutil image attach` | 512 | protective MBR only (`0xEE`) | none |
| `DiskImages2`, default | 512 | protective MBR only | none |
| `DiskImages2`, `setBlockSize:4096` | **4096** | **GPT** | **visible** |

- `setBlockSize:` sets `overrideBlockSize`; `blockSize` still reads 512.
- `hdiutil info` reports these attaches with `diskutil`'s engine
  (`read/write disk image`).
- The device outlives the process that attached it.
- **The same on macOS 26.6.2 (25G83)**, on a SIP-on test VM, with the tool
  built for a 26.0 deployment target: 512 and the protective MBR by default,
  4096 and the GPT with `setBlockSize:4096`. One difference: on 26
  `blockSize` is a 32-bit `unsigned int` (`TI`), on 27.2 a 64-bit
  `unsigned long long` (`TQ`). arm64 passes either in the same register, so a
  64-bit call worked on both, but real code should read the method's type
  encoding at runtime rather than assume one.

So 4Kn LUNs can have the concurrent engine. The costs:

- **This is private API.** It is fine in a Developer ID app; notarization does
  not look for private API. But it can change in any macOS update. The app
  would look the classes and selectors up at runtime and fall back to
  `hdiutil -blocksize` when they are missing.
- **Not yet measured on this attach:**
  - reads in flight;
  - the write-through grant, though that is the extension's half and the
    engine is the same;
  - `autoMount` YES.

**What is on `adaptive-read-around`: DiskImages2 opt-in on macOS 27, `hdiutil` by
default.** It was the 27 default for one evening, 2026-10-31. Then a FreeBSD 15
guest under VMware Fusion, booting from `seattle-vms` attached through
DiskImages2, panicked with "NVME polled command failed to complete within
10s". The host device counters showed writes averaging 120-140 ms (589 writes,
70.7 s in total), and VMware logged "Something may be hung". The same VM had
booted cleanly on `hdiutil` earlier that day.

The extension's summary ruled out two explanations:
- **not extra flushing:** 4 flushes in the session;
- **not read-before-write in the page cache:** reads and writes at the
  extension matched the device's, about 1:1.

It showed up to 17 reads in flight, plus 16-deep speculation, where `hdiutil`
had 1. But a mixed test on name-testing (8 random readers and 1 64 KiB writer)
did not reproduce it: writes averaged 17 ms on DiskImages2 against 33 ms on
`hdiutil`, with a worst case of 171 ms. That test differed from the VM's
session in three ways:
- **write policy:** `seattle-vms` flushes every 5 s without FUA;
- **the NAS:** cold for the VM, warm in the test;
- **the workload:** VMware on HFS+, against fio on APFS.

**Reproduced with timing, 2026-10-31: the seconds are spent above the
extension.** The extension and the daemon now log any I/O that takes a
second or more, with where its time went, and the extension times every
read from FSKit's handover to its reply (CLAUDE.md, "Slow I/O is logged
where it happens"). Three experiments used that.

*The VM boot, again,* from `seattle-vms` through DiskImages2, with its
flush every 5 s. It booted this time, but the counters for the attached disk
showed two stalls:

- **19:47:20–27:** 7–47 writes a second, averaging 0.7–1.2 s;
- **19:48:21–25:** 5 writes a second, averaging 2.0 s, then 3.0 s and
  3.75 s.

Across the session the extension served 587 writes: the longest took
33.5 ms and none took a second. The daemon's longest operation was 391 ms,
with at most 23 in flight. Those counters are `IOBlockStorageDriver`'s,
under the HFS+ volume that holds the VM. So the seconds passed between the
disk device and the extension's write handler, in DiskImages2 or the
kernel's side of FSKit.

*A synthetic load on name-testing* (NVMe/TCP, 10 GbE). fio could not run
it: on macOS each fio job takes a System V shared-memory segment, and the
default limits (4 MiB in all) fail at about 16 jobs with "failed to setup
shm segment". A Python load generator ran instead:

- 16 threads of random 32 KiB `pread`s over one 1 GiB file, and 32 threads
  of random 64 KiB `pwrite`s over another;
- `F_NOCACHE`, as fio's `direct=1` sets;
- 20 s per run, each setup on a fresh mount and attach, run forwards and
  then backwards.

With the logging build and blocking writes:

| setup | reads: IOPS, mean (max) | writes: IOPS, mean (max) |
|---|---|---|
| DiskImages2, async reads (the opt-in) | 709 / 505, 23–32 ms (0.27 s) | 120 / 140, 229–269 ms (3.8 s) |
| DiskImages2, blocking reads | 137 / 114, 117–140 ms (0.42 s) | 33 / 28, 985–1,164 ms (5.3 s) |
| DiskImages2, writers only | — | 232 / 230, 138–139 ms (1.7 s) |
| `hdiutil` | 49 / 48, 329–332 ms (0.64 s) | 53 / 52, 615–618 ms (5.0 s) |

- **Writes do not starve behind concurrent reads.** That was the hypothesis,
  and blocking the reads made writes four times slower, not faster.
  Blocking replies give reads and writes one handover between them.
- **Writes reach the extension one at a time.** With writers only, it
  finished one every 4.3 ms, back to back (4,628 in 20 s), none over
  18.3 ms. 32 writers queuing for that wait about 138 ms each, the mean they
  saw. FSKit hands blocking writes over serially, as the layer table earlier
  in this item shows it doing for reads.
- **`hdiutil` was slowest on every count,** with both reads and writes
  serial.
- **No I/O took a second anywhere in our code** in these 9 runs. The worst
  read the app saw took 1.6 s, in the warm-up.

*Concurrent writes, tried and not adopted.* A speculative build answered
writes asynchronously as well, behind `?writes=async`:

- up to 32 writes in flight, replied to from a concurrent queue;
- an ordered range lock in place of `ioLock`, in both modes, so overlapping
  writes still reach the device and the chunk cache in arrival order.

Its tests passed. With writers alone it did what it was for: 375–863 IOPS
against 216–244 blocking, with 9–16 writes in flight at the extension. But
with readers and writers together, reads stalled. Two sets, of the same
nine runs; set 2 added the read timing:

| set | mixed run | writes | worst read in the app | worst write | longest read at the extension | daemon's longest |
|---|---|---|---|---|---|---|
| 1 | warm-up | async | **9.1 s** | 1.9 s | not timed | 711 ms |
| 1 | A forwards | blocking | 0.36 s | 2.4 s | not timed | 632 ms |
| 1 | A' forwards | async | **11.4 s** | 7.6 s | not timed | 388 ms |
| 1 | A' backwards | async | **17.5 s** | 5.9 s | not timed | 1,336 ms |
| 1 | A backwards | blocking | **18.4 s** | 17.3 s | not timed | 608 ms |
| 2 | warm-up | async | **9.2 s** | 1.0 s | 459 ms | 458 ms |
| 2 | A forwards | blocking | **10.2 s** | 4.5 s | 326 ms | 325 ms |
| 2 | A' forwards | async | **11.3 s** | 1.4 s | 533 ms | 533 ms |
| 2 | A' backwards | async | **18.0 s** | 1.0 s | 809 ms | 808 ms |
| 2 | A backwards | blocking | 0.38 s | 1.0 s | 500 ms | 499 ms |

Between the sets, the read-timing build without the write patch ran 4 mixed
and 3 writers-only runs. None stalled, and the worst read in the app took
0.54 s. In every run the extension's longest read, its longest daemon fetch
and the daemon's longest operation were the same figure, at most 456 ms.

- **The write patch provokes the stall.** All 6 mixed runs with async writes
  had a read held for 9–18 s; 0 of the 11 mixed runs on builds without the
  patch did. Two of its four blocking-write runs stalled too. All four
  followed an async-write run, each on a fresh mount, and the patch replaces
  `ioLock` in blocking mode as well. So this cannot tell a carry-over from
  the patch's blocking path.
- **The stalled reads never waited in our code.** In set 2 no read took
  over 0.81 s between FSKit's handover and the reply, and none waited for a
  thread. The exceptions were two 16 KiB reads in a writers-only run, which
  took 1.1 s at the NAS; the extension and the daemon timed them within a
  millisecond of each other. So 8–17 s of each stalled read passed outside
  the handler. That is APFS, DiskImages2, or the kernel's side of FSKit,
  including the page cache the `writeThrough` grant keeps for `lun0.img`.
- **The VM's stall looks like the same thing.** It had no write patch, and
  still the disk waited 2–4 s for writes the extension finished in under
  34 ms. The patch makes the stall easy to reproduce; it does not create it.

So:

- **DiskImages2 is not safe for VM disks.** Under a VM's load, or a heavy
  mixed one, it holds single requests for seconds where our code cannot see
  them.
- **Concurrent writes are not adopted.** Their only gain is on DiskImages2,
  where they make the stall routine. `hdiutil` sends one request at a time,
  so there they would change nothing.
- **`hdiutil` stays the default.** Under this load its tail was queueing for
  its one-at-a-time engine, up to 5.0 s for a write, but no read in its
  runs took over 0.64 s.

**Next, to find what holds the reads:** a system-wide `spindump` (it needs
`sudo`) while a read is stuck. The async-write build stalls within one 20 s
run, so it is the reproduction to use. Until the stall is explained,
DiskImages2 stays behind
`defaults write me.herko.iSCSIInitiator ImageAttachEngine diskimages2`.

When opted in:

- **The app** attaches with `diskutil image attach --mountPolicy autoMount`,
  or with `DiskImages2Attach` (`setBlockSize:4096`, `autoMount`) when a 4Kn
  LUN needs it. On any failure it falls back to `hdiutil`, using an already
  attached device rather than attaching twice. `autoMount` was chosen over
  attach-then-`diskutil mountDisk` because `mountDisk` also mounts an EFI
  partition; `autoMount` left EFI alone, like `hdiutil`, and attached a blank
  image without complaint (both measured on scratch images, 2026-10-31).
- **The extension**, told by `engine=diskimages2` on the mount URL, answers
  reads asynchronously and grants `writeThrough` for `lun0.img`
  (`VolumeIOOptions`). Without that query it behaves as every release did.
  `writeThrough` rather than `noCache` because its write durability is the
  one measured.
- **On macOS 26** the app keeps `hdiutil` and the extension keeps blocking
  replies. `ImageAttachEngine` will not choose DiskImages2 there even when
  asked, since nothing can make its writes write-through.
- **Escape hatches:**
  - `defaults write me.herko.iSCSIInitiator ImageAttachEngine hdiutil`;
  - `?reads=blocking` and `?cache=fskit` on a hand-made mount URL.

The 27 SDK it needs is shown harmless on macOS 26.6.2 (2026-10-31, SIP-on VM,
a 27-SDK Developer ID build with a 26.0 deployment target):

- `FSOpenItemResult` and `FSUpgradeItemResult` are weak imports;
- the extension loaded and mounted, and `hdiutil` + APFS read back 8 MiB
  intact;
- with `?cache=writethrough`, FSKit 26 never called the handler and kept
  `OpenCloseOperations`, final-close flush included.

On 26.6.2 the module needed the documented `enabledModules.plist` entry and a
`killall fskitd` first.

**Through the app on macOS 27.2, 2026-10-31.** Attaching name-testing from
the app used DiskImages2 (`read/write disk image`, 512-byte blocks). EFI was
left unmounted, the volume was remounted `noatime`, the extension logged
`reads: async`, and FSKit's `readWriteWithCache` request for `lun0.img` got
`writeThrough`.

Its first fio runs were slow (8 threads: 390 IOPS). That was a cold NAS: an
`hdiutil` control right after gave 330. One ranking of the cache grants then
rose in exactly its run order. So it was redone with one sequential warm-up
pass over `read.dat`, then each setup run forwards and again backwards. 8
threads, 4 KiB random, `direct=1`, 15 s:

| setup | IOPS (two runs) | mean latency | reads the extension served |
|---|---|---|---|
| DiskImages2 + `writethrough` (default) | 59,693 / 52,981 | 0.13–0.15 ms | 65,580: all of the 1 GiB file, once |
| DiskImages2 + FSKit default caching | 59,667 / 55,392 | 0.13–0.14 ms | 65,580 |
| DiskImages2 + `readcache` | 55,026 / 47,980 | 0.15–0.17 ms | 65,590 |
| DiskImages2 + `nocache` | 6,578 / 5,797 | 1.2–1.4 ms | 88,000–99,000, every read |
| `hdiutil` | 688 / 654 | 11.6–12.2 ms | about 11,000, one at a time |

- **`writethrough` costs reads nothing** against FSKit's own caching, and it is
  the grant with measured write durability, so it stays the default.
- **The cached modes run at RAM speed once the file is cached.** Within each
  15 s run the extension fetched all of the 1 GiB file once, in 16 KiB pages,
  and every later read was served from the Mac's page cache.
- **`nocache` shows the network path: about nine times `hdiutil`**, with 8
  reads in flight against 1. But `ReadAroundController` settled on 8-16 KiB
  units, the near-tie noted above, costing 2.4-4.3x on the wire.

Still unverified:
- **`noCache` writes.**
- **A target loss with writes in flight.** They are synchronous now, so they
  should fail loudly.
- **A real host power cut** on a VM with `crash-consistency.py`.
- **Async replies rely on undocumented buffer lifetime.** 1,139,667 async
  reads have been checked byte for byte with no mismatch. 126,928 were on the
  `hdiutil` path. 1,012,739 were through `diskutil image attach`, but those
  were mostly served from the page cache, so they prove less.

Also outstanding: a Feedback report to Apple on `hdiutil`'s CRawDiskImage
reading its backing file serially, and on DiskImageKit having no attach
with a block size.

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
