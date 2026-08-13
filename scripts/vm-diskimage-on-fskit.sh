#!/bin/bash
# vm-diskimage-on-fskit.sh — run ON the VM as root, STREAMED over ssh.
#
# Answers Backend A's question 1 WITHOUT needing our own FSKit module enabled:
#
#   Will DiskImages attach a raw image file that lives on an FSKit-served
#   (userspace, non-local) volume at all?
#
# Our module is stuck behind a one-time System Settings consent toggle, but
# Apple's own FSKit modules are enabled out of the box — and `mount -F` forces
# the FSKit path rather than the legacy kext. So mounting an ExFAT volume with
# `mount -F -t exfat` gives a genuine FSKit-served filesystem to test against.
#
# If DiskImages refuses here, Backend A cannot work and no amount of work on our
# extension changes that. If it succeeds, the mechanism is sound and our module
# only has to serve bytes correctly.
#
# Every step is bounded: macOS has no timeout(1), and a hang must not take the
# run with it.
set -uo pipefail

FSMNT=/Users/herko/exfatmnt
APFSMNT=/Users/herko/mnt4
IMG="$FSMNT/raw.img"

mkdir -p "$FSMNT" "$APFSMNT"

run() {
  local secs=$1 label=$2; shift 2
  "$@" >/tmp/dstep.out 2>&1 &
  local pid=$! i=0
  while [ $i -lt "$secs" ]; do
    kill -0 $pid 2>/dev/null || break
    sleep 1; i=$((i+1))
  done
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid 2>/dev/null; echo "${label}-BLOCKED"; return 1
  fi
  wait $pid; local rc=$?
  sed 's/^/    /' /tmp/dstep.out
  [ $rc -eq 0 ] && echo "${label}-OK" || echo "${label}-FAILED(rc=$rc)"
  return $rc
}

echo "=== $(date '+%H:%M:%S') DiskImages-on-FSKit probe"

# Clean slate; a stale mount would silently invalidate the whole result.
umount -f "$APFSMNT" 2>/dev/null
umount -f "$FSMNT" 2>/dev/null

echo "=== backing RAM disk for the ExFAT volume (1 GiB)"
# hdiutil pads its output with tabs, not just spaces — take field 1, don't trim.
RAM=$(hdiutil attach -nomount ram://2097152 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$RAM" ] && { echo NO-RAMDISK; exit 1; }
echo "=== ram disk: $RAM"

echo "=== format ExFAT"
run 90 NEWFS newfs_exfat -v fskitprobe "$RAM" || { hdiutil detach "$RAM"; exit 1; }

# -F is the whole point: it forces the filesystem to be handled as an FSKit
# FSModule rather than the in-kernel implementation.
echo "=== mount it through FSKit (mount -F)"
if ! run 60 FSMOUNT mount -F -t exfat "$RAM" "$FSMNT"; then
  echo "VERDICT: could not mount ExFAT via FSKit; probe inconclusive"
  hdiutil detach "$RAM"; exit 1
fi

echo "=== confirm the mount is really FSKit-served"
/sbin/mount | grep -F "$FSMNT" | sed 's/^/    /'
# A userspace FSKit mount shows up with the module's short name; the legacy kext
# would report plain "exfat" with no FSKit involvement. Also check that a
# UserFS/FSKit process is actually servicing it.
pgrep -fl 'fskit|exfat' 2>/dev/null | head -5 | sed 's/^/    /'

echo "=== create a 256 MiB raw image ON the FSKit volume"
run 120 MKIMG dd if=/dev/zero of="$IMG" bs=1m count=256 || { hdiutil detach "$RAM"; exit 1; }
ls -l "$IMG" | sed 's/^/    /'

echo "=== QUESTION 1: attach that file with DiskImages"
if run 90 ATTACH hdiutil attach -imagekey diskimage-class=CRawDiskImage \
      -nomount -noverify "$IMG"; then
  DEV=$(grep -o '/dev/disk[0-9]*' /tmp/dstep.out | head -1)
else
  echo "VERDICT: DiskImages will NOT attach a file on an FSKit volume."
  echo "         Backend A is not viable in this shape."
  hdiutil detach "$RAM"; exit 1
fi
[ -z "${DEV:-}" ] && { echo NO-DEVICE; hdiutil detach "$RAM"; exit 1; }
echo "=== attached as $DEV — DiskImages DOES work over an FSKit volume"

echo "=== newfs_apfs on $DEV"
run 120 NEWFS_APFS newfs_apfs -v backendAprobe "$DEV" || { hdiutil detach "$DEV"; hdiutil detach "$RAM"; exit 1; }

VOLDEV=$(diskutil list "$DEV" 2>/dev/null | grep -o "${DEV#/dev/}s[0-9]*" | tail -1)
[ -z "$VOLDEV" ] && { echo NO-VOLDEV; hdiutil detach "$DEV"; hdiutil detach "$RAM"; exit 1; }

echo "=== mount APFS privately at $APFSMNT"
run 60 APFSMOUNT mount_apfs "/dev/$VOLDEV" "$APFSMNT" || { hdiutil detach "$DEV"; hdiutil detach "$RAM"; exit 1; }

# The dext wedge is positional: first access completes, second blocks. Same
# probe shape here, so the result is directly comparable.
echo "=== first access: readdir"
run 30 READDIR ls -a "$APFSMNT"
echo "=== second access: getattr"
run 30 GETATTR stat "$APFSMNT"
echo "=== write + sync"
run 60 WRITE dd if=/dev/zero of="$APFSMNT/probe.bin" bs=1m count=8
run 60 SYNC sync

echo "=== teardown"
run 60 UNMOUNT umount "$APFSMNT"
run 60 DETACH hdiutil detach "$DEV"
run 60 FSUNMOUNT umount "$FSMNT"
hdiutil detach "$RAM" >/dev/null 2>&1

echo "=== $(date '+%H:%M:%S') done"
