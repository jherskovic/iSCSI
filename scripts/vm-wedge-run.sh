#!/bin/bash
# vm-wedge-run.sh — run ON the VM as root, STREAMED over ssh, with
# scripts/dtrace/storage-inflight.d already tracing on a SECOND ssh connection.
#
# One wedge costs a power-cycle, so every control runs inside this one run, and
# the control set runs THREE times -- before the first access, after it, and
# late -- because the box degrades progressively and a control's meaning
# depends on when it was taken.  The ukopen-returns-in-0ms and
# dext-stats-hangs results in the docs may be the same wedge at two ages.
#
# The blocking probe is a RAW read of /dev/rdiskN via a binary copied to the
# unique name `wedgeprobe`, so the dtrace predicate can select on execname
# without copyinstr (copyinstr predicates fault once page-ins stall).  Raw I/O
# bypasses APFS entirely, so whatever it blocks in is the block/SCSI layer.
#
# Deliberately does NOT unmount or clean up: leave the wedge standing so the
# late controls and the dtrace ticks see it.  Recover with utmctl from the host.
#
# STAGES.  Run STAGE=setup first with NO tracer armed, then arm the tracer,
# then run STAGE=probe.  fbt on ~2400 storage probes slows the kernel enough
# that newfs_apfs trips the known nondeterministic re-probe EIO
# ("failed to write superblock to block 0: 5"), which costs a whole run.  The
# wedge is triggered by the first ACCESS, so the tracer only has to be up from
# phase 3 onward.
set -uo pipefail

STAGE=${STAGE:-all}
DISK=${DISK:-disk7}
FS=${FS:-apfs}
MNT=/Users/herko/mnt2
LOGS=/Users/herko/logs
mkdir -p "$MNT" "$LOGS"

say(){ echo "[$(date '+%H:%M:%S')] $*"; }

# probe <label> <timeout-seconds> <command...>
# Backgrounds the command and polls.  A blocked probe is LEFT RUNNING on
# purpose -- the traced one must still be parked when dtrace ticks.
probe(){
  local label=$1; shift
  local tmo=$1; shift
  local out="$LOGS/probe-$label.out"
  : > "$out"
  say "PROBE $label START: $*"
  ( "$@" > "$out" 2>&1; echo "RC=$?" >> "$out" ) &
  local p=$! i=0
  while [ "$i" -lt "$tmo" ]; do
    kill -0 "$p" 2>/dev/null || break
    sleep 1; i=$((i+1))
  done
  if kill -0 "$p" 2>/dev/null; then
    say "PROBE $label ===> BLOCKED (still running after ${tmo}s)"
  else
    say "PROBE $label ===> COMPLETED in ~${i}s"
    sed 's/^/        /' "$out" | tail -10
  fi
}

controls(){
  local tag=$1
  say "----- control set [$tag] -----"
  # Our dext: lookup + open + 16 MiB arena map + ExternalMethod(6) stats.
  probe "uk-dext-$tag" 25 /Users/herko/ukopen iSCSIDext
  # THE MISSING CONTROL.  An unrelated service, nothing to do with storage.
  # Returns promptly -> IOKit is live and the dext's hang is ours.
  # Hangs           -> IOKit is globally stuck and the dext's hang proves nothing.
  probe "uk-hid-$tag" 25 /Users/herko/ukopen IOHIDSystem
}

if [ "$STAGE" = "probe" ]; then
  say "=== STAGE probe: reusing the volume mounted by STAGE=setup"
  mount | grep -q " $MNT " || { say "NOT-MOUNTED -- run STAGE=setup first"; exit 1; }
else
say "=== phase 0: starting state"
diskutil list "$DISK" 2>&1 | sed 's/^/    /'
say "dext pids: $(pgrep -f 'me.herko.iSCSIInitiator.dext' | tr '\n' ' ')"

say "=== phase 1: newfs ($FS) on /dev/$DISK"
if [ "$FS" = "exfat" ]; then
  newfs_exfat -v scratchTest "/dev/$DISK" > "$LOGS/wedge-newfs.out" 2>&1
else
  newfs_apfs -v scratchTest "/dev/$DISK" > "$LOGS/wedge-newfs.out" 2>&1
fi
rc=$?
sed 's/^/    /' "$LOGS/wedge-newfs.out"
[ "$rc" -eq 0 ] || { say "NEWFS-FAILED rc=$rc"; exit 1; }
say "newfs ok"

# POLL, do not sleep a fixed interval.  The synthesized APFS container can take
# well over 3s to appear on this build; a fixed `sleep 3` reported NO-VOLDEV on
# a run whose volume showed up moments later, costing the whole run.
if [ "$FS" = "exfat" ]; then
  VOLDEV="/dev/$DISK"
else
  VOLDEV=""
  for _ in $(seq 1 30); do
    VOLDEV=$(diskutil info scratchTest 2>/dev/null | awk '/Device Node:/{print $3}')
    [ -n "$VOLDEV" ] && break
    sleep 1
  done
fi
[ -z "$VOLDEV" ] && { say NO-VOLDEV; diskutil list | sed 's/^/    /'; exit 1; }
say "volume device: $VOLDEV"

say "=== phase 2: private mount at $MNT (outside /Volumes: no daemon races it)"
if [ "$FS" = "exfat" ]; then
  mount -t exfat "$VOLDEV" "$MNT" || { say MOUNT-FAILED; exit 1; }
else
  mount_apfs "$VOLDEV" "$MNT" || { say MOUNT-FAILED; exit 1; }
fi

say "mounted"
if [ "$STAGE" = "setup" ]; then
  say "=== STAGE setup done.  Arm the tracer now, then run STAGE=probe."
  exit 0
fi
fi

say "=== phase 3: controls BEFORE the first access (mounted, still healthy)"
controls early

say "=== phase 4: FIRST ACCESS (readdir) -- expected to COMPLETE"
probe firstaccess 30 /bin/ls -a "$MNT"

say "=== phase 5: controls AFTER the first access"
controls mid

say "=== phase 6: SECOND ACCESS = RAW read of /dev/r$DISK, TRACED as 'wedgeprobe'"
say "     raw I/O bypasses APFS, so where this blocks is the block/SCSI layer"
probe rawread 30 /Users/herko/wedgeprobe if="/dev/r$DISK" of=/dev/null bs=4096 count=1

say "=== phase 7: the classic APFS second access, for continuity with the docs"
probe getattr 20 /usr/bin/stat "$MNT"

say "=== phase 8: raw flush ioctls (also bypass APFS)"
probe dkflush 20 /Users/herko/dkflush "/dev/r$DISK" --write

say "=== phase 9: controls LATE"
controls late

say "=== phase 10: holding 45s so dtrace ticks against the standing wedge"
sleep 45
say "=== DONE (wedge deliberately left standing; recover with utmctl)"
