#!/bin/bash
# vm-apfs-mount-only.sh — run ON the VM as root, STREAMED over ssh (see
# vm-apfs-test.sh's header for why streamed and not detached).
#
# One question only: does the box die because something TOUCHES the mounted
# APFS volume, or does mounting alone start something fatal?
#
# Every hanging run so far has listed the volume moments after mounting it, so
# "access triggers the hang" was assumed, never tested. Here the volume is
# mounted and then deliberately left alone while a heartbeat that never goes
# near /Volumes proves the box is still alive. If the heartbeat dies untouched,
# the trigger is the mount and `ls` was only the thing standing closest to it.
set -uo pipefail
cd ~/iSCSI || exit 1
mkdir -p /Users/herko/logs

TARGET=${TARGET:-iqn.me.herko.planet-express:iscsi-driver-testing}
PORTAL=${PORTAL:-192.168.0.101}
CTL=.build/release/iscsictl
LOG=/Users/herko/logs/mountonly-iscsid.log
# 90s is enough: a mounted-but-untouched volume has already been observed
# healthy for 153s, so the quiet window is confirmation, not the experiment.
QUIET=${QUIET:-90}      # seconds to leave the volume strictly alone

our_disk() {
  ioreg -r -c IOSCSIPeripheralDeviceType00 -l 2>/dev/null \
    | grep -m1 -o '"BSD Name" = "disk[0-9]*"' | grep -o 'disk[0-9]*'
}

echo "=== wipe"
$CTL wipe "$PORTAL" --target "$TARGET" >/Users/herko/logs/mountonly-wipe.log 2>&1 \
  || { echo WIPE-FAILED; exit 1; }

echo "=== attach"
: > "$LOG"
( $CTL dext-attach --portal "$PORTAL" --target "$TARGET" >>"$LOG" 2>&1
  echo "ATTACH-EXIT rc=$?" >>"$LOG" ) &
trap 'pkill -f dext-attach 2>/dev/null' EXIT

for _ in $(seq 1 45); do grep -q "published LUN" "$LOG" 2>/dev/null && break; sleep 1; done
grep -q "published LUN" "$LOG" 2>/dev/null || { echo NO-PUBLISH; tail -5 "$LOG"; exit 1; }

DISK=""
for _ in $(seq 1 45); do
  sleep 1
  d=$(our_disk)
  if [ -n "$d" ] && diskutil info "$d" >/dev/null 2>&1; then DISK="$d"; break; fi
done
[ -z "$DISK" ] && { echo NO-DISK; tail -5 "$LOG"; exit 1; }
echo "=== disk: $DISK"

newfs_apfs -v iSCSITest "/dev/$DISK" >/dev/null 2>&1 || { echo NEWFS-FAILED; exit 1; }
echo "=== newfs ok"
sleep 3

echo "=== mounting"
diskutil mount iSCSITest || { echo MOUNT-FAILED; exit 1; }
echo "=== mounted; NOT touching it for ${QUIET}s"

# Heartbeat that stays well clear of the volume: no /Volumes, no getfsstat, no
# stat of the mount point. `date` alone would not prove much, so fork a
# subshell each beat — fork is the thing that stopped working in the bad runs.
for i in $(seq 1 $((QUIET / 3))); do
  beat=$( (echo "$i") 2>/dev/null )
  echo "beat $beat t=$((i * 3))s $(date +%H:%M:%S)"
  sleep 3
done
echo "=== SURVIVED ${QUIET}s UNTOUCHED"

# Escalate from "does not touch the volume at all" to a full readdir, naming
# each probe BEFORE running it. Step timeouts are useless here — when this
# wedges, fork stops working and the watchdog can never fire — but the last
# marker that made it across the ssh link names the exact operation that did
# it. That only works if the caller is streaming (see the header).
probe() {
  echo "=== PROBE: $1"
  shift
  "$@" >/dev/null 2>&1
  echo "=== PROBE-OK rc=$?"
}

# NOTE: `stat -f FMT` is stat(1)'s output FORMAT flag, not statfs(2). Both
# lines below call stat(); tracing showed real statfs64 calls on this volume
# return normally while stat() blocks forever, so do not read the first one as
# a statfs result.
probe "mount table only (no VFS op on the volume)" sh -c "mount | grep iSCSITest"
probe "getattr the root vnode (stat)"              stat -f %d /Volumes/iSCSITest
probe "getattr the root vnode (stat, again)"       stat /Volumes/iSCSITest
probe "readdir the root"                           ls -a /Volumes/iSCSITest
probe "full listing with per-entry stat"           ls -la /Volumes/iSCSITest
echo "=== ALL-PROBES-SURVIVED"
echo "=== DONE"
