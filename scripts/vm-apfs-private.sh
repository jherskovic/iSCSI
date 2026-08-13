#!/bin/bash
# vm-apfs-private.sh — run ON the VM as root, STREAMED over ssh.
#
# Mount the volume OUTSIDE /Volumes, so nothing but this script touches it.
#
# Two jobs at once:
#
#  1. Diagnostic. Finder, Spotlight, fseventsd and diskarbitrationd all watch
#     /Volumes and reach for a new volume on their own. If a private mountpoint
#     never wedges, their access pattern is implicated rather than the mount
#     itself.
#
#  2. Capture harness. Those same daemons have been winning the race — in two
#     of three runs they wedged the box before a deliberate trigger could run,
#     so the wedging thread was never the one under trace. Out of /Volumes they
#     are not in the race at all, and the trigger fires the instant the mount
#     returns rather than after a settle.
#
# dtrace selects on execname (the trigger binary is copied to a unique name):
# copyinstr() predicates are useless here because page-ins stall as the box
# goes down and every copyinstr then fails with "invalid user access".
set -uo pipefail
cd ~/iSCSI || exit 1
mkdir -p /Users/herko/logs /Users/herko/mnt

TARGET=${TARGET:-iqn.me.herko.planet-express:iscsi-driver-testing}
PORTAL=${PORTAL:-192.168.0.101}
CTL=.build/release/iscsictl
LOG=/Users/herko/logs/private-iscsid.log
MNT=/Users/herko/mnt

our_disk() {
  ioreg -r -c IOSCSIPeripheralDeviceType00 -l 2>/dev/null \
    | grep -m1 -o '"BSD Name" = "disk[0-9]*"' | grep -o 'disk[0-9]*'
}

echo "=== wipe"
$CTL wipe "$PORTAL" --target "$TARGET" >/Users/herko/logs/private-wipe.log 2>&1 \
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

newfs_apfs -v iSCSITest "/dev/$DISK" 2>&1 | sed 's/^/    /'
[ "${PIPESTATUS[0]:-0}" -eq 0 ] || { echo NEWFS-FAILED; exit 1; }
echo "=== newfs ok"
sleep 3

# Resolve the synthesized volume's device node while the box is still healthy.
VOLDEV=$(diskutil info iSCSITest 2>/dev/null | awk '/Device Node:/{print $3}')
[ -z "$VOLDEV" ] && { echo NO-VOLDEV; diskutil list | sed 's/^/    /'; exit 1; }
echo "=== volume device: $VOLDEV"

# Everything the trigger needs must exist BEFORE the mount: once the box starts
# wedging, even cp and fork become unreliable.
# READDIR is the operation that wedges — getattr on the same mount completes.
# (Under /Volumes a getattr appeared to block too, but only because a daemon
# had already done a readdir and wedged the volume ahead of it.) So the traced
# binary is ls, not stat.
cp /bin/ls /tmp/wedgeprobe
chmod +x /tmp/wedgeprobe
cp /usr/bin/stat /tmp/statprobe
chmod +x /tmp/statprobe

cat > /tmp/private.d << 'EOF'
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=10ms
#pragma D option bufsize=16m

syscall:::entry
/execname == "wedgeprobe"/
{ self->insys = 1; self->n = 0; printf("SYS %s\n", probefunc); }

fbt:com.apple.filesystems.apfs::entry
/self->insys/
{ self->n++; printf("    apfs[%d] %s\n", self->n, probefunc); }

sched:::sleep
/self->insys/
{ printf("    ---- SLEEP after %d apfs calls\n", self->n); }

fbt::lck_mtx_sleep:entry
/self->insys/
{ printf("    ---- LCK_MTX_SLEEP (waiting on a mutex) after %d apfs calls\n", self->n); }

syscall:::return
/execname == "wedgeprobe"/
{ self->insys = 0; printf("SYS %s ret\n", probefunc); }
EOF

# Run dtrace under `script` to give it a PTY. Its stdout is otherwise a pipe
# (ssh), so libc block-buffers it and a low-volume trace never flushes before
# the box wedges — the run then ends with the verdict and no trace at all,
# which is exactly how one earlier attempt lost its capture.
# `tail -f /dev/null |` keeps script's stdin open forever. Without it script
# inherits this session's stdin (the ssh heredoc feeding sudo the password),
# reads EOF immediately and exits, killing dtrace before it traces anything —
# the giveaway is a lone "^D" in the output right after this line.
echo "=== starting dtrace"
tail -f /dev/null | script -q /dev/null /usr/sbin/dtrace -s /tmp/private.d &
DT=$!
sleep 12

echo "=== mounting privately at $MNT (NOT /Volumes)"
mount_apfs "$VOLDEV" "$MNT" || { echo MOUNT-FAILED; exit 1; }
echo "=== mounted"

# No settle: fire immediately, before anything else can find the volume.
# getattr first as a control — it is expected to complete, and proves the
# volume is reachable before the readdir goes near it.
echo "=== control: getattr on the private mount root"
/tmp/statprobe "$MNT" >/dev/null 2>&1 &
TRIG=$!
sleep 15
kill -0 $TRIG 2>/dev/null && echo "GETATTR-BLOCKED" || echo "GETATTR-COMPLETED"

echo "=== trigger: readdir on the private mount root (traced)"
/tmp/wedgeprobe -a "$MNT" >/dev/null 2>&1 &
TRIG2=$!
sleep 25
kill -0 $TRIG2 2>/dev/null && echo "READDIR-BLOCKED" || echo "READDIR-COMPLETED"

sleep 5
kill $DT 2>/dev/null
umount "$MNT" >/dev/null 2>&1 && echo "=== UNMOUNT-OK"
echo "=== DONE"
