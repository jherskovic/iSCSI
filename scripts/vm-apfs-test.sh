#!/bin/bash
# vm-apfs-test.sh — run ON the VM as root. Does APFS actually work now that
# flushes reach the device?
#
# Routed around the known-separate `diskutil eraseDisk` re-probe race by
# building the container on the whole device, so the only question left is
# APFS itself. Every step is time-boxed, so a wedge shows up as a TIMEOUT line
# instead of hanging forever.
#
# RUN IT STREAMED, NOT DETACHED:
#     ssh VM "sudo -S zsh iSCSI/scripts/vm-apfs-test.sh" <<< PASS | tee local.log
# When this test fails it can take the whole box down, and anything buffered in
# a VM-side file is then lost to the power-cycle — /tmp is wiped on boot and a
# page-cached tail never reaches disk. Lines that already crossed the ssh
# connection survive, and that tail is the whole diagnosis.
set -uo pipefail
cd ~/iSCSI || exit 1
mkdir -p /Users/herko/logs

TARGET=${TARGET:-iqn.me.herko.planet-express:iscsi-driver-testing}
PORTAL=${PORTAL:-192.168.0.101}
CTL=.build/release/iscsictl
LOG=/Users/herko/logs/apfs3-iscsid.log

step() {  # step <seconds> <name> <cmd...>
  local t=$1 name=$2; shift 2
  echo "--- $name"
  ( "$@" ) >/Users/herko/logs/apfs3-step.out 2>&1 &
  local p=$! i=0
  while kill -0 $p 2>/dev/null; do
    sleep 1; i=$((i+1))
    [ $i -ge "$t" ] && { echo "TIMEOUT after ${t}s: $name"; kill -9 $p 2>/dev/null; return 124; }
  done
  wait $p; local rc=$?
  sed 's/^/    /' /Users/herko/logs/apfs3-step.out | tail -10
  echo "    [$name rc=$rc after ${i}s]"
  return $rc
}

our_disk() {
  ioreg -r -c IOSCSIPeripheralDeviceType00 -l 2>/dev/null \
    | grep -m1 -o '"BSD Name" = "disk[0-9]*"' | grep -o 'disk[0-9]*'
}

echo "=== wipe"
$CTL wipe "$PORTAL" --target "$TARGET" >/Users/herko/logs/apfs3-wipe.log 2>&1 || { echo WIPE-FAILED; exit 1; }

echo "=== attach"
# Truncate: the daemon log is APPENDED to, and the publish-wait below greps it.
# A stale "published LUN" from the previous run makes that wait a silent no-op.
: > "$LOG"
# Wrapped so the daemon's exit status lands in the log. It has quietly gone
# away mid-test more than once, and "the arena is gone" (sense 04/08/00 on
# every read) is all the dext can tell us about why.
( $CTL dext-attach --portal "$PORTAL" --target "$TARGET" >>"$LOG" 2>&1
  echo "ATTACH-EXIT rc=$?" >>"$LOG" ) &
ATTACH=$!
trap 'kill $ATTACH 2>/dev/null; pkill -f dext-attach 2>/dev/null' EXIT

# Wait for the DAEMON, not just for the disk node. Under
# ISCSI_DEXT_FIXED_DISK_PROBE the medium is present from controller start, so a
# /dev/disk exists at boot with nothing behind it — polling for the node alone
# hands us a disk whose every read fails 04/08/00 until login finishes.
for _ in $(seq 1 45); do
  grep -q "published LUN" "$LOG" 2>/dev/null && break
  sleep 1
done
grep -q "published LUN" "$LOG" 2>/dev/null || { echo NO-PUBLISH; tail -5 "$LOG"; exit 1; }

DISK=""
for _ in $(seq 1 45); do
  sleep 1
  d=$(our_disk)
  if [ -n "$d" ] && diskutil info "$d" >/dev/null 2>&1; then DISK="$d"; break; fi
done
[ -z "$DISK" ] && { echo NO-DISK; tail -5 "$LOG"; exit 1; }
echo "=== disk: $DISK"


# No partition map at all: an APFS container on the whole device removes the
# separate diskutil re-probe race from this experiment, leaving only the
# question we care about — does APFS itself work now that barriers land?
step 300 "newfs_apfs on the WHOLE device" newfs_apfs -v iSCSITest "/dev/$DISK" || exit 1
sleep 3




sleep 5
step 60 "diskutil list" diskutil list

echo "=== THE MOMENT OF TRUTH: mounting APFS"
step 120 "mount APFS by name" diskutil mount iSCSITest

MNT="/Volumes/iSCSITest"
echo "=== mounted at $MNT"
# Let the mount settle before touching it. Listing sub-second after `diskutil
# mount` wedged the box twice; the same listing ~10s later returns instantly,
# so something (Spotlight/fseventsd claiming the new volume?) is racing us.
sleep 15
step 120 "listing" ls -la "$MNT"

step 300 "write 200 MiB" dd if=/dev/urandom of="$MNT/blob" bs=1m count=200
step 120 "sha before" shasum -a 256 "$MNT/blob"
SHA1=$(awk '{print $1}' /Users/herko/logs/apfs3-step.out)

step 120 "300 small files + sync" sh -c "mkdir -p '$MNT/many' && for i in \$(seq 1 300); do echo hello-\$i > '$MNT/many/f'\$i; done; sync"

step 120 "unmount" diskutil unmount "$MNT"
step 120 "remount" diskutil mount iSCSITest
step 120 "sha after remount" shasum -a 256 "$MNT/blob"
SHA2=$(awk '{print $1}' /Users/herko/logs/apfs3-step.out)
echo "=== sha before=$SHA1"
echo "=== sha after =$SHA2"
if [ -n "$SHA1" ] && [ "$SHA1" = "$SHA2" ]; then echo "=== DATA-OK"; else echo "=== DATA-MISMATCH"; fi

step 60 "small files intact" sh -c "ls '$MNT/many' | wc -l; cat '$MNT/many/f42'"
step 120 "unmount for fsck" diskutil unmount "$MNT"
step 300 "fsck_apfs -n" fsck_apfs -n "/dev/r${DISK}"

echo "=== flushes seen by daemon: $(grep -c FLUSH "$LOG")"
echo "=== DONE"
