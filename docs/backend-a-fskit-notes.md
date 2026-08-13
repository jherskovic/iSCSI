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

**Deferred, not blocking:** the loopback-writeback deadlock. Dirty pages of the
disk image are written back through a userspace filesystem, which is the classic
NFS-loopback hazard. Belongs in a soak test once the basic path works.
