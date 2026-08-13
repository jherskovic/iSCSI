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

**Resolution: toggle it once in System Settings → General → Login Items &
Extensions → File System Extensions.** This is a one-time action per install and
needs GUI access to the VM. Everything else in the chain is already in place.

Note this is a real product consideration, not just a test-rig annoyance: any
user of this project will have to flip the same switch after installing.

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
