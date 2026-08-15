# Clean-machine acceptance: 0.2.0, 2026-08-14

The plan's success criterion, stated at the top of it, was: *a person downloads a
DMG and mounts an iSCSI LUN without ever opening Terminal.* This is the run where
that became true.

## Rig

`herko@192.168.0.39` — UTM guest, macOS 26.6.1 (25G76), **SIP enabled**, no
Xcode, no Command Line Tools, no Apple ID, no developer account. Deliberately the
machine that most resembles a stranger's Mac. Target: a real TrueNAS at
192.168.0.101, `iqn.me.herko.planet-express:iscsi-driver-testing`.

## What was done, entirely in the GUI

1. Downloaded-quarantine DMG, `spctl` → `source=Notarized Developer ID`.
2. Dragged over the previous version, launched, cleared the Gatekeeper dialog.
3. Setup screen: registered the background service, approved it in System
   Settings, repaired the extension registration the drag had dropped.
4. **Discover** against 192.168.0.101 → the target's IQN, added with one click.
5. **Attach** → an APFS volume in Finder.
6. Copied files to it. Detached. Re-attached.

Terminal was never opened. Every command in this document was run afterwards, by
ssh, to verify what the GUI had done.

## What the machine looked like with it attached

```
iscsi://192.168.0.101/iqn.me.herko.planet-express:iscsi-driver-testing/0
    on /Users/herko/Library/Caches/me.herko.iSCSIInitiator/8efd44e1453c842a
    (iSCSIProto, nodev, nosuid, noowners, noatime, fskit, mounted by herko)

image-path : …/8efd44e1453c842a/lun0.img   ->  /dev/disk7
/dev/disk8s1 on /Volumes/nofua (apfs, local, nodev, nosuid, journaled, mounted by herko)
```

Three things in that output are worth reading closely:

- **`mounted by herko`, at every layer.** Nothing in the attach path runs as
  root. That is R2's resolution visible in the mount table.
- **`/dev/disk7` attaches, `/dev/disk8s1` mounts.** The APFS synthesized
  container gets a different disk number, which is exactly what made the bash
  version report "not mounted" for a healthy volume. Reading mount points from
  `hdiutil`'s own output rather than matching the device number is what handles
  it.
- **The tag `8efd44e1453c842a`** is `MountpointTag.derive`, the same 16 hex
  characters the shell pipeline produced.

Data integrity, 64 MiB of random bytes written and read back:

```
wrote:  d8346c9ab7133a3eb3e287d11d779393a3043d99eefeaff08771574f2f7b2f9f
read:   d8346c9ab7133a3eb3e287d11d779393a3043d99eefeaff08771574f2f7b2f9f
```

## What this verified that nothing before it could

Everything up to this point ran against `iscsi://proto/lun0` — a local file
served by the extension, with no network, no target, and no authentication. This
run was the first time the following had ever executed against real hardware:

- SendTargets discovery and its response parsing
- `TargetStore` persistence of a discovered target
- login against a real portal
- `hdiutil attach` on a LUN served over the network
- the re-attach path, which must find the existing mount rather than stacking a
  second one on a path already in use

## Still unverified

Being explicit, because "it worked" is easy to over-read:

- **CHAP.** This target needs none, so the credential path — keychain storage,
  `hasCHAPSecret`, authenticated discovery, authenticated login — has unit tests
  and no field run.
- **Mutual CHAP**, which has a field in the editor and no exercise at all.
- **Multiple LUNs / `reportLUNs`.** One target, LUN 0.
- **R3**, whether a root daemon can read the keychain before login. Only matters
  once auto-attach exists.
- **Sparkle updates**, uninstall, and behaviour across a reboot with a volume
  attached.
