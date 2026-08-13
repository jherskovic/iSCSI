#!/bin/bash
# vm-apfs-control.sh — run ON the VM as root, STREAMED over ssh.
#
# CONTROL EXPERIMENT: no iSCSI, no dext, no network. Build an APFS volume on a
# RAM disk and run the exact probe sequence that wedges the iSCSI volume.
#
# The iSCSI LUN hangs on statfs — the first VFS operation on the volume —
# without issuing a single SCSI command. That is consistent with a bug in our
# device, and equally consistent with APFS being broken in this VM. Those two
# have never been told apart, and every conclusion about the storage stack
# depends on which it is. A RAM disk removes our driver from the picture
# entirely: if statfs hangs here too, nothing we built is implicated.
set -uo pipefail

SIZE_MB=${SIZE_MB:-512}
VOL=apfsControl

echo "=== creating ${SIZE_MB} MiB ram disk"
DEV=$(hdiutil attach -nomount "ram://$((SIZE_MB * 2048))") || { echo RAMDISK-FAILED; exit 1; }
# hdiutil pads the device name with TABS, not just spaces — `tr -d ' '` leaves
# them and newfs_apfs then fails on a path that looks identical when printed.
DEV=$(echo "$DEV" | awk '{print $1}')
echo "=== ram disk: $DEV"
trap 'hdiutil detach "$DEV" -force >/dev/null 2>&1' EXIT

echo "=== newfs_apfs on the whole ram disk"
newfs_apfs -v "$VOL" "$DEV" || { echo NEWFS-FAILED; exit 1; }
sleep 2

echo "=== mounting"
diskutil mount "$VOL" || { echo MOUNT-FAILED; exit 1; }
MNT="/Volumes/$VOL"
echo "=== mounted at $MNT"

# Same escalation, same order, same markers as vm-apfs-mount-only.sh, so the
# two runs can be compared line for line.
probe() {
  echo "=== PROBE: $1"
  shift
  "$@" >/dev/null 2>&1
  echo "=== PROBE-OK rc=$?"
}

probe "mount table only (no VFS op on the volume)" sh -c "mount | grep $VOL"
probe "statfs the mount point"                     stat -f %d "$MNT"
probe "getattr the root vnode"                     stat "$MNT"
probe "readdir the root"                           ls -a "$MNT"
probe "full listing with per-entry stat"           ls -la "$MNT"
echo "=== ALL-PROBES-SURVIVED"

echo "=== write + flush for good measure"
dd if=/dev/urandom of="$MNT/blob" bs=1m count=16 2>/dev/null && sync && echo "=== WRITE-OK"
diskutil unmount "$MNT" >/dev/null 2>&1 && echo "=== UNMOUNT-OK"
echo "=== DONE"
