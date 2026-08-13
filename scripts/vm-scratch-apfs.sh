#!/bin/bash
# vm-scratch-apfs.sh — run ON the VM as root, STREAMED over ssh.
#
# ISOLATION EXPERIMENT. Requires the dext built with ISCSI_DEXT_SCRATCH_DISK 1,
# which serves a RAM buffer inside the dext itself.
#
# That removes, in one step, everything downstream of our SCSI emulation:
#   - the daemon (no iscsid, no user client, no shared arena)
#   - the network and the iSCSI target
#   - the 4096-byte block size (scratch mode uses 512)
#
# What remains is our dext answering SCSI commands out of memory. So:
#
#   wedges too  -> the bug is in our dext's SCSI emulation, and the reproducer
#                  becomes tiny and self-contained — no target, no daemon
#   works fine  -> the emulation is sound and the cause lies in the daemon
#                  path, the network round-trip, or the 4Kn block size, each of
#                  which can then be reintroduced one at a time
#
# Same probe shape as vm-apfs-private.sh: mount outside /Volumes, first access
# then second access, because the failure is positional.
set -uo pipefail
mkdir -p /Users/herko/logs /Users/herko/mnt2

our_disk() {
  ioreg -r -c IOSCSIPeripheralDeviceType00 -l 2>/dev/null \
    | grep -m1 -o '"BSD Name" = "disk[0-9]*"' | grep -o 'disk[0-9]*'
}

echo "=== waiting for the scratch disk (no daemon needed in this mode)"
DISK=""
for _ in $(seq 1 40); do
  d=$(our_disk)
  if [ -n "$d" ] && diskutil info "$d" >/dev/null 2>&1; then DISK="$d"; break; fi
  sleep 1
done
[ -z "$DISK" ] && { echo NO-DISK; exit 1; }
echo "=== disk: $DISK"
diskutil info "$DISK" 2>/dev/null | grep -iE "Disk Size|Block Size|Device Block" | sed 's/^/    /'

# FS=apfs (default) or exfat. ExFAT ran end-to-end over iSCSI in earlier work,
# so if it survives here while APFS wedges, the failure needs APFS's access
# pattern; if ExFAT wedges too, the driver breaks the block layer regardless of
# filesystem and APFS is incidental.
FS=${FS:-apfs}
echo "=== newfs ($FS) on the scratch disk"
if [ "$FS" = "exfat" ]; then
  newfs_exfat -v scratchTest "/dev/$DISK" > /Users/herko/logs/scratch-newfs.out 2>&1
else
  newfs_apfs -v scratchTest "/dev/$DISK" > /Users/herko/logs/scratch-newfs.out 2>&1
fi
NEWFS_RC=$?
sed 's/^/    /' /Users/herko/logs/scratch-newfs.out
[ "$NEWFS_RC" -eq 0 ] || { echo "NEWFS-FAILED rc=$NEWFS_RC"; exit 1; }
echo "=== newfs ok"
sleep 3

if [ "$FS" = "exfat" ]; then
  # ExFAT has no container/synthesized device; the filesystem lives on the disk.
  VOLDEV="/dev/$DISK"
else
  VOLDEV=$(diskutil info scratchTest 2>/dev/null | awk '/Device Node:/{print $3}')
fi
[ -z "$VOLDEV" ] && { echo NO-VOLDEV; diskutil list | sed 's/^/    /'; exit 1; }
echo "=== volume device: $VOLDEV"

echo "=== mounting privately at /Users/herko/mnt2"
if [ "$FS" = "exfat" ]; then
  mount -t exfat "$VOLDEV" /Users/herko/mnt2 || { echo MOUNT-FAILED; exit 1; }
else
  mount_apfs "$VOLDEV" /Users/herko/mnt2 || { echo MOUNT-FAILED; exit 1; }
fi
echo "=== mounted"

echo "=== first access: readdir"
ls -a /Users/herko/mnt2 >/dev/null 2>&1 &
p=$!
sleep 20
kill -0 $p 2>/dev/null && echo "READDIR-BLOCKED" || echo "READDIR-COMPLETED"

echo "=== second access: getattr"
stat /Users/herko/mnt2 >/dev/null 2>&1 &
q=$!
sleep 20
kill -0 $q 2>/dev/null && echo "GETATTR-BLOCKED" || echo "GETATTR-COMPLETED"

echo "=== raw read (bypasses APFS)"
dd if="/dev/r$DISK" of=/dev/null bs=4096 count=1 >/dev/null 2>&1 &
r=$!
sleep 15
kill -0 $r 2>/dev/null && echo "RAWREAD-BLOCKED" || echo "RAWREAD-COMPLETED"

umount /Users/herko/mnt2 >/dev/null 2>&1 && echo "=== UNMOUNT-OK"
echo "=== DONE"
