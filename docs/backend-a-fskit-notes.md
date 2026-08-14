# Backend A: FSKit + hdiutil — API reconnaissance

Backend A exposes the iSCSI LUN as a **file** served by an FSKit filesystem
extension, then attaches that file as a raw disk image:

```
iscsid ──XPC──► FSKit extension ──► /Users/x/mnt/lun0.img
                                          │
                    hdiutil attach -imagekey diskimage-class=CRawDiskImage
                                          ▼
                                     /dev/diskN ──► APFS
```

**Why this is the shipping path:** the block device is created by Apple's
DiskImages framework, not by our dext. The wedge documented in
`feedback-virtual-scsi-wedge.md` is specific to APFS on *our*
`IOUserSCSIParallelInterfaceController`; the elimination matrix already records
that **APFS on an `hdiutil` RAM disk works**. Backend A therefore routes around
the wedge rather than waiting on Apple.

Reconnaissance done against the macOS 27.0 SDK headers (host) and the shipped
frameworks/tools on the 26.6.1 test VM.

## Availability gates

From `FSKitDefines.h`:

| macro | OS | notable declarations |
|---|---|---|
| `FSKIT_API_AVAILABILITY_V1` | macOS 15.4 | `FSBlockDeviceResource`, `FSUnaryFileSystem`, `FSVolumeOperations`, `FSVolumeReadWriteOperations` |
| `FSKIT_API_AVAILABILITY_V2` | macOS 26.0 | **`FSGenericURLResource`**, **`FSPathURLResource`** |
| `FSKIT_API_AVAILABILITY_V2_4` | macOS 26.4 | — |
| `FSKIT_API_AVAILABILITY_V3` | macOS 27.0 | `FSClient.mountSingleVolume(resource:bundleID:options:)` |

Also present: `FSKIT_API_INTRODUCED_V1_DEPRECATED_V3_WITH_REPLACEMENT` — parts of
the original 15.4 API are deprecated in 27.0, so target V2 shapes where there's a
choice.

**Consequence:** the test VM (26.6.1) has the URL resource types but *not* the
programmatic mount API. The extension must therefore be built with a deployment
target that excludes V3 symbols, and mounted from the command line (below).

## Resource model

`FSResource` subclasses:

- `FSBlockDeviceResource` (V1) — a real block device. **Not applicable**: Backend
  A has no block device; that is the entire point.
- `FSGenericURLResource` (V2) — content identified by an arbitrary URL. The
  extension declares the schemes it handles via the Info.plist key
  `FSSupportedSchemes` (an array of case-insensitive scheme strings). This is the
  fit for `iscsi://target/lun0`.
- `FSPathURLResource` (V2) — a `file:` URL in the system file space, possibly
  security-scoped, with a `writable` flag.

## Mount path on macOS 26.6 (the gating question — resolved)

`mount(8)` on the VM documents:

```
-F      Forces the file system type be considered as an FSModule
        delivered using FSKit.
```

and `/sbin/mount` on 26.6.1 contains the resource-selection logic and Info.plist
key names:

```
FSSupportsGenericURLResources
FSSupportsPathURLs
FSSupportsServerURLs
FSRequiresSecurityScopedPathURLResources
resourceWithURL:
"Filesystem %s supports neither Block Device nor PathURL resources nor ServerURL resources."
```

So a URL-resource FSKit module is mountable from the CLI on the VM's OS:
`mount -F -t <FSShortName> <url> <mountpoint>`. **No macOS 27 upgrade and no V3
API are required.** The VM keeps its value as the wedge-reproduction baseline for
the pending Apple report.

Supporting tools present on the VM: `/usr/libexec/fskitd`, `fskit_agent`,
`fskit_helper`. (`fskitd`'s usage string mentions ports and threads and looks
unrelated to mounting — don't read anything into it.)

## Methodology note: `strings` on framework binaries is a false negative

Checking whether the 26.6 framework "really" has an API via
`strings /System/Library/Frameworks/FSKit.framework/Versions/A/FSKit` returns
**nothing** — no selectors, no class names — because shipped framework binaries
are dyld-shared-cache stubs. The same probe returns nothing on the macOS 27.0
host, which certainly *does* have the V3 API. That control is what caught it.

`strings` on standalone tools such as `/sbin/mount` *is* informative, and is what
actually answered the mount question above.

## Required change to the existing skeleton

`apps/iSCSIFSExtension/Info.plist` currently declares:

```xml
<key>FSSupportsBlockResources</key><true/>
<key>FSShortName</key><string>iSCSI</string>
```

`FSSupportsBlockResources` is wrong for Backend A. It needs
`FSSupportsGenericURLResources` (plus `FSSupportedSchemes`), or possibly
`FSSupportsServerURLs` — `/sbin/mount` recognises both and the header documents
`FSSupportedSchemes` only for `FSGenericURLResource`. Determine empirically with
the prototype.

The extension point identifier `com.apple.fskit.fsmodule` and the `XPC!` package
type look right and need no change.

## Reference implementation: Apple's own URL-resource module

`/System/Library/ExtensionKit/Extensions/com.apple.fskit.ftp.appex` is a
**shipping** FSKit filesystem with no block device behind it — the same shape
Backend A needs. Its Info.plist is the authority on how to declare one:

```
"EXAppExtensionAttributes" => {
    "EXExtensionPointIdentifier" => "com.apple.fskit.fsmodule"
    "EXExtensionPrincipalClass" => "ftpFileSystem"
    "FSShortName" => "ftp"
    "FSSupportedSchemes" => [ "ftp" ]
    "FSSupportsBlockResources" => false
    "FSSupportsGenericURLResources" => true
    "FSSupportsPathURLs" => false
    "FSRequiresSecurityScopedPathURLResources" => false
    "FSMediaTypes" => { }
    "FSPersonalities" => { }
    ...
}
```

**Every `FS*` key lives inside `EXAppExtensionAttributes`.** Placed at the top
level of the Info.plist they are silently ignored, and the module advertises no
resource support at all — which is how ours was originally written. This cost a
build cycle to find and is the single most important gotcha here.

`EXExtensionPrincipalClass` is set because Apple's module is ObjC; a Swift
extension using `@main` + `UnaryFileSystemExtension` supplies its entry point
through ExtensionFoundation instead. If the extension fails to launch, adding
`$(PRODUCT_MODULE_NAME).ISCSIFileSystemExtension` is the first thing to try.

## Status: verified working

- The extension builds and signs on the VM (team 4A27X5PJP3).
- `Package.swift` had no `products:` section, so the Xcode target could not link
  `iSCSIKit` ("Missing package product"). Fixed by exposing it as a library.
- The `.appex` was never embedded in the host app. Added an "Embed ExtensionKit
  Extensions" copy phase to `$(EXTENSIONS_FOLDER_PATH)` (`Contents/Extensions`)
  plus a target dependency.
- FSKit **discovers** the module:
  `pluginkit -m -v -p com.apple.fskit.fsmodule` lists
  `me.herko.iSCSIInitiator.fsext` alongside Apple's msdos/exfat/ftp, and
  `fskit_agent` logs a new module list when the app is installed.

## Blocker: the module must be enabled by the user

```
$ sudo mount -F -t iSCSI iscsi://proto/lun0 /Users/herko/fsmnt
Module me.herko.iSCSIInitiator.fsext is disabled!
mount: Unable to invoke task
```

`/sbin/mount` gates on `FSModuleIdentity.isEnabled` (the string `isEnabled` and
the message `Module %s is disabled!` are both in the `mount` binary). This is a
**user-consent gate, separate from pluginkit registration**:

- `pluginkit -e use -i me.herko.iSCSIInitiator.fsext` reports the module as `+`
  enabled, for both the user and root, and `mount` still refuses.
- `fskitd` logs *"Call fskit_agent to set enabled state of identifier"* and
  exposes `setEnabledStateForIdentifier:newState:replyHandler:` over XPC, but
  that is a private interface behind an entitlement check.
- There is no `defaults` domain for FSKit yet and no CLI equivalent was found.

The expected resolution is to toggle it once in System Settings → General →
Login Items & Extensions → File System Extensions. **That did not work: the UI
does not allow the switch to be turned on** (reported by the project owner
on 2026-08-13). So the blocker is currently unresolved.

Note this is a real product consideration, not just a test-rig annoyance: any
user of this project will have to get past the same gate after installing.

> **RESOLVED on macOS 27.0 — 2026-08-14.** The switch works. It was suspect #2
> below: the build, not the plist. See "Resolution" at the end of this section.
> Everything between here and there is the record of how it was diagnosed, kept
> because the ordered-suspects list is what produced the answer.

### Evidence gathered so far on the dead toggle

All of these were checked and are **healthy**, so none of them is the cause:

| checked | result |
|---|---|
| code signature of the `.appex` | valid; Apple Development, team 4A27X5PJP3 |
| `codesign --verify --deep --strict` on the app | valid on disk, satisfies its Designated Requirement |
| `com.apple.developer.fskit.fsmodule` entitlement | present and `true` |
| duplicate registrations | none — only `/Applications/…/iSCSIFSExtension.appex` |
| crash reports | none, in either user or system DiagnosticReports |

The one suggestive signal: `launchd` repeatedly logs *"remove all extension
instances … total of 0 extension instances were found to remove"*. The extension
is registered but has **never been instantiated even once**.

### Ordered suspects for the dead toggle

1. **Missing `EXExtensionPrincipalClass`.** Apple's `ftp` module declares it and
   ours does not (a Swift `@main` + `UnaryFileSystemExtension` extension is
   supposed to supply its entry point via ExtensionFoundation). If ExtensionKit
   cannot resolve a principal class it cannot instantiate the extension, which
   would explain both the zero instances and an inert switch. Try
   `@objc(ISCSIFileSystemExtension)` on the class plus the matching plist key.
2. **The app is a Debug build** carrying `get-task-allow` and a
   `__preview.dylib`; a Release build signed for distribution may be required
   before the system will enable a filesystem module.
3. **`LSMinimumSystemVersion`** — Apple's module sets it; ours does not.
4. Turning on private-data logging (`sudo log config --mode private_data:on`,
   viable since SIP is off) would unmask `fskit_agent`'s "New module list
   <private>" records and likely name the actual rejection reason. This was
   about to be tried when the VM froze.

### Resolution: it was the build (2026-08-14, macOS 27.0)

Suspect #2 was right. A **notarized Developer ID Release build, installed by
dragging from a mounted DMG to `/Applications`, enables from the System Settings
switch on the first try** — with SIP on, on real hardware. Nothing else changed:
no `EXExtensionPrincipalClass` (suspect #1 was never needed), no private
entitlement, no plist editing, no `pluginkit -e use`.

`LSMinimumSystemVersion` (suspect #3) was added in the same build, so strictly
it is confounded with the signing change and cannot be individually cleared. It
is inert metadata that matches Apple's own modules, so it stays; it is not worth
a second build to isolate.

Measured on Zoidberg-6, macOS 27.0, SIP enabled, via `scripts/m0b-observe.sh`
(full transcript in `docs/m0b/m0b-Zoidberg-6-27.0.log`). Read the evidence, not the
run labels — the observations were fired in back-to-back batches, so the labels
do not mark what they say:

| time | `enabledModules.plist` | `mount -F -t iSCSI` | fskitd pid |
|---|---|---|---|
| 13:01:00–:06 | ours ABSENT | `Module … is disabled!` | 737 |
| 13:01:46–:48 | **ours PRESENT** | **mounted** | 737 |
| 13:12:55–13:13:02 | ours PRESENT | mounted | 694 |
| 13:18:40–:46 | ours PRESENT | mounted | 694 |

Three things that matter for the product, in descending order:

1. **The switch takes effect immediately.** fskitd stayed pid 737 across the
   ABSENT→PRESENT transition and the first successful mount, so no reboot and no
   daemon restart was involved. Setup can flip from "action needed" to "ready"
   while the user watches.
2. **The entry survives a reboot.** pid 737→694 (and `fskit_agent` 53772→1319,
   with fskitd logging `Old modules (null)`) is one clean boot; ours is still in
   `enabledModules.plist` afterwards and still mounts. The entry postdates the
   module's 13:00:30 pluginkit registration, so the pruning rule described at the
   end of this document is *satisfied*, not merely untested.
3. **`Extension is not entitled to run in the App Sandbox` is noise.**
   `fskit_agent` logs it before and after enablement — including at 13:13:24,
   while our module was enabled and mounting. It names an opaque
   `_EXExtensionIdentity`, not necessarily ours. Do not chase it on macOS 27.

Consequence for the shipping app: **branch E-toggle**. Deep-link to the pane and
observe `FSModuleIdentity.isEnabled`. No `enabledModules.plist` writing ships on
macOS 27, which also means no Full Disk Access prompt in the setup flow.

The related external report ([andrewgazelka/loaf#1](https://github.com/andrewgazelka/loaf/issues/1),
Apple's own FSKitSample refusing to enable) is consistent with this: it describes
macOS 26.1/26.2. The enablement branch is therefore a **runtime decision keyed on
OS version**, not a compile-time constant, until the 26.x leg is measured.

### The 26.x leg: the same build still refuses (2026-08-14, macOS 26.6.1)

Rig: `herko@192.168.0.39`, a UTM guest running 26.6.1 (25G76), SIP enabled, with
**no Xcode, no Apple ID and no developer account** — the end-user acceptance
machine. Same notarized DMG, downloaded-quarantine stamped, dragged to
`/Applications` in Finder, launched through the Gatekeeper dialog. A COW clone of
the pre-install state is at `~/UTM-backups/`, so this is re-runnable from zero.

Everything up to the gate works, and works identically to macOS 27:

| step | 26.6.1 |
|---|---|
| `spctl -a -t install` on the DMG | `accepted`, `source=Notarized Developer ID` |
| quarantine after the drag+launch | `01c3;…;Safari;…`, byte-identical in shape to 27 |
| bundle contents | same `CodeResources` (1716 B) and `embedded.provisionprofile` |
| pluginkit registration | registered; `fskit_agent` logs `Added 1 identifiers`, no complaint |
| `FSClient.shared.installedExtensions` | works; reports our module and per-module `isEnabled` |
| **the System Settings switch** | **row present, switch off, will not move** |

So `FSClient` is usable on 26.x — step E of the setup machine does not need a
macOS 27 API to *observe* state. Only the enable action is blocked.

Two findings from this leg, in order of usefulness:

**1. The `x-apple.systempreferences:` deep link does not work on 26.6.1.** Risk R7,
confirmed. `com.apple.LoginItems-Settings.extension` did not navigate anywhere;
the pane had to be reached by hand. `FSClient.openFileSystemExtensionsSettings()`
is macOS 27 only, so on 26.x there is currently **no reliable way to put the user
in front of the switch** — which matters even if the switch is later fixed.

**2. `fskitd` fails a team-ID lookup, and only on 26.x.** During the toggle
attempts (13:42:01, 13:42:02, 13:43:31, 13:43:33) `fskitd` logged, every time:

```
Incomming connection, entitled 0
About to get current agent for 501
Received error '(null)', errno 2, retrieving team ID
```

That message does not appear anywhere in macOS 27's log for the whole day, on the
FSKit subsystem, including the window in which the switch actually worked. It is
not a logging difference: `strings /usr/libexec/fskitd` on **27** still contains
both `Received error '%@', errno %d, retrieving team ID` and `%s did not find
team ID`, so 27 runs the same code and succeeds where 26.6.1 fails. Note the
error object is `(null)` while `errno` is 2, so `errno` is probably stale from an
unrelated call and should not be read as a literal ENOENT — the reliable part of
the signal is *"no team ID was found"*.

Not chased further because it does not change what ships. Ruled out as causes
along the way: the appex's own staple (absent on **both** machines — nested code
is covered by the outer bundle's ticket, so this is normal), the entitlements
(`com.apple.developer.fskit.fsmodule => true` plus `app-sandbox => true` on the
appex, verified from the signature *on the VM*), and the
`Extension is not entitled to run in the App Sandbox` line, which on this machine
is emitted by `chronod` about somebody else's widget.

**The confound, and how it was cleared.** The machine where the switch works
differed from the machine where it refuses in *four* ways, not one: macOS 27.0 vs
26.6.1, a developer account signed in vs not, Xcode installed vs not, and real
hardware vs a VM. If the discriminator had been the signed-in developer account,
v1 would have been dead for every end user, so it was tested rather than assumed:

> A **fresh local user account** (`fskittest`, admin, no Apple ID, no developer
> account) was created on the macOS 27 machine, and from that account the switch
> toggled with no issue. Since `enabledModules.plist` is per-user, this isolates
> the account on identical OS and hardware. **The developer account is not the
> gate.**

That leaves OS version as the discriminator, corroborated by loaf#1 and by the
`fskitd` team-ID branch above. Hardware-vs-VM remains formally unisolated, but it
no longer threatens the product: the failure is on the *older* OS, which is the
opposite of what a VM-specific restriction would predict, and the fallback below
works in the VM anyway.

### The 26.x fallback works, and does not need a reboot

With the switch refusing, the documented plist route was run end to end on
26.6.1. It works:

| step | result |
|---|---|
| `plutil -insert 0 -string me.herko.iSCSIInitiator.fsext enabledModules.plist` | written |
| `killall fskit_agent`, then mount | entry survives, but **`Module … is disabled!`** |
| reboot | entry **survives** — not pruned |
| mount after reboot | **`MOUNTED`**, `lun0.img` visible, clean unmount |

**`fskitd` is what holds the stale state, not `fskit_agent`.** An earlier draft of
this section claimed the live state is only re-read at boot; that was wrong, and
wrong in a way that would have put a needless "restart your Mac" step in the
shipping setup flow. Only `fskit_agent` had been restarted — never `fskitd`, which
is the root daemon `/sbin/mount` actually consults. Re-run from a clean
live-disabled baseline (plist restored, rebooted, mount confirmed failing):

| step | result |
|---|---|
| write the entry, restart nothing | `Module … is disabled!` |
| **`sudo killall fskitd`** | **`MOUNTED`** |

So the whole 26.x enablement is: write the entry, restart `fskitd`, done — no
reboot, no logout.

**The restart must be a signal, not `launchctl`.** An earlier draft recommended
`launchctl kickstart -k` as "the supported spelling". It does not work here, for
two separate reasons, both found the hard way:

```
$ sudo launchctl kickstart -k system/com.apple.fskitd
Could not find service "com.apple.fskitd" in domain for system      # wrong label

$ sudo launchctl kickstart -k system/com.apple.filesystems.fskitd
Could not kickstart service "...": 150: Operation not permitted
                                        while System Integrity Protection is engaged
```

The label is `com.apple.filesystems.fskitd` (from
`/System/Library/LaunchDaemons/com.apple.filesystems.fskitd.plist`), and SIP
forbids `launchctl` job control on Apple's daemons regardless. `sudo killall
fskitd` **is** permitted under SIP — signalling a process is not job control —
and launchd respawns it immediately. That is what shipping code has to do.

It needs root, which is free here because M2 installs a root daemon anyway.

The entry was not pruned, because it was written after the module's pluginkit
registration (registration 20:35:06 UTC, write ~20:44). The ordering rule at the
end of this document held exactly as recorded.

### M0-b.2: the app can do the write itself, silently

The results above all came from an ssh shell, which inherits the terminal's TCC
grants. `group.com.apple.fskit.settings` is a *foreign* group container, so the
real question was whether a freshly installed app is allowed the same thing.

Answered with a notarized 0.1.1 build carrying `FSKitEnablement.enableModule()`
behind a button, drag-installed on the clean 26.6.1 VM:

- **The write succeeds. No consent prompt, no `EPERM`.** The entry lands at index
  0 with Apple's five preserved, and reads back correctly.
- **`containerURL(forSecurityApplicationGroupIdentifier:)` returned a URL**, for a
  group the app is not a member of and has no entitlement for. This was expected
  to return nil and to need the constructed-path fallback. It did not. The
  fallback stays in the code — this is undocumented behaviour that could change —
  but the supported-looking route currently works.
- Nothing became live until `fskitd` was signalled, exactly as designed.

End-to-end on 26.6.1, with the user touching neither Terminal nor System
Settings: drag-install → launch → button → root `killall fskitd` → `mount -F`
succeeds and `lun0.img` is there. **The 26.x fallback is viable as a shipping
path**, and needs no Full Disk Access step in the setup machine.

### Decision: v1 keeps a 26.0 floor and branches at runtime

| | macOS 27+ | macOS 26.x |
|---|---|---|
| mechanism | `FSClient.openFileSystemExtensionsSettings()`, user flips the switch | consent sheet → app writes the entry → daemon signals `fskitd` |
| readiness signal | `FSModuleIdentity.isEnabled` | `FSModuleIdentity.isEnabled` (verified to agree with `mount` on 26.x) |
| user actions | one switch | one "Enable" button |
| Full Disk Access | no | no |
| reboot | no | no |

Branch on OS version at **runtime**, never at compile time.

Note that the 26.x path is the *smoother* of the two — the user does less. That
is not a reason to use it on 27. The switch is a user-consent gate; routing
around it where it works would be circumventing consent rather than improving
the experience. On 26.x there is no working switch and no way to navigate to the
pane, so the app obtains that consent itself, in a sheet that names
`enabledModules.plist` explicitly before touching it.

Two obligations that come with shipping the fallback:

1. **File the Feedback** (`feedback-fskit-enablement-26x.md`). Shipping a
   workaround for an OS bug with no tracking number means never learning when it
   is fixed, and this one should be deleted the moment 26.x enables properly.
2. **The post-update repair path is not optional on 26.x.** A Sparkle update
   replaces the bundle, which re-registers the appex, which makes the existing
   enablement entry predate the registration — and `fskit_agent` prunes exactly
   those at the next boot. The every-launch state machine has to notice and
   rewrite. On 27 the same event costs the user a second trip to the switch.

## Soak and crash consistency (2026-08-13)

### 20-minute soak — passed

`scripts/soak.py`, 4 workers plus 3 GB of memory pressure, against APFS on the
real 40 GiB LUN:

```
written=38696 MB  read=77186 MB
files=268655  rmwPatches=235278  verifies=503933  errors=0
```

Throughput stayed flat (27–35 MB/s write, 53–71 MB/s read) for the whole run.
Two things this actually establishes:

- The **read-modify-write path was exercised 235k times** with every file
  verified by SHA-256 afterwards, so the alignment fix holds under sustained
  unaligned, odd-sized I/O rather than just in the cases I thought to test.
- No **loopback-writeback deadlock**. Dirty disk-image pages are written back
  *through* a userspace filesystem, which is the classic NFS-loopback hazard;
  under 3 GB of pressure with pageouts occurring, nothing stalled.

### Crash consistency — passed

Method: write 64 × 1 MiB files, `fsync` each, `fsync` the directory, `sync`.
Save the manifest **to the host**, because verifying against a manifest stored
on the volume under test would prove nothing. Start a write load so dirty state
is in flight, then cut power with `utmctl stop --force` — a real power cut, not
a shutdown. Reboot, remount, check.

```
** The volume /dev/rdisk9s1 ... appears to be OK.
** The container /dev/disk8 appears to be OK.
=== verified 64/64 intact, 0 missing, 0 corrupt
CRASH-CONSISTENCY-PASSED
```

So with FUA write-through, data that `fsync` reported durable *was* durable, and
APFS came back consistent despite never having a barrier honoured beneath it.

**Cost:** 128 MiB writes ran at **76.9 MB/s with FUA vs 162 MB/s without** —
roughly half the write throughput. That is the price of crash consistency here,
and it is why `writeThrough` is a parameter rather than a hardcoded constant.

### Negative control: also passed — and that invalidates the experiment

Repeating the identical cut with `ISCSI_WRITE_THROUGH=0` (no FUA at all):

```
** The volume ... appears to be OK.   ** The container ... appears to be OK.
=== verified 64/64 intact, 0 missing, 0 corrupt
CRASH-CONSISTENCY-PASSED
```

The control passed too, so **FUA is not what made the first run pass**, and the
reason is a flaw in the test rather than a property of the system:

> `utmctl stop --force` cuts power to the **initiator**. The target never lost
> power. A target-side volatile write cache survives an initiator crash intact,
> so this experiment cannot discriminate FUA no matter how many times it is run.

FUA protects against *target* power loss. Testing that means cutting power to
the NAS, which is not something to do casually to a machine holding real data.

Two things were nonetheless settled:

- The target **does** have a volatile write cache. With the MODE SENSE fix
  actually deployed, the daemon reports `write cache ENABLED` at login. (The
  earlier "unknown" reading came from a stale binary — a build failure had left
  the previous daemon running, see below.)
- The **initiator stack is crash-safe**: APFS, DiskImages, the FSKit extension
  and the daemon together survive an abrupt initiator power loss with fsync'd
  data intact and the filesystem consistent, with and without FUA.

Because the target's cache is volatile and confirmed enabled, `writeThrough`
stays on by default: it is the only thing standing between a target power
failure and the loss of writes APFS believes are durable. The cost is real —
**76.9 MB/s with FUA vs 117 MB/s without** on the same 128 MiB test.

**Method note.** Two false negatives in this session came from the same mistake:
running `strings` against binaries that do not contain plain symbol tables —
shared-cache framework stubs, and kernel collections. Both times a control
(the same probe against a known-present symbol) exposed it. Do not conclude
"feature absent" from `strings` without that control.

## WORKING ON A REAL iSCSI LUN (2026-08-13, macOS 26.6.1)

The complete Backend A chain, against the TrueNAS scratch target:

```
APFS  ->  /dev/disk9s1  ->  DiskImages (CRawDiskImage)  ->  lun0.img
      ->  our FSKit module  ->  XPC  ->  iscsid  ->  TCP  ->  target
```

| step | result |
|---|---|
| `mount -F -t iSCSI iscsi://192.168.0.101/<iqn>/0` | mounts; `lun0.img` = 42949672960 B (40 GiB), geometry from READ CAPACITY |
| `hdiutil attach -imagekey diskimage-class=CRawDiskImage` | attaches |
| `newfs_apfs` | succeeds; container **synthesized** as `/dev/disk9s1` |
| `mount_apfs` | mounts; `df` reports the full 40 GiB |
| positional readdir/getattr probe | both complete — no wedge |
| 128 MiB random write | 162 MB/s |
| unmount → detach → reattach → remount → SHA-256 | **byte-exact** |

### The bug that blocked this: block alignment

Before the fix the LUN mounted, read and wrote correctly, and `fsck_apfs`
pronounced the container healthy — but `diskarbitrationd` probed with `apfs`
and failed with EIO, so the container was never synthesized and nothing could
be mounted.

`ISCSIBlockDevice` requires block-aligned offsets and whole-block lengths
(`BlockDeviceError.misaligned`, plus a truncating `length / blockSize`), and
`DaemonStore` forwarded FSKit's arbitrary byte ranges unchanged. Against a
**4Kn** LUN that is invisible for ordinary file access — the page cache issues
aligned requests — and fatal for DiskImages, which reads the backing file at
512-byte granularity. Hence EIO *only* while probing.

Two things made this findable:

- **A control.** A 40 GiB *local* sparse image synthesizes its container fine,
  which ruled out image size and bare-container probing and pointed at
  `DaemonStore` specifically.
- **`fsck_apfs` disagreeing with `diskarbitrationd`.** When one reader calls the
  data healthy and another gets EIO, the data is fine and the *access pattern*
  is not.

The arithmetic now lives in `BlockAligner` (iSCSIKit) with 10 unit tests, so it
can be exercised without a live 4Kn target. One test records why this hid for so
long: with a 512-byte LUN every such request is already exact.

## Earlier: end to end with a local backing store

Our FSKit module mounts and the whole Backend A stack runs on it:

```
iscsi://proto/lun0 on /Users/herko/fsmnt (iSCSIProto, ..., fskit, mounted by herko)
-rw-r--r--  1 herko  staff  536870912  lun0.img
```

| step | result |
|---|---|
| `mount -F -t iSCSI iscsi://proto/lun0` | **mounts**; lifecycle logs `loadResource` → `activate` → `mount` |
| `lun0.img` visible at the declared size | 536870912 bytes |
| `hdiutil attach -imagekey diskimage-class=CRawDiskImage` | attaches → `/dev/disk8` |
| `newfs_apfs` + `mount_apfs` | both succeed |
| positional probe (readdir, then getattr) | **both complete** — no wedge |
| 32 MiB random write → unmount → detach → reattach → remount → SHA-256 | **byte-exact match** |

### Bugs found and fixed getting here, in order

Each cycle failed one layer deeper, which is what a sound stack looks like:

| symptom | cause |
|---|---|
| `Module … is disabled!` | enablement ordering (below) |
| `Filesystem iSCSI does not support operation mount` | missing `FSActivateOptionSyntax` |
| `loadResource failed: Operation not permitted` | sandboxed appex cannot write `/Users/Shared`; moved into the container |
| `Loading resource: Undefined error: 0` | `.active(status: fs_errorForPOSIXError(0))` attaches a real NSError with POSIX code 0; use the no-error form |
| `Loading resource: Protocol not supported` | `fskitd` logged *"unexpected container state"*: the state machine is notReady → ready → active, and `loadResource` is the transition to **ready**, not active |

`mount`'s error text is consistently less useful than `fskitd`'s log. When stuck,
read `log show --predicate 'process == "fskitd"'`.

### RESOLVED: there is no barrier signal — durability must ride on open/close

Instrumented run (counts from `BackingStore`), writing 32 MiB through APFS on
the attached image:

```
OPEN modes=1                  # FREAD
OPEN modes=3                  # FREAD|FWRITE
FIRST READ  off=536854528 len=16384
FIRST WRITE off=0 len=131072
CLOSE keeping=0 — reads=199/3016192B writes=123/38895616B maxIO=1048576
```

**Our read/write path is genuinely used** — 123 writes totalling 38.9 MB, max
I/O 1 MiB. Nothing is kernel-offloaded behind our back.

**No sync callback ever fires.** `synchronize` was not called once, and three
separate probes confirm it is not merely rare:

| probe | result |
|---|---|
| `sync(8)` with our volume mounted | no `synchronize` |
| `fsync()` on `lun0.img` | arrives as a plain write; no `synchronize` |
| `F_FULLFSYNC` on `lun0.img` | arrives as a plain write; no `synchronize` |

So on macOS 26.6 with `FSVolume.Operations`, an FSKit volume gets **no barrier
notification at all**. An APFS barrier on the disk image cannot be observed by
the extension underneath it.

What *is* observable is open/close: DiskImages opens `modes=3` and closes with
`keeping=0` around I/O batches. `closeItem` with no retained modes is therefore
the only durability hook available, and the extension now flushes there.

**Design consequence for the real backend.** Once `BackingStore` is iSCSI, every
write is already handed to the target in order — the extension receives them as
ordered `pwrite`s, so ordering is preserved. The residual risk is only the
target's volatile write cache. The defensible policy is:

1. `SYNCHRONIZE CACHE` on final close (the one real signal), and
2. either write-through/FUA on every write, or a target configured without a
   volatile write cache, for crash consistency during sustained I/O.

This is worth stating plainly because it is the *opposite* of the dext-side
barrier bug: there, flushes were silently elided by the kernel and the fix was
to make them reach the wire. Here they are never generated in the first place,
so correctness has to come from write policy rather than from honouring
barriers.

### Superseded note: flush does not reach our `synchronize`

The extension logs every `synchronize` call, and across a full run — including a
`sync` on the APFS volume and 32 MiB of writes — **not one was logged**. Data
integrity still held across the teardown cycle, because unmount flushes through
the normal write path.

So this is not a data-loss bug in the tested path, but the crash-consistency
question is open: whether an APFS barrier on the disk image becomes a durable
flush of the backing file. Given the barrier saga in `architecture.md`, verify
before trusting it. Note also that reads/writes are not currently logged, so
their absence from the log says nothing — only `synchronize` is instrumented.

`FSSupportsKernelOffloadedIO` (declared by Apple's msdos module) and the
`inhibitKernelOffloadedIO` item attribute are the first things to look at.

## Earlier: mechanism proven against Apple's module (same day)

The two questions that decide Backend A have been answered **yes**, without
needing our own module enabled — Apple's `msdos` FSKit module provides a
genuine userspace-served volume to test against.

`scripts/vm-diskimage-on-fskit.sh` runs the whole thing. Results:

| step | result |
|---|---|
| `mount -F -t msdos` — FSKit-served volume | mounts; options include the literal `fskit`, served by `com.apple.fskit.msdos.appex` |
| 256 MiB raw image created on that volume | ok |
| **Q1:** `hdiutil attach -imagekey diskimage-class=CRawDiskImage` | **attaches** → `/dev/disk9` |
| `newfs_apfs` on the attached device | ok (synthesized container `disk10`, volume `disk10s1`) |
| `mount_apfs` privately | ok |
| readdir, then getattr (the **positional probe** that wedges the dext) | **both complete** — no wedge |
| 8 MiB write + `sync` | ok, `df` confirms the space used |
| **Q2:** 32 MiB random write → unmount → detach → reattach → remount → SHA-256 | **byte-exact match** |

So DiskImages does not care that its backing file is served by a userspace
filesystem, the full APFS stack runs on top of it, and writes propagate all the
way down to the backing file and survive a teardown cycle. Backend A does not
have to wait on Apple, and the wedge does not follow it.

**Caveat on Q2:** this proves propagation through *Apple's* FSKit module. Our
extension's own `synchronize` / `write` implementations still have to be
verified once it can be mounted — `scripts/vm-fskit-proto.sh` does exactly that
and greps the extension log for `SYNCHRONIZE` calls.

Two gotchas the run exposed, both now handled in the script:

- **Use `msdos`, not `exfat`.** `mount -F -t exfat` fails with *"Filesystem
  exfat does not support operation mount"*; only `msdos` declares
  `FSActivateOptionSyntax` and `FSSupportsKernelOffloadedIO`.
- **APFS synthesizes a new container disk**, so the volume is not `${DEV}s1`.
  Find it by volume name. Relatedly, `mount_apfs … | tail -2 && echo MOUNTED`
  reports *tail's* status — the same class of pipeline-status bug that has bitten
  this project before; capture `$?` from the command itself.

### The enablement gate, located exactly

FSKit stores module enablement as a plain array of bundle identifiers in the
user's group container:

```
~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist
~/Library/Group Containers/group.com.apple.fskit.settings/probeOrder.plist
```

On the test VM:

```
enabledModules.plist          probeOrder.plist
  com.apple.fskit.apfs          me.herko.iSCSIInitiator.fsext   <- ours, known
  com.apple.fskit.exfat         com.apple.fskit.apfs
  com.apple.fskit.msdos         com.apple.fskit.exfat
  com.apple.filesystems.util.ntfs   com.apple.fskit.msdos
  com.apple.fskit.ftp           com.apple.filesystems.util.ntfs
                                com.apple.fskit.ftp
```

**Our module is in `probeOrder` but absent from `enabledModules`.** That single
absence is the whole gate — it is what makes `FSModuleIdentity.isEnabled` false
and what `mount` reports as *"Module … is disabled!"*.

So the System Settings switch does exactly one thing: append the bundle ID to
that array. Since the UI refuses to do it, the equivalent is:

```sh
G=~/Library/Group\ Containers/group.com.apple.fskit.settings
cp "$G/enabledModules.plist" "$G/enabledModules.plist.bak"
plutil -insert 0 -string me.herko.iSCSIInitiator.fsext "$G/enabledModules.plist"
killall fskit_agent      # force a reload
```

**This works, but only transiently** — and the transient success was extremely
informative. After adding the bundle ID, deduplicating the LaunchServices
registrations and rebooting, the module *was* enabled: `mount` stopped saying
"is disabled!" and instead said **"Filesystem iSCSI does not support operation
mount"**.

That is the identical error Apple's own `exfat` module gives, and `exfat` is the
one module that omits **`FSActivateOptionSyntax`**. So that key is what declares
mount/activate support. It has been added (matched to `ftp`'s `"o:"`).

### fskit_agent prunes modules it rejects

On the next boot, `fskit_agent` **rewrote `enabledModules.plist` and removed our
bundle ID**, leaving only Apple's five. So the file is not merely a mirror: the
agent validates each entry at startup and silently drops the ones it rejects.

That is almost certainly the same validation that makes the System Settings
switch refuse to turn on — the UI is not broken, the module is being judged
ineligible.

Sequence observed:

| state | result |
|---|---|
| bundle ID added, deduped, rebooted (no `FSActivateOptionSyntax`) | **enabled**; fails with "does not support operation mount" |
| rebuilt + reinstalled the app | registration lost entirely — "No extension with fsShortName found" |
| `pluginkit -a` to re-register (new UUID) | back to "is disabled" |
| rebooted | entry **pruned** from `enabledModules.plist` |

Two operational gotchas this exposed: replacing `/Applications/iSCSIApp.app`
drops the pluginkit registration (re-add the `.appex` explicitly), and enablement
does not survive re-registration.

### The rule: the enabled entry must be written AFTER the last registration

Four observations fix the ordering:

| sequence | outcome |
|---|---|
| insert entry → dedup → reboot | **enabled** |
| insert entry → reboot | **enabled** (entry survived) |
| `pluginkit -a` (new UUID) → reboot | entry **pruned** |
| in-place update → `pluginkit -a` → reboot | entry **pruned** |

So `fskit_agent` keeps an entry only if it postdates the module's current
pluginkit registration; an entry that predates it is treated as stale and
dropped. It was never about the Info.plist declaration.

**Working recipe** (a rebuild invalidates the registration, so all four steps
are needed every time):

```sh
# 1. install in place — do NOT rm -rf the app, that drops the registration
sudo rsync -a --delete <DerivedData>/iSCSIApp.app/ /Applications/iSCSIApp.app/
# 2. re-register the extension
pluginkit -a /Applications/iSCSIApp.app/Contents/Extensions/iSCSIFSExtension.appex
# 3. NOW add the enabled entry (must come after step 2)
G=~/Library/Group\ Containers/group.com.apple.fskit.settings
plutil -insert 0 -string me.herko.iSCSIInitiator.fsext "$G/enabledModules.plist"
# 4. reboot
sudo reboot
```

### First successful invocation of our module

With the module enabled, `mount -F -t iSCSI iscsi://proto/lun0` reached our code:

```
resource: FSGenericURLResource iscsi://proto/lun0
loadResource failed: ... Operation not permitted
```

This confirms the whole chain — the generic-URL resource model works, and FSKit
hands us exactly the `FSGenericURLResource` the design assumed.

The EPERM was ours: the appex is built with `com.apple.security.app-sandbox`, so
the backing file could not be created under `/Users/Shared`. Fixed by moving it
into the container (`NSHomeDirectory()/Documents`). This is prototype-only
storage — nothing outside the extension ever needs to see it, since the bytes
are served *as* a file by the filesystem itself.

### Still open



`scripts/vm-diskimage-on-fskit.sh` answers Backend A's decisive question — will
DiskImages attach a raw image living on an FSKit-served volume? — using Apple's
`exfat` FSKit module via `mount -F`, which ships enabled. It therefore
sidesteps the consent gate entirely. **It has not been run yet** (its first run
found the `hdiutil` tab-padding bug, since fixed). Run it before investing more
in the toggle: if DiskImages refuses there, Backend A is not viable in this
shape and the toggle does not matter.

## Prototype plan (deliberately not the real extension)

Two Backend A risks are untested and decide viability. Neither involves iSCSI, so
the prototype must not include it:

1. Will DiskImages attach a file that lives on an **FSKit (non-local) volume** at
   all?
2. Does **flush/sync** propagate from the disk image down through the FSKit
   `FSVolumeReadWriteOperations` path? Given the barrier saga, verify — never
   assume.

Prototype: a minimal `FSUnaryFileSystem` serving **one** fixed-size file backed by
local RAM or a plain file — no daemon, no XPC, no network. Then:

```
mount -F -t <module> <url> /Users/herko/fsmnt
hdiutil attach -imagekey diskimage-class=CRawDiskImage /Users/herko/fsmnt/lun0.img
newfs_apfs -v backendA /dev/diskN
```

and run the existing two-access probe from `vm-scratch-apfs.sh` against it.

`scripts/vm-fskit-proto.sh` automates the whole sequence with every step
bounded, and ends by grepping the extension's log for the resource kind it
received and for `SYNCHRONIZE` calls — so one run answers both questions.

### Ordered suspects if the first run fails

Do not implement these speculatively; check them in order only against an actual
failure:

1. **Extension never launches at mount** → add `EXExtensionPrincipalClass`
   (`$(PRODUCT_MODULE_NAME).ISCSIFileSystemExtension`). Apple's ftp module sets
   it; a Swift `@main` extension is supposed not to need it.
2. **Mount succeeds but no read/write calls arrive** → the likely causes are the
   missing `FSVolumeOpenCloseOperations` conformance (the image is opened before
   it is read) and the `inhibitKernelOffloadedIO` item attribute, which controls
   whether the kernel bypasses the extension for data transfers.

**Deferred, not blocking:** the loopback-writeback deadlock. Dirty pages of the
disk image are written back through a userspace filesystem, which is the classic
NFS-loopback hazard. Belongs in a soak test once the basic path works.
