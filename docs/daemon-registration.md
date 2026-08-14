# Registering iscsid with SMAppService — measured behaviour

Everything here was observed on macOS 27.0, SIP on, real hardware, against a
**Developer ID signed but deliberately un-notarized** 0.1.2 build
(`spctl` reported `source=Unnotarized Developer ID`). That signing grade was
chosen on purpose: it isolates notarization as the single variable, which an
Apple-Development build would not, because it differs in signing identity too.

## R4 is answered: registration does not require notarization

`SMAppService.h` says *"Apps that contain LaunchDaemons must be notarized."* That
is **not enforced at `register()`**. The daemon registered, was approved, launched,
and answered XPC — all with no notarization ticket.

This matters only for the development loop, and it makes it much cheaper:
`SMAppService` can be exercised with `scripts/release.sh --skip-notarize`, which
takes about two minutes, instead of a ten-minute notarization round trip per
iteration. It does **not** license shipping an un-notarized build; Gatekeeper
still rejects one on a machine that did not build it.

## `register()` throws EPERM on the happy path

The single most confusing thing here. Registering a LaunchDaemon that has not yet
been approved throws:

```
SMAppServiceErrorDomain 1: The operation couldn't be completed. Operation not permitted
```

Code 1 is `EPERM`. It is **not** one of the `kSMError*` values, which start at 2 —
so error-code mapping alone will not recognise it, and it looks like a hard
failure.

It is not. By the time it throws, `smd` has already recorded the item:

```
$ sfltool dumpbtm
                 Name: iscsid
      Team Identifier: 4A27X5PJP3
                 Type: daemon (0x10)
          Disposition: [enabled, disallowed, not notified] (0x1)
           Identifier: 16.me.herko.iSCSIInitiator.daemon
                  URL: Contents/Library/LaunchDaemons/me.herko.iSCSIInitiator.daemon.plist
      Executable Path: Contents/MacOS/iscsid
    Assoc. Bundle IDs: [ me.herko.iSCSIInitiator ]
    Parent Identifier: 2.me.herko.iSCSIInitiator
```

`.status` reports `requiresApproval`, and the user is one switch away from done.

**So never report a `register()` throw as the final state.** Ask the system what
happened afterwards and only interpret the error if nothing registered at all.
`DaemonController.register()` does this. Reporting the throw directly told the
user their install had failed when it had, in fact, succeeded.

`sfltool dumpbtm` needs no `sudo` and is the fastest way to see the truth.

## What the bundle layout bought

Confirmed from the BTM record above rather than assumed:

- `BundleProgram` resolved — the recorded `Executable Path` is bundle-relative
  (`Contents/MacOS/iscsid`), so moving the app does not strand the daemon.
- `AssociatedBundleIdentifiers` took, so System Settings shows **iSCSI Initiator**
  rather than `me.herko.iSCSIInitiator.daemon`. The user is approving a root
  daemon; they should be able to see what it belongs to.
- The plist filename matching the `Label` is what let `SMAppService` find it at
  all. `release.sh` asserts this.

## After approval

launchd bootstraps it immediately — no reboot:

```
$ sudo launchctl print system/me.herko.iSCSIInitiator.daemon
	path = (submitted by smd.362)
	state = running
	program identifier = Contents/MacOS/iscsid (mode: 2)
	pid = 16739
```

and the daemon's own startup line appears in the unified log, readable rather
than redacted:

```
$ log show --predicate 'subsystem == "me.herko.iSCSIInitiator"' --last 10m
iscsid[16739] [me.herko.iSCSIInitiator:lifecycle] iscsid: listening on
me.herko.iSCSIInitiator.daemon (writeThrough=on, taskTimeout=30.0 seconds)
```

`daemonInfo` then answers over XPC with `version=0.1.2 build=3 pid=16739
relaxedAuth=false` — which incidentally verifies M4.1 end to end at runtime: the
Release daemon was enforcing the Developer ID code-signing requirement and the
connecting app satisfied it. `codesign -R` proves the requirement matches a
binary on disk; only this proves the kernel accepts the live connection.

## Why status alone is not enough

`SMAppService.status == .enabled` means launchd is *willing to start the job*. It
does not mean the job started, stayed up, or is the build that shipped with this
app. "Approved and working" and "approved and crashlooping" are the same status
and need opposite instructions, so `DaemonController` pairs the status with the
`daemonInfo` round trip and gives the latter its own state
(`registeredNotResponding`).

## Development cleanup

A registration made from `build/export/` survives the next `release.sh`, which
deletes that directory — leaving a registration pointing at nothing. Click
**Unregister** when finished with a throwaway build, or remove it in System
Settings → General → Login Items & Extensions.

## M3 verified end to end (2026-08-14)

Clean SIP-on VM (`192.168.0.39`, macOS 26.6.1, no Xcode, no Apple ID), notarized
0.1.3, installed by dragging from the DMG over an existing 0.1.2. The user
clicked only buttons inside our app; Terminal was never opened.

```
app                0.1.3
daemon             state = running, pid 1286, Contents/MacOS/iscsid
module registered  me.herko.iSCSIInitiator.fsext(0.1.3)
enabledModules     ours present
mount -F -t iSCSI  => MOUNTED, lun0.img present
```

**The extension steps were red on first launch, and that is the finding.**
Dragging the new bundle over the old one dropped the extension's registration —
the failure mode `backend-a-fskit-notes.md` documents for in-place bundle
replacement — and the every-launch check caught it and repaired it with one
button.

That is the M7 post-update repair path, working before M7 exists. A Sparkle
update replaces the bundle exactly the same way, so no update-specific code is
needed: re-checking unconditionally on every launch turns "an update broke the
registration" into an ordinary unsatisfied step. This is the payoff for the
design decision in `SetupCoordinator`, and the reason not to narrow it later
into a check that only runs on first run or only after a version change.

It also settles the repair action's scope: `lsregister` run in the *user's*
context is sufficient on a healthy machine, so the daemon does not need a
privileged re-registration call.
