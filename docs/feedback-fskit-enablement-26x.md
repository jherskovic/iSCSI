# Feedback draft: the File System Extensions switch cannot enable a third-party FSKit module on macOS 26.x

Draft for Feedback Assistant. Not yet filed — filing needs the project owner's
account. Companion to `feedback-virtual-scsi-wedge.md`.

**Suggested title:** On macOS 26.6.1 the File System Extensions switch will not
enable a notarized third-party FSKit module; the identical build enables on the
first click on macOS 27.0

**Area:** File System Extensions / FSKit / System Settings
**Platform:** macOS 26.6.1 (25G76), Apple Silicon (Apple Virtualization guest),
**SIP enabled**

---

## Summary

A notarized Developer ID FSKit module registers correctly on macOS 26.6.1,
appears in System Settings → General → Login Items & Extensions → File System
Extensions with its switch in the off position, and **the switch cannot be turned
on**. It does not move.

The **identical DMG**, installed the same way, enables on the first click on
macOS 27.0 and mounts immediately.

This is not a code-signing or entitlement problem. Everything the system exposes
about the module is healthy on 26.6.1, and byte-identical to the machine where it
works.

## Reproducer

1. Build an FSKit module (`EXExtensionPointIdentifier com.apple.fskit.fsmodule`,
   `FSSupportsGenericURLResources`, `com.apple.developer.fskit.fsmodule`
   entitlement, sandboxed appex inside an unsandboxed host app).
2. Sign Developer ID with hardened runtime, notarize and staple both the app and
   a DMG containing it.
3. On a clean macOS 26.6.1 install with **SIP on, no Xcode, and no Apple ID
   signed in**, download the DMG, drag the app to `/Applications`, and launch it.
4. System Settings → General → Login Items & Extensions → File System Extensions.
5. Try the switch.

**Expected:** the switch turns on, as it does on macOS 27.0.
**Actual:** the switch does not move.

Reproduced against Apple's own `FSKitSample` by a third party on macOS 26.1 and
26.2: https://github.com/andrewgazelka/loaf/issues/1

## What is verifiably *not* the cause

Each of these was checked on the failing machine, and each matches the machine
where the switch works:

| checked on 26.6.1 | result |
|---|---|
| `spctl -a -vvv -t install` on the DMG | `accepted`, `source=Notarized Developer ID` |
| quarantine xattr after the Finder drag | `01c3;…;Safari;…` — assessed and approved |
| bundle contents | same `CodeResources` (1716 B) and `embedded.provisionprofile` byte counts |
| appex signature | Developer ID Application, hardened runtime, secure timestamp, team present |
| appex entitlements *as signed* | `com.apple.developer.fskit.fsmodule = true`, `com.apple.security.app-sandbox = true` |
| `pluginkit -m -p com.apple.fskit.fsmodule` | module listed |
| `fskit_agent` on install | `Added 1 identifiers`, no rejection logged |
| `FSClient.shared.installedExtensions` | returns the module; `isEnabled` correctly `false` |
| developer account signed in | **not** required — see below |

The last row is worth stating explicitly because it is the obvious suspicion. A
**freshly created local user account** on the macOS 27 machine, with no Apple ID
and no developer account signed in, toggles the switch without issue.
`enabledModules.plist` is per-user, so this isolates the account on identical OS
and hardware. Developer status is not the discriminator; OS version is.

## The one asymmetric signal

On 26.6.1, every attempt at the switch produces this in `fskitd`:

```
fskitd  [com.apple.FSKit:default] Incomming connection, entitled 0
fskitd  [com.apple.FSKit:default] About to get current agent for 501
fskitd  [com.apple.FSKit:default] Received error '(null)', errno 2, retrieving team ID
```

That message appears **nowhere** in macOS 27.0's log for the entire day, on the
same subsystem, including the window in which the switch actually worked.

It is not a logging difference. `strings /usr/libexec/fskitd` on **macOS 27.0**
still contains both `Received error '%@', errno %d, retrieving team ID` and
`%s did not find team ID`. macOS 27 runs the same code and succeeds where 26.6.1
fails.

(The error object is `(null)` while `errno` is 2, so `errno` is probably stale
from an unrelated call rather than a literal `ENOENT`. The reliable part of the
signal is that no team ID was found — for a binary that demonstrably has one:
`codesign -dv` on the appex reports `TeamIdentifier` correctly on the *failing*
machine.)

## Workaround, and why it should not be necessary

Appending the module's bundle identifier to

```
~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist
```

and then restarting `fskitd` enables the module immediately — `mount -F` stops
reporting `Module … is disabled!` and mounts successfully, `FSModuleIdentity.isEnabled`
flips to true, and the entry survives a reboot without being pruned.

So nothing about the module is being judged ineligible by the rest of the system.
Only the path through System Settings fails.

This workaround requires an application to write into an Apple-owned group
container and to restart a system daemon as root. That is a bad thing for
third-party software to ship, it is invisible to the user consent model the
switch exists to provide, and it will break the moment the file format changes.
We would much rather the switch worked.

## Secondary request: no way to open the pane on macOS 26

`FSClient.openFileSystemExtensionsSettings()` is macOS 27 only. On macOS 26 there
appears to be no supported way for an app to bring the user to the File System
Extensions pane — `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
does not navigate there on 26.6.1 (System Settings does not move to the pane).

An app that ships an FSKit module on macOS 26 therefore cannot direct the user to
the control it needs them to use. Back-deploying
`openFileSystemExtensionsSettings()`, or documenting a URL that works, would
close that gap independently of the bug above.

## What we would like

1. The File System Extensions switch to enable third-party modules on macOS 26.x,
   as it does on 27.0 — ideally in a 26.x update, since 26.x is where the
   installed base is.
2. Failing that, a documented reason a module is judged ineligible, surfaced
   somewhere the developer can read. The switch silently not moving gives nothing
   to act on; the `retrieving team ID` line was only found by diffing logs across
   two OS versions.
