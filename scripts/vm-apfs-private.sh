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

# Capture the dext's pids NOW, while the process table is still readable.
# `ps`/`pgrep` both enumerate the proc list, which is one of the things that
# piles up behind the wedge — looking the pid up afterwards just hangs. Pids are
# stable for the life of the boot, so grabbing them here is enough.
# One pid per line in a file, iterated with `while read`. Do NOT collect them
# into a variable and `for p in $VAR` — this script is launched with `sudo zsh`,
# and zsh does not word-split unquoted variables the way bash does, so the loop
# runs once with p="243 263" and sample is handed a nonsense argument.
DEXT_PIDFILE=/Users/herko/logs/dext-pids
ps ax -o pid,comm | grep 'me.herko.iSCSIInitiator.dext' | grep -v grep \
  | awk '{print $1}' > "$DEXT_PIDFILE"
echo "=== dext pids: $(tr '\n' ' ' < "$DEXT_PIDFILE")"

# Started now so it exists and is quiescent before anything wedges; sampled
# later as the control described above.
sleep 600 &
CONTROL_PID=$!
echo "=== control pid: $CONTROL_PID"

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

/*
 * Heartbeat. Without it, an empty trace is ambiguous: dtrace may have died, or
 * the predicate may simply never have matched. Two earlier runs produced no
 * output at all and there was no way to tell those apart from the log.
 */
profile-5s
{ printf("DTRACE-ALIVE\n"); }

/*
 * Key off the OPERATION, not the process.
 *
 * Filtering by execname kept yielding nothing even though dtrace was provably
 * alive and the same predicate worked on a healthy box — so stop depending on
 * which binary runs, and arm on APFS's readdir entry point itself. Whoever
 * calls it gets traced. The boot volume adds some noise; that is a fair price
 * for a probe that cannot silently miss.
 */
/*
 * Which vnop never comes back?
 *
 * Arming on apfs_vnop_readdir specifically was still too narrow: the blocking
 * `ls` was BLOCKED while enters and returns stayed perfectly balanced (716 of
 * each), so it never reached APFS's readdir at all. Trace every apfs_vnop_*
 * entry and return instead and let the post-processing find the unbalanced
 * pair — that names the exact vnop that hangs without having to guess it in
 * advance. strstr() on probefunc is safe: it is a kernel string, not user
 * memory, so it cannot fail the way copyinstr() does as the box goes down.
 */
fbt:com.apple.filesystems.apfs::entry
/strstr(probefunc, "apfs_vnop_") != NULL/
{ printf("VNOP-E %d %s %s\n", pid, execname, probefunc); }

fbt:com.apple.filesystems.apfs::return
/strstr(probefunc, "apfs_vnop_") != NULL/
{ printf("VNOP-R %d %s %s\n", pid, execname, probefunc); }
EOF

# Run dtrace under `script` to give it a PTY. Its stdout is otherwise a pipe
# (ssh), so libc block-buffers it and a low-volume trace never flushes before
# the box wedges — the run then ends with the verdict and no trace at all,
# which is exactly how one earlier attempt lost its capture.
# Plain dtrace, deliberately. An earlier version ran it under `script` to get a
# PTY on the theory that its output was block-buffered into the ssh pipe; that
# was wrong. Verified on a healthy box: plain dtrace streams line by line over
# ssh, and `execname` matching on the copied binary works. `script` only added
# a way to fail — it inherits the sudo heredoc's stdin, hits EOF and exits
# instantly, taking dtrace with it (a lone "^D" in the output is the tell).
echo "=== starting dtrace"
/usr/sbin/dtrace -s /tmp/private.d &
DT=$!
sleep 12

echo "=== mounting privately at $MNT (NOT /Volumes)"
mount_apfs "$VOLDEV" "$MNT" || { echo MOUNT-FAILED; exit 1; }
echo "=== mounted"

# ORDER=readdir-first (default) or getattr-first.
#
# Everything so far ran getattr then readdir, and concluded "readdir is what
# wedges". But that ordering cannot distinguish it from "the FIRST access
# succeeds and wedges the volume as a side effect, so whatever runs SECOND
# blocks". Those are very different bugs. Running readdir first settles it:
# if readdir alone blocks, readdir really is the trigger; if it now succeeds
# and the following getattr blocks instead, the trigger is simply "the second
# access" and the operation is irrelevant.
ORDER=${ORDER:-readdir-first}
echo "=== order: $ORDER"

# Each trigger prints STARTED from userspace before exec'ing the real binary.
# Without it, "blocked" is ambiguous between "the process ran and blocked in
# the syscall on our volume" and "the PROCESS blocked in fork/exec and never
# reached userspace at all" — which would make this about the second *process*
# rather than the second *access*, a different bug. Several traced runs showed
# no syscalls whatsoever from the blocking process, so this is a live question.
do_readdir() {
  echo "=== readdir on the private mount root (traced)"
  sh -c 'echo "    STARTED readdir"; exec /tmp/wedgeprobe -a "$1" >/dev/null 2>&1' _ "$MNT" &
  local p=$!
  sleep 25
  kill -0 $p 2>/dev/null && echo "READDIR-BLOCKED" || echo "READDIR-COMPLETED"
}

do_getattr() {
  echo "=== getattr on the private mount root"
  sh -c 'echo "    STARTED getattr"; exec /tmp/statprobe "$1" >/dev/null 2>&1' _ "$MNT" &
  local p=$!
  sleep 15
  kill -0 $p 2>/dev/null && echo "GETATTR-BLOCKED" || echo "GETATTR-COMPLETED"
}

# THE decisive probe. "The dext's queue is empty" only rules out tasks stuck
# INSIDE the dext; it cannot rule out one stuck ABOVE us, in IOSCSIParallelFamily
# or IOBlockStorageDriver, that was never dispatched to UserProcessParallelTask.
# A leaked completion or reused tag at the end of the checkpoint burst would
# jam that queue, and the dext would see exactly the silence we observed.
#
# Raw I/O to the same device goes through the whole block/SCSI stack while
# bypassing APFS entirely:
#   completes -> the device stack is alive, APFS is stuck on something of its
#                own, and "not our I/O" becomes kernel-visible rather than
#                inferred from our own logs
#   hangs     -> the family queue is jammed and this is plausibly OUR bug
raw_io_probe() {
  echo "=== RAW I/O PROBE (bypasses APFS; is the device stack alive?)"
  echo "--- raw read of /dev/r$DISK"
  dd if="/dev/r$DISK" of=/dev/null bs=4096 count=1 >/dev/null 2>&1 &
  local p=$!
  sleep 20
  kill -0 $p 2>/dev/null && echo "RAWREAD-BLOCKED" || echo "RAWREAD-COMPLETED"

  # Read-only: no --write, so it issues flush ioctls without scribbling on the
  # device. Flushes are what the checkpoint ends in, so this asks specifically
  # whether the barrier path still works while APFS is wedged.
  if [ -x ./dkflush ]; then
    echo "--- dkflush (flush ioctls only, read-only)"
    ./dkflush "/dev/r$DISK" >/Users/herko/logs/private-dkflush.out 2>&1 &
    local q=$!
    sleep 20
    if kill -0 $q 2>/dev/null; then echo "DKFLUSH-BLOCKED"; else
      echo "DKFLUSH-COMPLETED"; sed 's/^/    /' /Users/herko/logs/private-dkflush.out | tail -8
    fi
  else
    echo "--- dkflush not built; skipping"
  fi
}

if [ "$ORDER" = "readdir-first" ]; then
  do_readdir
  do_getattr
else
  do_getattr
  do_readdir
fi

raw_io_probe

# Where is the dext itself stuck?
#
# `sample` targets one process by pid and does NOT enumerate mounts, so unlike
# spindump it survives here. Symbolicated user-space stacks say directly
# whether a dext thread is parked inside our own code — the test for the theory
# that UserProcessParallelTask blocks the default queue, which is also what
# services NewUserClient and ExternalMethod and would explain why
# `iscsictl dext-stats` hangs while the device is wedged.
# Is IOKit itself still alive while wedged?
#
# `iscsictl dext-stats` hangs during a wedge, which looked like proof that the
# dext cannot service a request. It is not, until this runs: every other
# inspection tool also hangs when wedged, and `sample` was shown to hang on an
# unrelated process just as readily as on the dext. So try a lookup + user
# client open against a service with nothing to do with storage.
#
#   returns  -> IOKit is live, and the dext's hang is specific to us
#   hangs    -> IOKit is globally stuck, and the dext's hang means nothing
#
# A refused open still counts as "returns" — liveness is the question, not
# access.
if [ -x ./ukopen ]; then
  echo "=== IOKit liveness while wedged: UNRELATED service (control)"
  ./ukopen IOHIDSystem 2>&1 | sed 's/^/    /'
  echo "IOKIT-CONTROL-RETURNED"
  echo "=== IOKit liveness while wedged: OUR dext"
  ./ukopen iSCSIDext 2>&1 | sed 's/^/    /'
  echo "IOKIT-DEXT-RETURNED"
else
  echo "=== ukopen not built; skipping IOKit liveness probe"
fi

# Control: an ordinary process that touches nothing storage-related. If sample
# works on IT but hangs on the dext, the dext is genuinely stuck. If sample
# hangs on both, the wedge has simply defeated another inspection tool and says
# nothing about the dext — the same ambiguity that made the silent log
# unreadable. Do not interpret a hung dext sample without this.
echo "=== sampling CONTROL process (plain sleep, pid $CONTROL_PID)"
sample "$CONTROL_PID" 2 -file /Users/herko/logs/control-wedged.txt >/dev/null 2>&1
if sed -n '/Call graph/,/Total number/p' /Users/herko/logs/control-wedged.txt 2>/dev/null | head -8; then
  echo "CONTROL-SAMPLE-OK"
else
  echo "CONTROL-SAMPLE-FAILED"
fi

echo "=== sampling the dext process(es) while wedged"
while read -r p; do
  [ -n "$p" ] || continue
  echo "--- dext pid $p"
  sample "$p" 3 -file "/Users/herko/logs/dext-wedged-$p.txt" >/dev/null 2>&1
  sed -n '/Call graph/,/Total number/p' "/Users/herko/logs/dext-wedged-$p.txt" 2>/dev/null | head -40
done < "$DEXT_PIDFILE"

sleep 5
kill $DT 2>/dev/null
umount "$MNT" >/dev/null 2>&1 && echo "=== UNMOUNT-OK"
echo "=== DONE"
