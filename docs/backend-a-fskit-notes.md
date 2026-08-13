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

## VERDICT: Backend A's mechanism is sound (verified 2026-08-13, macOS 26.6.1)

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

Untested — writing to this file needs approval. It may also be re-read only at
agent start, or validated against something else on use.

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
