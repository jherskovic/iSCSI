#!/bin/bash
# vm-apfs-trace.sh — run ON the VM as root, STREAMED over ssh.
#
# Name the APFS code path that wedges, without symbolication.
#
# vm-apfs-stack.sh captures the blocked thread's kernel stack, but dtrace
# cannot symbolicate `kernel.release.vmapple`, so those stacks are raw
# addresses. This sidesteps that entirely: `com.apple.filesystems.apfs` DOES
# carry fbt probes, so tracing its entries for the wedging thread prints
# function NAMES. The last name before the thread stops is the culprit — and if
# no apfs function is ever entered, the block is above APFS, which is just as
# useful an answer.
set -uo pipefail
cd ~/iSCSI || exit 1
mkdir -p /Users/herko/logs

TARGET=${TARGET:-iqn.me.herko.planet-express:iscsi-driver-testing}
PORTAL=${PORTAL:-192.168.0.101}
CTL=.build/release/iscsictl
LOG=/Users/herko/logs/trace-iscsid.log

our_disk() {
  ioreg -r -c IOSCSIPeripheralDeviceType00 -l 2>/dev/null \
    | grep -m1 -o '"BSD Name" = "disk[0-9]*"' | grep -o 'disk[0-9]*'
}

echo "=== wipe"
$CTL wipe "$PORTAL" --target "$TARGET" >/Users/herko/logs/trace-wipe.log 2>&1 \
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
[ -z "$DISK" ] && { echo NO-DISK; exit 1; }
echo "=== disk: $DISK"

newfs_apfs -v iSCSITest "/dev/$DISK" 2>&1 | sed 's/^/    /' \
  || { echo NEWFS-FAILED; diskutil list "$DISK" 2>&1 | sed 's/^/    /'; exit 1; }
# newfs_apfs is on the left of a pipe, so $? is sed's. Check the real status.
[ "${PIPESTATUS[0]:-0}" -eq 0 ] || {
  echo NEWFS-FAILED
  diskutil list "$DISK" 2>&1 | sed 's/^/    /'
  exit 1
}
echo "=== newfs ok"
sleep 3

# Trace only the thread that is doing a path lookup on OUR volume. The apfs
# kext has thousands of entry probes and the boot volume is busy, so the
# per-thread `self->armed` guard is what keeps this from drowning the box.
# Select on EXECNAME, not on the path. The trigger binary is copied to a unique
# name so it can be picked out of the machine's constant stat traffic, which
# removes copyinstr() from the predicates entirely — no fd-vs-path arg
# confusion, no faulting on every unrelated call.
#
# Tracing EVERY syscall the trigger makes is the point: an earlier version
# armed only on the path-taking stat syscalls and caught nothing at all, even
# though the trigger provably blocked. The last "SYS <name>" with no matching
# "ret" names precisely where it stops.
cat > /tmp/trace.d << 'EOF'
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=10ms
#pragma D option bufsize=16m

syscall:::entry
/execname == "wedgeprobe"/
{ self->insys = 1; printf("SYS %s\n", probefunc); }

syscall:::return
/execname == "wedgeprobe"/
{ self->insys = 0; printf("SYS %s ret\n", probefunc); }

fbt:com.apple.filesystems.apfs::entry
/self->insys/
{ self->n++; printf("  apfs[%d] %s\n", self->n, probefunc); }

sched:::sleep
/self->insys/
{ printf("  ---- SLEEP after %d apfs calls\n", self->n); }
EOF

echo "=== starting dtrace (before mount)"
/usr/sbin/dtrace -s /tmp/trace.d &
DT=$!
sleep 12

echo "=== mounting"
diskutil mount iSCSITest || { echo MOUNT-FAILED; exit 1; }
echo "=== mounted"
sleep 20

echo "=== triggering getattr on the volume root"
cp /usr/bin/stat /tmp/wedgeprobe
/tmp/wedgeprobe /Volumes/iSCSITest &
TRIG=$!
sleep 30
kill -0 $TRIG 2>/dev/null && echo "TRIGGER-BLOCKED" || echo "TRIGGER-COMPLETED"
sleep 8
kill $DT 2>/dev/null
echo "=== DONE"
