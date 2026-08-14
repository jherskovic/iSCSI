#!/bin/bash
# vm-fskit-proto.sh — run ON the VM as root, STREAMED over ssh.
#
# BACKEND A DISCRIMINATING TEST. Answers, in one run, the two questions that
# decide whether Backend A works at all (docs/backend-a-fskit-notes.md):
#
#   1. Will DiskImages attach a file that lives on an FSKit (non-local) volume?
#   2. Does flush/sync propagate from the attached disk image down through the
#      extension's FSVolume.ReadWriteOperations path?
#
# Neither involves iSCSI, so the extension serves ONE file from a local sparse
# backing store. If both answers are yes, Backend A is viable and the only
# remaining work is swapping the BackingStore for an XPC client to iscsid.
#
# PREREQUISITE — a one-time manual step. The module must be enabled in
#   System Settings > General > Login Items & Extensions > File System Extensions
# `mount` gates on FSModuleIdentity.isEnabled and pluginkit registration is NOT
# sufficient; without the toggle every run stops at MODULE-DISABLED below.
#
# Deliberately mounts outside /Volumes, like vm-apfs-private.sh, so no system
# daemon touches the volume and the sequence stays deterministic. Every step is
# bounded: macOS has no timeout(1), and the whole point of this rig is that a
# hang must not take the script with it.
set -uo pipefail

FSMNT=/Users/herko/fsmnt
DISKMNT=/Users/herko/mnt3
URL=iscsi://proto/lun0
LOG=/Users/herko/logs/fskit-proto.out

mkdir -p "$FSMNT" "$DISKMNT" /Users/herko/logs

# run <seconds> <label> <command...> — bounded; prints LABEL-BLOCKED on timeout
# instead of hanging the run. Everything here can plausibly wedge.
run() {
  local secs=$1 label=$2; shift 2
  "$@" >/tmp/step.out 2>&1 &
  local pid=$!
  local i=0
  while [ $i -lt "$secs" ]; do
    kill -0 $pid 2>/dev/null || break
    sleep 1; i=$((i+1))
  done
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid 2>/dev/null
    echo "${label}-BLOCKED"
    return 1
  fi
  wait $pid; local rc=$?
  sed 's/^/    /' /tmp/step.out
  [ $rc -eq 0 ] && echo "${label}-OK" || echo "${label}-FAILED(rc=$rc)"
  return $rc
}

echo "=== $(date '+%H:%M:%S') Backend A prototype run"

# Fresh state: an old backing file would mask a broken create path.
umount -f "$DISKMNT" 2>/dev/null
umount -f "$FSMNT" 2>/dev/null
rm -f /Users/Shared/iscsi-proto-*.img

echo "=== module registered?"
pluginkit -m -v -p com.apple.fskit.fsmodule 2>/dev/null | grep -i iscsi | sed 's/^/    /' \
  || echo "    NOT-REGISTERED (install '/Applications/iSCSI Initiator.app')"

echo "=== mount the FSKit volume"
if ! run 60 MOUNT mount -F -t iSCSI "$URL" "$FSMNT"; then
  grep -q 'is disabled' /tmp/step.out 2>/dev/null && {
    echo "MODULE-DISABLED — enable it in System Settings > General >"
    echo "  Login Items & Extensions > File System Extensions, then re-run."
    exit 1
  }
  exit 1
fi

echo "=== volume contents (expect lun0.img, 512 MiB)"
run 30 LIST ls -l "$FSMNT"

IMG="$FSMNT/lun0.img"
echo "=== question 1: attach the image with DiskImages"
if run 90 ATTACH hdiutil attach -imagekey diskimage-class=CRawDiskImage \
      -nomount -noverify "$IMG"; then
  DEV=$(grep -o '/dev/disk[0-9]*' /tmp/step.out | head -1)
else
  echo "VERDICT: DiskImages will not attach a file on an FSKit volume"
  exit 1
fi
[ -z "${DEV:-}" ] && { echo "NO-DEVICE"; exit 1; }
echo "=== attached as $DEV"

echo "=== newfs_apfs on $DEV"
run 120 NEWFS newfs_apfs -v backendA "$DEV" || exit 1

VOLDEV=$(diskutil list "$DEV" 2>/dev/null | grep -o "${DEV#/dev/}s[0-9]*" | tail -1)
[ -z "$VOLDEV" ] && { echo "NO-VOLDEV"; exit 1; }
echo "=== volume device: /dev/$VOLDEV"

echo "=== mounting privately at $DISKMNT"
run 60 APFSMOUNT mount_apfs "/dev/$VOLDEV" "$DISKMNT" || exit 1

# The dext wedge is positional — the FIRST access completes and the SECOND
# blocks — so both are probed, in that order, exactly as in vm-scratch-apfs.sh.
echo "=== first access: readdir"
run 30 READDIR ls -a "$DISKMNT"
echo "=== second access: getattr"
run 30 GETATTR stat "$DISKMNT"

echo "=== write + flush (question 2: does the flush reach the extension?)"
run 60 WRITE dd if=/dev/zero of="$DISKMNT/probe.bin" bs=1m count=8
run 60 SYNC sync

echo "=== unmount"
run 60 UNMOUNT umount "$DISKMNT"
run 60 DETACH hdiutil detach "$DEV"

echo "=== extension log — resource kind received, and SYNCHRONIZE calls"
/usr/bin/log show --last 10m \
  --predicate 'subsystem == "me.herko.iSCSIInitiator.fsext"' 2>/dev/null \
  | grep -E 'resource:|SYNCHRONIZE|BackingStore|activate|mount' | tail -30 | sed 's/^/    /'

echo "=== $(date '+%H:%M:%S') done"
