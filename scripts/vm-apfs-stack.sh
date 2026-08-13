#!/bin/bash
# vm-apfs-stack.sh — run ON the VM as root, STREAMED over ssh.
#
# Name the thread and the lock behind the post-mount hang.
#
# Earlier attempts to capture this failed because there was nothing to arm on:
# `spindump` samples everything, and on this box it enumerates mounts, blocks
# on the very hang it is trying to record, and takes the machine down with it.
# What changed is that the trigger is now known exactly — statfs on the mounted
# volume, the first VFS operation to touch it — so dtrace can be armed on the
# statfs syscall and catch the kernel stack at the instant the thread blocks.
#
# SIP must be off (it is, in this VM). Output is printed as it happens, not
# collected at exit, because the box may not survive to the exit.
set -uo pipefail
cd ~/iSCSI || exit 1
mkdir -p /Users/herko/logs

TARGET=${TARGET:-iqn.me.herko.planet-express:iscsi-driver-testing}
PORTAL=${PORTAL:-192.168.0.101}
CTL=.build/release/iscsictl
LOG=/Users/herko/logs/stack-iscsid.log

our_disk() {
  ioreg -r -c IOSCSIPeripheralDeviceType00 -l 2>/dev/null \
    | grep -m1 -o '"BSD Name" = "disk[0-9]*"' | grep -o 'disk[0-9]*'
}

echo "=== wipe"
$CTL wipe "$PORTAL" --target "$TARGET" >/Users/herko/logs/stack-wipe.log 2>&1 \
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

newfs_apfs -v iSCSITest "/dev/$DISK" >/dev/null 2>&1 || { echo NEWFS-FAILED; exit 1; }
echo "=== newfs ok"
sleep 3

# Arm BEFORE mounting, and catch whichever process gets there first.
#
# An earlier version armed after the mount and triggered statfs itself; the box
# wedged ~5s after `diskutil mount`, before dtrace was even running. The volume
# does not sit untouched after mounting — diskarbitrationd and fseventsd reach
# for it on their own — so the thread that wedges is often not ours. Selecting
# on the PATH rather than on execname catches whoever it turns out to be.
#
# thread_block_reason is the universal parking spot, so whatever lock or wait
# channel APFS ends up on, the stack that leads there is printed here.
cat > /tmp/catch.d << 'EOF'
#pragma D option quiet
#pragma D option destructive
#pragma D option switchrate=10ms
#pragma D option bufpolicy=ring

/*
 * getattr on the volume ROOT is the operation that wedges — NOT statfs.
 * `stat -f %d` looked like statfs and is not: -f is stat(1)'s output FORMAT
 * flag, so that probe was calling stat(). Tracing proved the difference:
 * 502 real statfs64 calls on this volume (Finder's, mostly) all returned
 * normally while the stat() sat blocked forever.
 *
 * Name each syscall explicitly rather than globbing: a *stat* glob catches
 * fstat/fstatfs, whose arg0 is a file descriptor and not a path pointer, and
 * copyinstr() then faults on every call the machine makes, burying the trace
 * in "invalid address in predicate" errors.
 */
syscall::stat64:entry,
syscall::lstat64:entry,
syscall::getattrlist:entry,
syscall::statfs64:entry
/arg0 != 0 && strstr(copyinstr(arg0), "iSCSITest") != NULL/
{
        self->armed = 1;
        printf("ENTER %s pid=%d exec=%s path=%s\n",
               probefunc, pid, execname, copyinstr(arg0));
}

/*
 * Two catchers, because which one fires is itself the answer.
 * `thread_block*` is not instrumentable on this kernel, so:
 *   sched:::sleep        — the thread parked for any reason
 *   fbt::lck_mtx_sleep   — it parked specifically waiting on a MUTEX, which
 *                          means some other thread holds it and is itself stuck
 * Neither exits: arming is per-thread (self->), so only the statfs thread
 * fires, and a legitimate brief sleep early on must not stop the trace before
 * the one that never wakes. The LAST stack printed is the interesting one.
 */
sched:::sleep
/self->armed/
{
        printf("---- SLEEP pid=%d exec=%s, kernel stack:\n", pid, execname);
        stack(48);
        printf("---- end stack\n");
}

fbt::lck_mtx_sleep:entry
/self->armed/
{
        printf("---- LCK_MTX_SLEEP (waiting on a mutex) pid=%d exec=%s:\n",
               pid, execname);
        stack(48);
        printf("---- end stack\n");
}

/*
 * Disarm on EVERY armed syscall's return, not just statfs64's. Arming is a
 * per-thread flag, so a thread that entered via stat64/getattrlist and was
 * never disarmed stays armed for the rest of its life and reports every later
 * sleep it makes for any unrelated reason — which silently turns the
 * per-process tallies into "threads that once touched this path", not
 * "threads blocked on it". logd and cloudd topping the list is that bug.
 */
syscall::stat64:return,
syscall::lstat64:return,
syscall::getattrlist:return,
syscall::statfs64:return
/self->armed/
{ self->armed = 0; printf("%s RETURNED without wedging pid=%d\n", probefunc, pid); }
EOF

echo "=== starting dtrace (before mount)"
/usr/sbin/dtrace -s /tmp/catch.d &
DT=$!
sleep 10

echo "=== mounting"
diskutil mount iSCSITest || { echo MOUNT-FAILED; exit 1; }
echo "=== mounted"

# Do not touch the volume: let whatever normally reaches for it do so. Only if
# nothing has wedged by then do we poke it ourselves.
sleep 30
echo "=== nothing wedged on its own; triggering statfs deliberately"
stat -f %d /Volumes/iSCSITest &
TRIG=$!
sleep 25
kill -0 $TRIG 2>/dev/null && echo "TRIGGER-BLOCKED" || echo "TRIGGER-COMPLETED"
sleep 10
kill $DT 2>/dev/null
echo "=== DONE"
