# Setup repair for inconsistent installs — design

Approved in conversation 2026-10-05, during 0.7.0 RC testing.

## Goal

Setup should get a machine to a working state whatever earlier installs left
behind. The motivating case: the app was once run straight from its mounted
DMG, or the DMG was left mounted, and the machine now carries registrations
that make attaching fail while every Setup step reports green.

Setup today checks four things on every launch — location, daemon, module
registered, module enabled — and every check asks about **presence**. The
states below are about **plurality and provenance**, which none of them see.

## In scope

1. **Ghost copies.** Other bundles registered with LaunchServices as this app:
   the copy inside a mounted (or once-mounted) DMG, a copy in Downloads, build
   products. LaunchServices registers the app inside a mounted DMG and does not
   unregister it on eject. With two registered copies `mount -F` cannot choose
   a module and fails with "File system named iSCSI not found"
   (`docs/backend-a-fskit-notes.md`, "Registered *twice* looks exactly like not
   registered").
2. **Stale registrations.** Records pointing at bundles that no longer exist —
   an ejected DMG, a deleted build folder.
3. **A daemon registered from another copy.** The approved launchd job runs
   `iscsid` out of a different copy of the app, or out of one that has gone.
   Today the first is invisible when versions match, and the second shows as
   "approved but not answering" with advice to reinstall from the disk image —
   a dead end.

## Out of scope

- The SIP-off VM state where `FSClient.installedExtensions` omits the module
  while `pluginkit` lists it and `mount -F` works. Unexplained, and documented
  as "do not re-litigate".
- Deleting any files. Every repair here removes *registrations*; bundles stay
  where they are.
- Repairing silently. Every repair is a button behind a consent prompt.

## Measured before designing (2026-10-04, read-only)

- `NSWorkspace.shared.urlsForApplications(withBundleIdentifier:
  "me.herko.iSCSIInitiator")` answers in **~4 ms** and, on the dev host, returned
  7 copies: `/Applications`, two DerivedData products, `build/export`,
  `build/dmg-stage`, `apps/build/dd`, and a renamed `iSCSIApp.app`. The full
  `lsregister -dump` (~2.3 s) attributes the module to only 2 of them, so the
  bundle-ID query is a **superset** — the safe side for "other copies exist".
- On the SIP-on VM, unprivileged `launchctl print system/me.herko.iSCSIInitiator.daemon`
  shows only `program identifier = Contents/MacOS/iscsid` and
  `parent bundle identifier`, **no absolute path**. launchd will not say which
  copy the daemon runs from; the daemon itself has to.
- **Not yet known:** whether the bundle-ID query returns registrations whose
  bundle no longer exists. The dev host had none to test against. Section 3
  settles it before building.

## 1. New setup step: "No other copies registered"

`OtherCopies`, id `other-copies`, placed **after "Installed in Applications"
and before the daemon step**:

    location -> other copies -> daemon -> registered -> enabled

Before the daemon, because a ghost copy is what makes the later steps report
green over a broken install, and because cleaning up is independent of the
daemon.

**Check.** The bundle-ID query above, minus the running bundle (both sides
with symlinks resolved). Each remaining URL is classified as *present* (the
bundle exists on disk) or *gone* (it does not).

- None left: `.satisfied("only this copy is registered")`.
- Otherwise `.actionable`, naming each copy, e.g.
  "2 other copies of iSCSI Initiator are registered with macOS:
  /Volumes/iSCSI Initiator/iSCSI Initiator.app (no longer exists);
  ~/Downloads/iSCSI Initiator.app. With more than one, macOS cannot tell which
  filesystem extension to load, so attaching fails with 'not found' even while
  this screen is green."

  *Revised during implementation:* two live copies attached fine on the SIP-on
  VM (2026-10-05); what broke was the daemon left running from, then pointing
  at, the ejected copy. The step's text says so instead of "not found" — see
  `docs/backend-a-fskit-notes.md`, "What LaunchServices keeps after a DMG".

**Action** "Clean up", behind a consent prompt: "This removes macOS's
registration of the copies listed above so only this one is used. It does not
delete any files." `perform()` runs `lsregister -u <path>` for each, **off the
main actor** (as every subprocess the app waits on now does), then re-checks.

Like every unsatisfied step it holds back Connect. (*Revised:* a gone copy
that survives Clean up no longer does — LaunchServices may refuse to drop it,
and holding back every target and session for a record that attaching was
measured not to depend on would be a lockout.) On a
development Mac every build product shows up here. That is accurate — they are
registered — and one click clears them.

When the running bundle is translocated or outside /Applications, the location
step fails first: this step still checks and shows its state, but offers no
button until the location step passes (only the first unsatisfied step does).
So Clean up never runs from a translocated copy that would count the real
install as "another copy".

## 2. Which copy the daemon runs from

- `DaemonInfo` gains `bundlePath: String?` — **optional**, so an app talking to
  an older daemon still decodes its reply.
- `XPCService.daemonInfo` fills it from `Bundle.main.bundleURL` (which, for
  `iscsid` inside `<app>/Contents/MacOS`, is the containing app), and only when
  that path ends in `.app`. A loose `swift run` daemon reports nil.
- `DaemonController.probe()` compares it to the running app's bundle (symlinks
  resolved). A mismatch is a new state, `.otherCopy(path)`, checked **before**
  the version comparison: a daemon from another copy is the wrong daemon even at
  the same version.
- `DaemonStep` renders `.otherCopy` as actionable — "the background service
  belongs to another copy of the app at <path>; it needs reinstalling from this
  one" — with a "Reinstall" button that runs the existing `reregister()`
  (unregister, settle, register), exactly as version mismatch does today.
- `.registeredNotResponding` changes from **blocked** to **actionable** with the
  same "Reinstall" button and the text "approved, but not running — most often
  because it belongs to a copy of the app that no longer exists. Reinstall it
  from this copy." Re-registration may bring back the System Settings approval;
  the step already handles `requiresApproval`.
- A nil `bundlePath` (an older daemon) skips the comparison; the version check
  still catches that case.

## 3. Stale registrations: probe, then one of two branches

Implementation **starts** with the motivating scenario on the SIP-on VM:

1. Mount the RC DMG; launch the app from it (the location step refuses);
   quit.
2. Drag-install to /Applications over the existing copy; launch.
3. Eject the DMG; relaunch.

At each stage, record what the bundle-ID query returns, what
`lsregister -dump | grep iSCSIFSExtension.appex` returns, and whether
`mount -F` (an attach) works.

- **If the bundle-ID query returns the ejected DMG's path:** section 1 covers
  stale registrations as written.
- **If it does not:** `OtherCopies.check()` additionally runs the dump-based
  `FSKitRegistrationAudit.registeredAppBundles()` once per launch, on a detached
  task, and merges its paths into the list. The step shows `.checking` until it
  returns; ~2.3 s on an idle Mac, off the main actor. (*Revised:* the wait
  is bounded at 10 s; a later check picks up a slower dump's answer.)

Whichever branch is taken is recorded in `docs/backend-a-fskit-notes.md` next to
the duplicate-registration section.

## 4. Kept as is

The Register step's duplicate pruning and the mount-failure diagnosis in
`AttachmentManager` both stay. With the new step they should rarely fire, but
they cost nothing and cover module-level duplicates a renamed bundle could
still produce.

## Code layout

- `Sources/iSCSIKit/SetupAudit.swift` (pure, tested with `swift test`):
  - `RegisteredCopies.others(registered: [String], running: String,
    exists: (String) -> Bool) -> [RegisteredCopy]` — path normalisation,
    excluding the running copy, present/gone classification, stable order.
  - `RegisteredCopies.summary(_ copies: [RegisteredCopy], home: String) -> String`
    — the actionable text, with `~` for the home directory.
  - `DaemonPlacement.isOtherCopy(daemonBundlePath: String?, appBundlePath: String) -> Bool`
    — nil-safe, symlink- and trailing-slash-normalised comparison.
- `Sources/iSCSIKit/XPCModels.swift` — `DaemonInfo.bundlePath`.
- `Sources/iSCSIDaemon/XPCService.swift` — fill `bundlePath`.
- `apps/iSCSIApp/Setup/OtherCopies.swift` (new) — the step; `NSWorkspace`
  query and `lsregister -u` live here, as `InstallLocation` and
  `FSKitRegistrationAudit` keep their system calls in the app.
- `apps/iSCSIApp/Setup/SetupCoordinator.swift` — insert the step; the
  ordering comment gains its reason.
- `apps/iSCSIApp/Setup/DaemonController.swift` — `.otherCopy`, the probe
  comparison, `registeredNotResponding` made actionable.

The pure parts live in iSCSIKit because the app target has no test target; the
interface picker's `InterfaceChoices` set the precedent.

## Testing

Unit (`swift test`):

- `RegisteredCopies.others`: the running copy is excluded, including through a
  symlink and a trailing slash; present and gone are classified by the injected
  `exists`; no other copies means an empty list; duplicates in the input collapse.
- `RegisteredCopies.summary`: names every copy, marks gone ones "(no longer
  exists)", abbreviates the home directory.
- `DaemonPlacement.isOtherCopy`: same path (raw, symlinked, trailing slash) is
  false; a different path is true; nil is false.
- `DaemonInfo` decodes from a payload without `bundlePath` (an older daemon) and
  round-trips with it.
- `XPCService.daemonInfo` reply decodes and carries a `bundlePath` that is nil
  under `swift test` (the test runner is not an `.app`).

Hardware, SIP-on VM, as part of the RC:

- The section 3 scenario end to end: the new step names the DMG copy (and, once
  ejected, the gone one), Clean up turns it green, and an attach then works.
- A daemon registered from another copy: put a second copy at
  `/Applications/Test/iSCSI Initiator.app` (inside /Applications, so the
  location step lets it register), register the daemon from it, then launch
  `/Applications/iSCSI Initiator.app` — the daemon step names the other copy,
  offers Reinstall, and recovers.
