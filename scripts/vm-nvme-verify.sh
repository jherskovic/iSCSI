#!/bin/bash
# vm-nvme-verify.sh — run ON the SIP-off VM as the logged-in user, streamed
# over ssh. The app-level NVMe/TCP verification, all of it without the GUI:
#
#   A. the shipping attach path (mount -F with an nvme:// URL, hdiutil
#      CRawDiskImage, APFS) against the NAS scratch namespace: integrity after
#      a cache purge, fsync'd files, diskutil verifyVolume, clean detach;
#   B. the same path against `iscsi-target-sim --nvme`, then `crash` on the
#      control socket — twice. B1 under the default write-through policy must
#      lose nothing; B2 with flushIntervalSeconds 0 (never) must lose the
#      cached writes, or the positive arm proves nothing.
#
# Preconditions (see docs/test-playbook.md): the app installed and its FSKit
# module enabled, the daemon registered, passwordless sudo, and the records
# for both targets in targets.json — this script edits the sim record's
# flush policy in place and removes it at the end. First run on 2026-09-01:
# A passed; B1 lost 0 of 0 cached blocks and verified 32/32; B2 lost 9192
# blocks and the volume was gone.
#
# Every step is bounded (macOS has no timeout(1)); a marker names the step
# that hung. DESTRUCTIVE to the namespace it is pointed at.
set -uo pipefail
cd ~/iSCSI || exit 1
mkdir -p ~/logs
NAS=${NAS:-192.168.20.1:4420}
NAS_NQN=${NAS_NQN:-nqn.2011-06.com.truenas:uuid:75ca6aa3-69fd-44e5-8269-8722b52845d0:name-testing}
SIM_NQN=nqn.2026-08.me.herko.sim:disk0
TARGETS="/Library/Application Support/me.herko.iSCSIInitiator/targets.json"
CACHE=~/Library/Caches/me.herko.iSCSIInitiator

run() {  # run <secs> <label> <cmd...>: bounded, prints LABEL-OK / LABEL-FAILED / LABEL-BLOCKED
  local secs=$1 label=$2; shift 2
  "$@" >/tmp/step.out 2>&1 &
  local pid=$! i=0
  while [ $i -lt "$secs" ]; do kill -0 $pid 2>/dev/null || break; sleep 1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; echo "${label}-BLOCKED"; sed 's/^/    /' /tmp/step.out | tail -5; return 1; fi
  wait $pid; local rc=$?
  sed 's/^/    /' /tmp/step.out | tail -8
  [ $rc -eq 0 ] && echo "${label}-OK" || echo "${label}-FAILED(rc=$rc)"
  return $rc
}

tag() { printf '%s|%s|%s' "$1" "$2" "$3" | shasum -a 256 | cut -c1-16; }

attach() {  # attach <portal> <nqn> <nsid> -> sets DEV, HIDDEN
  HIDDEN="$CACHE/$(tag "$1" "$2" "$3")"
  mkdir -p "$HIDDEN"
  run 60 MOUNT-FSKIT mount -F -t iSCSI "nvme://$1/$2/$3" "$HIDDEN" || return 1
  local img="$HIDDEN/lun0.img"
  [ -f "$img" ] || { echo "NO-IMAGE"; return 1; }
  echo "    lun0.img: $(stat -f %z "$img") bytes"
  run 60 HDIUTIL hdiutil attach -imagekey diskimage-class=CRawDiskImage -noverify -nomount "$img" || return 1
  DEV=$(awk 'NR==1{print $1}' /tmp/step.out)
  echo "    device: $DEV"
}

detach() {  # detach <volume-name>
  run 60 UNMOUNT diskutil unmountDisk force "$DEV"
  run 60 HDIUTIL-DETACH hdiutil detach "$DEV" -force
  run 30 UMOUNT-FSKIT umount "$HIDDEN" || run 30 UMOUNT-FSKIT-F umount -f "$HIDDEN"
}

echo "=== $(date '+%H:%M:%S') log stream on"
/usr/bin/log stream --info --debug --predicate 'subsystem BEGINSWITH "me.herko.iSCSIInitiator"' > ~/logs/nvme-attach.log 2>&1 &
LOGPID=$!
sleep 2

echo "=== A. NAS: attach $NAS_NQN nsid 1 through FSKit"
attach "$NAS" "$NAS_NQN" 1 || { echo "A-ATTACH-FAILED"; kill $LOGPID; exit 1; }
run 120 ERASE-APFS diskutil eraseDisk APFS NVMeTest GPT "$DEV" || { echo "A-FORMAT-FAILED"; detach; kill $LOGPID; exit 1; }
sleep 2
VOL=/Volumes/NVMeTest
[ -d "$VOL" ] || { echo "A-NO-VOLUME"; detach; kill $LOGPID; exit 1; }
echo "    mounted: $(mount | grep NVMeTest | head -1)"
run 180 A-WRITE dd if=/dev/urandom of="$VOL/random.bin" bs=1m count=256
BEFORE=$(shasum -a 256 "$VOL/random.bin" | awk '{print $1}')
sync; sudo purge
AFTER=$(shasum -a 256 "$VOL/random.bin" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] && echo "A-INTEGRITY-OK ($BEFORE)" || echo "A-INTEGRITY-MISMATCH"
run 180 A-FSYNC-FILES python3 scripts/crash-consistency.py prepare --dir "$VOL/durable" --manifest ~/logs/nas-manifest.json --count 32 --size 1048576
run 120 A-VERIFY-FILES python3 scripts/crash-consistency.py verify --dir "$VOL/durable" --manifest ~/logs/nas-manifest.json
run 120 A-VERIFYVOLUME diskutil verifyVolume "$VOL"
echo "    daemon session line:"; grep -E "nsid 1: write cache" ~/logs/nvme-attach.log | sed 's/^[^:]*: //' | tail -1
detach
echo "=== A done"

echo "=== B. simulator: start --nvme on 4420"
nohup .build/debug/iscsi-target-sim --nvme --port 4420 --control-port 3262 --capacity-mib 512 --digest CRC32C > ~/logs/sim.log 2>&1 &
SIMPID=$!
sleep 2; cat ~/logs/sim.log | sed 's/^/    /'
crash() { printf 'crash\n' | nc -w 3 127.0.0.1 3262; }
stats() { printf 'stats\n' | nc -w 3 127.0.0.1 3262; }

echo "=== B1. write-through (default): prepare, crash the target, re-attach, verify"
attach 127.0.0.1:4420 "$SIM_NQN" 1 || { echo "B1-ATTACH-FAILED"; kill $SIMPID $LOGPID; exit 1; }
run 120 ERASE-APFS diskutil eraseDisk APFS SimTest GPT "$DEV" || { echo "B1-FORMAT-FAILED"; kill $SIMPID $LOGPID; exit 1; }
sleep 2
run 120 B1-PREPARE python3 scripts/crash-consistency.py prepare --dir /Volumes/SimTest/durable --manifest ~/logs/sim1-manifest.json --count 32 --size 1048576
echo "    stats before crash: $(stats)"
echo "    CRASH: $(crash)"
sleep 2
detach
attach 127.0.0.1:4420 "$SIM_NQN" 1 || { echo "B1-REATTACH-FAILED"; kill $SIMPID $LOGPID; exit 1; }
run 60 B1-MOUNT diskutil mountDisk "$DEV"; sleep 2
run 120 B1-VERIFYVOLUME diskutil verifyVolume /Volumes/SimTest
run 120 B1-VERIFY-FILES python3 scripts/crash-consistency.py verify --dir /Volumes/SimTest/durable --manifest ~/logs/sim1-manifest.json
detach

echo "=== B2. negative control: flushIntervalSeconds 0 (never), same sequence"
sudo python3 - <<'PY'
import json
p="/Library/Application Support/me.herko.iSCSIInitiator/targets.json"
r=json.load(open(p))
for t in r:
    if t["host"]=="127.0.0.1": t["flushIntervalSeconds"]=0
json.dump(r,open(p,"w"),indent=1)
PY
attach 127.0.0.1:4420 "$SIM_NQN" 1 || { echo "B2-ATTACH-FAILED"; kill $SIMPID $LOGPID; exit 1; }
run 120 ERASE-APFS diskutil eraseDisk APFS SimTest2 GPT "$DEV" || { echo "B2-FORMAT-FAILED"; kill $SIMPID $LOGPID; exit 1; }
sleep 2
run 120 B2-PREPARE python3 scripts/crash-consistency.py prepare --dir /Volumes/SimTest2/durable --manifest ~/logs/sim2-manifest.json --count 32 --size 1048576
echo "    stats before crash: $(stats)"
echo "    CRASH: $(crash)"
sleep 2
detach
attach 127.0.0.1:4420 "$SIM_NQN" 1 || { echo "B2-REATTACH-FAILED"; kill $SIMPID $LOGPID; exit 1; }
run 60 B2-MOUNT diskutil mountDisk "$DEV"; sleep 2
run 120 B2-VERIFYVOLUME diskutil verifyVolume /Volumes/SimTest2
run 120 B2-VERIFY-FILES python3 scripts/crash-consistency.py verify --dir /Volumes/SimTest2/durable --manifest ~/logs/sim2-manifest.json
detach

echo "=== cleanup"
printf 'quit\n' | nc -w 3 127.0.0.1 3262 >/dev/null 2>&1; sleep 1; kill $SIMPID 2>/dev/null
sudo python3 - <<'PY'
import json
p="/Library/Application Support/me.herko.iSCSIInitiator/targets.json"
r=[t for t in json.load(open(p)) if t["host"]!="127.0.0.1"]
json.dump(r,open(p,"w"),indent=1)
PY
kill $LOGPID 2>/dev/null
echo "    session lines from the daemon log:"; grep -E "write cache|connection lost|recovered|RECOVERY" ~/logs/nvme-attach.log | sed 's/^[^:]*: //' | tail -12
echo "=== $(date '+%H:%M:%S') DONE"
