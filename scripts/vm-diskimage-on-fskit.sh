#!/bin/bash
# vm-diskimage-on-fskit.sh — run ON the VM as root, STREAMED over ssh.
#
# Answers Backend A's two decisive questions WITHOUT needing our own FSKit
# module enabled:
#
#   1. Will DiskImages attach a raw image file that lives on an FSKit-served
#      (userspace, non-local) volume at all?
#   2. Do writes propagate all the way down through the userspace filesystem to
#      the backing file, and survive a full detach/reattach cycle?
#
# Our module is stuck behind an enablement gate, but Apple's own FSKit modules
# ship enabled, and `mount -F` forces the FSKit path rather than the in-kernel
# one. So Apple's msdos module gives a genuine userspace-served volume to test
# against — the resulting mount reports the literal `fskit` option and is served
# by com.apple.fskit.msdos.appex.
#
# Use msdos, NOT exfat: on macOS 26.6 `mount -F -t exfat` fails with
# "Filesystem exfat does not support operation mount". Only msdos declares
# FSActivateOptionSyntax and FSSupportsKernelOffloadedIO.
#
# RESULT (2026-08-13, macOS 26.6.1): everything below passes, including a
# byte-exact SHA-256 match across the teardown cycle. Backend A's mechanism is
# sound; see docs/backend-a-fskit-notes.md.
set -uo pipefail

FSMNT=/Users/herko/msdosmnt
APFSMNT=/Users/herko/mnt4
IMG="$FSMNT/raw.img"

mkdir -p "$FSMNT" "$APFSMNT"

# Bounded step runner: macOS has no timeout(1), and a hang must not take the run
# with it. Note the explicit rc capture — piping to tail would report tail's
# status and silently turn a failure into a pass.
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

cleanup() {
  umount -f "$APFSMNT" 2>/dev/null
  [ -n "${DEV:-}" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  umount -f "$FSMNT" 2>/dev/null
  [ -n "${RAM:-}" ] && hdiutil detach "$RAM" -force >/dev/null 2>&1
}
trap cleanup EXIT

echo "=== $(date '+%H:%M:%S') DiskImages-on-FSKit probe"

umount -f "$APFSMNT" 2>/dev/null
umount -f "$FSMNT" 2>/dev/null

echo "=== backing RAM disk for the FSKit volume (1 GiB)"
# hdiutil pads its output with tabs, not spaces — take field 1, don't trim.
RAM=$(hdiutil attach -nomount ram://2097152 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$RAM" ] && { echo NO-RAMDISK; exit 1; }
echo "=== ram disk: $RAM"

echo "=== format FAT32"
run 90 NEWFS newfs_msdos -F 32 -v FSKITPROBE "$RAM" || exit 1

echo "=== mount it through FSKit (-F forces the FSModule path)"
run 60 FSMOUNT mount -F -t msdos "$RAM" "$FSMNT" || exit 1

echo "=== confirm the mount is genuinely FSKit-served (expect the 'fskit' option)"
/sbin/mount | grep -F "$FSMNT" | sed 's/^/    /'
if ! /sbin/mount | grep -F "$FSMNT" | grep -q fskit; then
  echo "NOT-FSKIT-SERVED — probe is meaningless, abort"; exit 1
fi
pgrep -fl 'fskit.msdos' 2>/dev/null | head -1 | cut -c1-90 | sed 's/^/    /'

echo "=== create a 256 MiB raw image ON the FSKit volume"
run 120 MKIMG dd if=/dev/zero of="$IMG" bs=1m count=256 || exit 1

echo "=== QUESTION 1: attach that file with DiskImages"
if run 90 ATTACH hdiutil attach -imagekey diskimage-class=CRawDiskImage \
      -nomount -noverify "$IMG"; then
  DEV=$(grep -o '/dev/disk[0-9]*' /tmp/dstep.out | head -1)
else
  echo "VERDICT: DiskImages will NOT attach a file on an FSKit volume."
  echo "         Backend A is not viable in this shape."
  exit 1
fi
[ -z "${DEV:-}" ] && { echo NO-DEVICE; exit 1; }
echo "=== attached as $DEV — DiskImages DOES work over an FSKit volume"

echo "=== newfs_apfs on $DEV"
run 120 NEWFS_APFS newfs_apfs -v backendAprobe "$DEV" || exit 1

# APFS creates a SYNTHESIZED container disk with its own number — it is NOT
# ${DEV}s1. Find the volume by name instead of guessing the device.
sleep 2
VOL=$(diskutil list 2>/dev/null | grep -B4 backendAprobe | grep -o 'disk[0-9]*s[0-9]*' | tail -1)
[ -z "$VOL" ] && { echo NO-VOLDEV; exit 1; }
echo "=== APFS volume: /dev/$VOL"

echo "=== mount APFS privately at $APFSMNT"
run 60 APFSMOUNT mount_apfs "/dev/$VOL" "$APFSMNT" || exit 1
/sbin/mount | grep -F "$APFSMNT" | sed 's/^/    /'

# The dext wedge is positional: first access completes, second blocks. Same
# probe shape as vm-scratch-apfs.sh so the results are directly comparable.
echo "=== first access: readdir"
run 30 READDIR ls -a "$APFSMNT"
echo "=== second access: getattr"
run 30 GETATTR stat "$APFSMNT"

echo "=== QUESTION 2: write 32 MiB, checksum, full teardown, reattach, re-verify"
dd if=/dev/urandom of="$APFSMNT/verify.bin" bs=1m count=32 >/dev/null 2>&1
BEFORE=$(shasum -a 256 "$APFSMNT/verify.bin" | cut -d' ' -f1)
echo "    before: $BEFORE"
run 60 SYNC sync
run 60 UNMOUNT umount "$APFSMNT"
run 60 DETACH hdiutil detach "$DEV"

echo "=== reattach from the SAME backing file"
DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount -noverify "$IMG" 2>&1 | awk 'NR==1{print $1}')
echo "    reattached: $DEV"
sleep 3
VOL=$(diskutil list 2>/dev/null | grep -B4 backendAprobe | grep -o 'disk[0-9]*s[0-9]*' | tail -1)
run 60 REMOUNT mount_apfs "/dev/$VOL" "$APFSMNT" || exit 1
AFTER=$(shasum -a 256 "$APFSMNT/verify.bin" | cut -d' ' -f1)
echo "    after:  $AFTER"

if [ "$BEFORE" = "$AFTER" ]; then
  echo "INTEGRITY-VERIFIED — writes reach the backing file through the FSKit extension"
  echo "VERDICT: Backend A's mechanism is sound."
else
  echo "INTEGRITY-MISMATCH — writes do not survive the round trip"
  exit 1
fi

echo "=== $(date '+%H:%M:%S') done"
