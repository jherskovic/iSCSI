#!/bin/bash
# vm-nvme-soak.sh — run ON the SIP-off VM as the logged-in user, DETACHED
# (nohup …&). A multi-hour soak of NVMe/TCP through the shipping stack:
# mount -F with an nvme:// URL, hdiutil CRawDiskImage, APFS, against the NAS
# scratch namespace. Cycles, each ~20 min, until the deadline:
#
#   1. scripts/soak.py — 4 workers, 15 min of unaligned read-modify-write and
#      whole-file rewrites, every read verified by SHA-256; 2 GiB of memory
#      pressure on even cycles (writeback through a userspace filesystem is
#      the classic loopback-deadlock shape);
#   2. a 1 GiB sequential write, sync, purge, read-back and checksum
#      (throughput both ways, and no stale page-cache pass);
#   3. 64 fsync'd 1 MiB files written and verified (crash-consistency.py);
#   4. diskutil verifyVolume, live.
#
# Alongside: the daemon's log (connection lost / recovered / exhausted /
# errors are counted per cycle) and a per-minute RSS sample of iscsid, the
# extension process and fskitd, for leak hunting. Status lines go to
# status.txt after every cycle; ABORT stops the run on a wedged step, a
# checksum mismatch or a failed volume check, leaving the volume attached
# for inspection. DESTRUCTIVE to the namespace it is pointed at.
#
#   HOURS=6 nohup scripts/vm-nvme-soak.sh > ~/logs/nvme-soak/run.log 2>&1 &
set -uo pipefail
cd ~/iSCSI || exit 1
HOURS=${HOURS:-6}
NAS=${NAS:-192.168.20.1:4420}
NAS_NQN=${NAS_NQN:-nqn.2011-06.com.truenas:uuid:75ca6aa3-69fd-44e5-8269-8722b52845d0:name-testing}
LOGDIR=~/logs/nvme-soak
mkdir -p "$LOGDIR"
STATUS="$LOGDIR/status.txt"; RSS="$LOGDIR/rss.csv"; CYCLES="$LOGDIR/cycles.tsv"; DLOG="$LOGDIR/daemon.log"
CACHE=~/Library/Caches/me.herko.iSCSIInitiator
DEADLINE=$(( $(date +%s) + HOURS * 3600 ))
: > "$STATUS"; : > "$CYCLES"
echo "epoch,iscsid_rss_kb,fsext_rss_kb,fskitd_rss_kb" > "$RSS"

status() { echo "$(date '+%H:%M:%S') $*" | tee -a "$STATUS"; }

run() {  # run <secs> <label> <cmd...>: bounded; LABEL-OK / LABEL-FAILED / LABEL-BLOCKED
  local secs=$1 label=$2; shift 2
  "$@" >/tmp/soak-step.out 2>&1 &
  local pid=$! i=0
  while [ $i -lt "$secs" ]; do kill -0 $pid 2>/dev/null || break; sleep 1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; echo "${label}-BLOCKED"; return 124; fi
  wait $pid; local rc=$?
  [ $rc -eq 0 ] && echo "${label}-OK" || echo "${label}-FAILED(rc=$rc)"
  return $rc
}

tag() { printf '%s|%s|%s' "$1" "$2" "$3" | shasum -a 256 | cut -c1-16; }

attach() {
  HIDDEN="$CACHE/$(tag "$1" "$2" "$3")"
  mkdir -p "$HIDDEN"
  run 60 MOUNT-FSKIT mount -F -t iSCSI "nvme://$1/$2/$3" "$HIDDEN" || return 1
  [ -f "$HIDDEN/lun0.img" ] || { echo "NO-IMAGE"; return 1; }
  run 60 HDIUTIL hdiutil attach -imagekey diskimage-class=CRawDiskImage -noverify -nomount "$HIDDEN/lun0.img" || return 1
  DEV=$(awk 'NR==1{print $1}' /tmp/soak-step.out)
}

detach() {
  run 120 UNMOUNT diskutil unmountDisk force "$DEV"
  run 120 HDIUTIL-DETACH hdiutil detach "$DEV" -force
  run 60 UMOUNT-FSKIT umount "$HIDDEN" || run 60 UMOUNT-FSKIT-F umount -f "$HIDDEN"
}

daemon_counts() {  # lost recovered exhausted errors
  echo "$(grep -c 'connection lost' "$DLOG") $(grep -c 'recovered (' "$DLOG") $(grep -c 'RECOVERY EXHAUSTED' "$DLOG") $(grep -ci ' error ' "$DLOG")"
}

/usr/bin/log stream --info --debug --predicate 'subsystem BEGINSWITH "me.herko.iSCSIInitiator"' > "$DLOG" 2>&1 &
LOGPID=$!
( while true; do
    d=$(pgrep -x iscsid | head -1); e=$(pgrep -f iSCSIFSExtension.appex | head -1); f=$(pgrep -x fskitd | head -1)
    r() { [ -n "${1:-}" ] && ps -o rss= -p "$1" 2>/dev/null | tr -d ' ' || echo 0; }
    echo "$(date +%s),$(r "$d"),$(r "$e"),$(r "$f")" >> "$RSS"
    sleep 60
  done ) &
RSSPID=$!
cleanup_bg() { kill $LOGPID $RSSPID 2>/dev/null; }

status "START hours=$HOURS target=$NAS $NAS_NQN nsid 1"
attach "$NAS" "$NAS_NQN" 1 || { status "ABORT attach failed: $(tail -3 /tmp/soak-step.out | tr '\n' ' ')"; cleanup_bg; exit 1; }
run 180 ERASE-APFS diskutil eraseDisk APFS NVMeSoak GPT "$DEV" || { status "ABORT format failed"; detach; cleanup_bg; exit 1; }
sleep 3
VOL=/Volumes/NVMeSoak
[ -d "$VOL" ] || { status "ABORT no volume"; detach; cleanup_bg; exit 1; }
mkdir -p "$VOL/soak"
status "ATTACHED $DEV $(grep -o 'nsid 1: write cache.*' "$DLOG" | tail -1)"

PRESSURE=$(( $(sysctl -n hw.memsize) / 1048576 >= 8192 ? 2048 : 0 ))
cycle=0; tot_verifies=0; tot_soak_errors=0; tot_written_mb=0
echo -e "cycle\tsecs\tsoak_verifies\tsoak_errors\tsoak_rmw\tseq_write_MBs\tseq_read_MBs\tseq_ok\tfsync_ok\tverifyvolume\tlost\trecovered\texhausted\terrors" >> "$CYCLES"

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  cycle=$((cycle + 1)); start=$(date +%s)
  P=0; [ $((cycle % 2)) -eq 0 ] && P=$PRESSURE

  # 1. verified mixed I/O
  run 1500 SOAK python3 scripts/soak.py --dir "$VOL/soak" --seconds 900 --workers 4 --pressure-mb $P; soak_rc=$?
  cp /tmp/soak-step.out "$LOGDIR/soak-$cycle.log"
  soak_err=$(grep -cE 'MISMATCH|ERROR' "$LOGDIR/soak-$cycle.log")
  soak_ver=$(grep -oE 'verifies[= ]+[0-9]+' "$LOGDIR/soak-$cycle.log" | tail -1 | grep -oE '[0-9]+$'); soak_ver=${soak_ver:-0}
  soak_rmw=$(grep -oE 'rmw[= ]+[0-9]+' "$LOGDIR/soak-$cycle.log" | tail -1 | grep -oE '[0-9]+$'); soak_rmw=${soak_rmw:-0}
  [ $soak_rc -eq 124 ] && { status "ABORT cycle $cycle: soak.py BLOCKED (no progress for 25 min)"; break; }

  # 2. sequential 1 GiB, purge, read back
  t0=$(date +%s.%N)
  run 600 SEQ-WRITE dd if=/dev/urandom of="$VOL/seq.bin" bs=1m count=1024; seq_rc=$?
  t1=$(date +%s.%N); sync; t2=$(date +%s.%N)
  before=$(shasum -a 256 "$VOL/seq.bin" | awk '{print $1}')
  sudo purge
  t3=$(date +%s.%N); after=$(shasum -a 256 "$VOL/seq.bin" | awk '{print $1}'); t4=$(date +%s.%N)
  wmbs=$(python3 -c "print(round(1024/($t2-$t0),1))"); rmbs=$(python3 -c "print(round(1024/($t4-$t3),1))")
  seq_ok=$([ "$before" = "$after" ] && [ $seq_rc -eq 0 ] && echo yes || echo NO)
  rm -f "$VOL/seq.bin"

  # 3. fsync'd files
  run 600 FSYNC python3 scripts/crash-consistency.py prepare --dir "$VOL/durable" --manifest "$LOGDIR/m.json" --count 64 --size 1048576
  run 300 FSYNC-VERIFY python3 scripts/crash-consistency.py verify --dir "$VOL/durable" --manifest "$LOGDIR/m.json"; fs_rc=$?
  fsync_ok=$([ $fs_rc -eq 0 ] && echo yes || echo NO)
  rm -rf "$VOL/durable"

  # 4. live volume check
  run 600 VERIFYVOLUME diskutil verifyVolume "$VOL"; vv_rc=$?
  vv=$([ $vv_rc -eq 0 ] && echo OK || echo FAIL); [ $vv_rc -eq 124 ] && vv=BLOCKED

  read -r lost recovered exhausted errors <<<"$(daemon_counts)"
  secs=$(( $(date +%s) - start ))
  tot_verifies=$((tot_verifies + soak_ver)); tot_soak_errors=$((tot_soak_errors + soak_err)); tot_written_mb=$((tot_written_mb + 1024))
  echo -e "$cycle\t$secs\t$soak_ver\t$soak_err\t$soak_rmw\t$wmbs\t$rmbs\t$seq_ok\t$fsync_ok\t$vv\t$lost\t$recovered\t$exhausted\t$errors" >> "$CYCLES"
  status "cycle $cycle done in ${secs}s (pressure ${P}MB): soak verifies=$soak_ver errors=$soak_err rmw=$soak_rmw | seq write=${wmbs} read=${rmbs} MB/s ok=$seq_ok | fsync 64 ok=$fsync_ok | verifyVolume=$vv | daemon lost=$lost recovered=$recovered exhausted=$exhausted errors=$errors"

  if [ "$soak_err" -gt 0 ] || [ "$seq_ok" != yes ] || [ "$fsync_ok" != yes ] || [ "$vv" != OK ] || [ "$exhausted" -gt 0 ]; then
    status "ABORT after cycle $cycle: see cycles.tsv, soak-$cycle.log, daemon.log — volume left attached at $VOL"
    cleanup_bg; exit 1
  fi
done

status "SOAK-COMPLETE cycles=$cycle verifies=$tot_verifies soak_errors=$tot_soak_errors seq_written_MB=$tot_written_mb"
detach
cleanup_bg
first=$(sed -n '2p' "$RSS"); last=$(tail -1 "$RSS")
status "RSS iscsid/fsext/fskitd KB first=[${first#*,}] last=[${last#*,}] max=[$(awk -F, 'NR>1{for(i=2;i<=4;i++) if($i+0>m[i]) m[i]=$i+0} END{print m[2]","m[3]","m[4]}' "$RSS")]"
status "DONE"
