#!/bin/bash
# vm-resilience.sh — run ON the VM as root, STREAMED over ssh.
#
# Drives the whole Backend A stack (FSKit extension -> DiskImages -> APFS)
# against the *local* target simulator, then breaks the target on purpose and
# asks whether the stack degraded the way it is supposed to.
#
# The simulator is what makes this possible. Against the real NAS none of these
# scenarios can be run: we cannot drop its connections on cue, we cannot make it
# swallow commands while still answering pings, and we certainly cannot cut its
# power mid-write. Loopback also removes the ~98 MB/s transport ceiling, so a
# hang is a hang rather than a slow link.
#
# What each scenario is actually asking:
#
#   baseline  Does the stack work at all over the simulator? If this fails,
#             nothing below means anything.
#   drop      Connections die mid-write. ERL0 recovery should re-login and
#             resubmit; the data must still verify afterwards.
#   stall     The target accepts commands and never answers, but keeps
#             answering NOPs. This must surface an *error* within the task
#             deadline. A hang here becomes a wedged APFS volume, which is
#             strictly worse than a failed write.
#   crash     Target power loss with a volatile write cache. With FUA on every
#             write, everything acknowledged is on stable media, so the
#             filesystem must come back consistent.
#   pause     The portal stops accepting long enough to exhaust recovery. The
#             stack must fail cleanly and then recover once the portal is back
#             — not stay dead, and not wedge.
#
# Usage (on the VM, as root):
#   scripts/vm-resilience.sh [scenario ...]     # default: all
set -uo pipefail
cd ~/iSCSI || exit 1

SIM=.build/release/iscsi-target-sim
IQN=iqn.2026-08.me.herko.sim:lun0
PORT=3260
CTLPORT=3262
LUNIMG=/Users/herko/simlun.img
SIMLOG=/Users/herko/logs/sim.log
FSMNT=/Users/herko/simfs
APFSMNT=/Users/herko/simmnt
CAPACITY_MIB=${CAPACITY_MIB:-4096}
DEV=""
VOL=""

mkdir -p /Users/herko/logs "$FSMNT" "$APFSMNT"

ctl() { printf '%s\n' "$*" | nc -w 5 127.0.0.1 "$CTLPORT" 2>/dev/null; }

# Bounded step runner: macOS has no timeout(1), and a hang must not take the
# whole run with it. rc is captured explicitly — piping to tail would report
# tail's status and turn a failure into a pass.
#
# Returns 124 (timeout(1)'s convention) when it had to kill the step, so a
# caller can tell "wedged" from "failed cleanly". For most steps both are bad
# and `|| return 1` is enough; for the stall scenario the difference *is* the
# result, so the distinction has to survive.
run() {
  local secs=$1 label=$2; shift 2
  # Truncate first: a killed step never gets sed'd, and its leftovers would
  # otherwise be printed as if they belonged to the next step.
  : >/tmp/rstep.out
  "$@" >/tmp/rstep.out 2>&1 &
  local pid=$! i=0
  while [ $i -lt "$secs" ]; do
    kill -0 $pid 2>/dev/null || break
    sleep 1; i=$((i+1))
  done
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid 2>/dev/null; echo "  ${label}-BLOCKED (>${secs}s)"; return 124
  fi
  wait $pid; local rc=$?
  sed 's/^/    /' /tmp/rstep.out
  [ $rc -eq 0 ] && echo "  ${label}-OK" || echo "  ${label}-FAILED(rc=$rc)"
  return $rc
}

teardown() {
  umount -f "$APFSMNT" 2>/dev/null
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  umount -f "$FSMNT" 2>/dev/null
  DEV=""; VOL=""
}

cleanup() {
  teardown
  ctl quit >/dev/null 2>&1
  sleep 1
  pkill -f iscsi-target-sim 2>/dev/null
}
trap cleanup EXIT

start_sim() {
  pkill -f iscsi-target-sim 2>/dev/null; sleep 1
  # Fresh backing file per run, so a scenario cannot pass on the previous
  # run's data.
  rm -f "$LUNIMG"
  # DIGEST=CRC32C turns on header/data digests. The real NAS negotiates them
  # off, so this is the only place the CRC32C path runs under load — and the
  # only place payload corruption can be tested for detection rather than
  # silently absorbed.
  "$SIM" --port "$PORT" --control-port "$CTLPORT" --block-size 4096 \
         --capacity-mib "$CAPACITY_MIB" --backing-file "$LUNIMG" \
         --digest "${DIGEST:-None}" \
         >"$SIMLOG" 2>&1 &
  for _ in $(seq 1 20); do
    [ "$(ctl ping)" = "ok" ] && return 0
    sleep 1
  done
  echo "SIM-NOT-READY"; sed 's/^/    /' "$SIMLOG"; return 1
}

# APFS on a raw disk synthesizes a *different* disk number for the volume
# (disk10 -> disk11s1), so "${DEV}s1" does not exist. Ask diskutil which volume
# sits on our physical store rather than guessing.
apfs_volume_of() {
  local store=${1#/dev/}
  diskutil apfs list -plist 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
want = sys.argv[1]
try:
    # loads(), not load(): a pipe is not seekable and plistlib.load seeks.
    d = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
for c in d.get("Containers", []):
    stores = [s.get("DeviceIdentifier", "") for s in c.get("PhysicalStores", [])]
    if any(s == want or s.startswith(want + "s") for s in stores):
        for v in c.get("Volumes", []):
            print(v["DeviceIdentifier"]); sys.exit(0)
' "$store"
}

wait_for_volume() {
  local i=0
  while [ $i -lt 30 ]; do
    VOL=$(apfs_volume_of "$DEV")
    [ -n "$VOL" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

mount_volume() {
  run 60 MOUNT diskutil mount -mountPoint "$APFSMNT" "$VOL"
}

# Bring up FSKit -> DiskImages. `format` lays down APFS; `nomount` stops before
# mounting, which is what fsck needs — fsck_apfs refuses a mounted volume, and
# a refusal looks exactly like a pass if its exit status is swallowed.
attach() {
  local want_format=${1:-no}
  local want_mount=${2:-mount}
  if ! /sbin/mount | grep -qF " $FSMNT "; then
    run 60 FSMOUNT mount -F -t iSCSI "iscsi://127.0.0.1/$IQN/0" "$FSMNT" || return 1
  fi
  [ -f "$FSMNT/lun0.img" ] || { echo "  NO-LUN-IMG"; return 1; }

  local out
  out=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -noverify -nomount \
        "$FSMNT/lun0.img" 2>&1)
  DEV=$(echo "$out" | awk 'NR==1{print $1}')
  [ -z "$DEV" ] && { echo "  ATTACH-FAILED"; echo "$out" | sed 's/^/    /'; return 1; }
  echo "  attached $DEV"

  if [ "$want_format" = format ]; then
    run 120 NEWFS newfs_apfs -v SimScratch "$DEV" || return 1
    sleep 2
  fi
  wait_for_volume || { echo "  NO-APFS-VOLUME on $DEV"; return 1; }
  echo "  apfs volume: $VOL"
  [ "$want_mount" = nomount ] && return 0
  mount_volume || return 1
  return 0
}

# Deterministic file writer + verifier. Python is what the VM has; fio is not
# installed and would not exercise the paths that actually broke here anyway.
write_files() {
  local dir=$1 count=$2 mib=$3
  /usr/bin/python3 - "$dir" "$count" "$mib" <<'PY'
import hashlib, os, sys
d, n, mib = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(d, exist_ok=True)
chunk = bytes(range(256)) * 4096          # 1 MiB, deterministic
for i in range(n):
    p = os.path.join(d, f"f{i}.bin")
    h = hashlib.sha256()
    with open(p, "wb") as f:
        for _ in range(mib):
            block = bytes((b + i) & 0xFF for b in chunk[:4096]) * 256
            f.write(block); h.update(block)
        f.flush(); os.fsync(f.fileno())
    with open(p + ".sha", "w") as f:
        f.write(h.hexdigest())
print(f"wrote {n} x {mib} MiB")
PY
}

verify_files() {
  local dir=$1
  /usr/bin/python3 - "$dir" <<'PY'
import hashlib, os, sys
d = sys.argv[1]
bad = missing = ok = 0
for name in sorted(os.listdir(d)):
    if not name.endswith(".bin"):
        continue
    want_path = os.path.join(d, name + ".sha")
    if not os.path.exists(want_path):
        missing += 1; continue
    want = open(want_path).read().strip()
    h = hashlib.sha256()
    with open(os.path.join(d, name), "rb") as f:
        while (b := f.read(1 << 20)):
            h.update(b)
    if h.hexdigest() == want: ok += 1
    else: bad += 1; print("MISMATCH", name)
print(f"verified ok={ok} mismatched={bad} missingDigest={missing}")
sys.exit(1 if bad else 0)
PY
}

# ---------------------------------------------------------------- scenarios

scenario_baseline() {
  echo "=== baseline: does the stack work over the simulator at all"
  attach format || return 1
  run 300 WRITE write_files "$APFSMNT/work" 4 16 || return 1
  run 300 VERIFY verify_files "$APFSMNT/work" || return 1
  echo "  $(ctl stats)"
  teardown
  echo "BASELINE-PASS"
}

scenario_drop() {
  echo "=== drop: connections die mid-write, recovery must resubmit"
  attach || return 1
  ( write_files "$APFSMNT/dropwork" 12 16 >/tmp/dropwrite.out 2>&1; echo "rc=$?" >>/tmp/dropwrite.out ) &
  local writer=$! killed=0
  for i in 1 2 3 4; do
    sleep 6
    local reply
    reply=$(ctl drop)
    echo "  drop $i: $reply"
    # Sum what was actually killed. Loopback is fast enough that a short write
    # can finish before the first drop lands, and "dropped=0" four times over
    # is a scenario that tested nothing.
    killed=$((killed + $(echo "$reply" | sed -n 's/.*dropped=\([0-9]*\).*/\1/p')))
  done
  if [ "$killed" -eq 0 ]; then
    echo "  NO-CONNECTIONS-DROPPED — the write finished before any drop landed"
    kill -9 $writer 2>/dev/null
    return 1
  fi
  echo "  connections killed: $killed"
  local waited=0
  while kill -0 $writer 2>/dev/null && [ $waited -lt 300 ]; do sleep 2; waited=$((waited+2)); done
  if kill -0 $writer 2>/dev/null; then kill -9 $writer; echo "  WRITER-BLOCKED"; return 1; fi
  sed 's/^/    /' /tmp/dropwrite.out
  grep -q "rc=0" /tmp/dropwrite.out || { echo "  WRITE-FAILED"; return 1; }
  run 300 VERIFY verify_files "$APFSMNT/dropwork" || return 1
  teardown
  echo "DROP-PASS"
}

scenario_stall() {
  echo "=== stall: commands swallowed, NOPs answered — must error, not hang"
  attach || return 1
  echo "  $(ctl fault stallcommands on)"
  # The task deadline is 30s and the daemon retries on a fresh session, so a
  # bounded failure can legitimately take a couple of minutes. What must not
  # happen is no return at all.
  run 240 STALLWRITE write_files "$APFSMNT/stallwork" 1 8
  local rc=$?
  echo "  $(ctl fault stallcommands off)"
  if [ $rc -eq 124 ]; then
    # This is the bug the scenario exists to catch: the I/O never came back,
    # which upstream means a wedged APFS volume rather than a failed write.
    echo "  WEDGED — the write never returned"
    return 1
  fi
  if [ $rc -eq 0 ]; then
    # A pass here would be an accident: the fault never reached the data path.
    echo "  NO-FAULT-EFFECT — the write succeeded, so nothing was stalled"
    return 1
  fi
  echo "  write failed cleanly (rc=$rc) — a bounded error, which is the point"
  run 180 RECOVER write_files "$APFSMNT/stallwork2" 1 8 || return 1
  run 180 VERIFY verify_files "$APFSMNT/stallwork2" || return 1
  teardown
  echo "STALL-PASS"
}

scenario_crash() {
  echo "=== crash: target power loss with a volatile cache; FUA must have saved us"
  attach || return 1
  run 300 WRITE write_files "$APFSMNT/crashwork" 4 16 || return 1

  # Crash *during* a write, not at rest. At rest the filesystem is quiescent
  # and consistency is nearly free; mid-write is where a lost cache would
  # actually tear metadata.
  ( write_files "$APFSMNT/crashtail" 8 16 >/tmp/crashtail.out 2>&1 ) &
  local writer=$!
  sleep 8
  echo "  before crash: $(ctl stats)"
  local reply
  reply=$(ctl crash)
  echo "  $reply"
  # blocksLost=0 is the assertion, not an anticlimax: with FUA on every write
  # there was nothing in the volatile cache for the power cut to take.
  case "$reply" in
    *blocksLost=0*) echo "  nothing was in the volatile cache — FUA covered every write" ;;
    *) echo "  CACHED-DATA-LOST — some writes were acknowledged without reaching stable media"; ;;
  esac
  kill -9 $writer 2>/dev/null; wait $writer 2>/dev/null

  # The stack is now talking to a target that lost its cache and its
  # connections. Tear down without trying to be graceful — that is the point.
  umount -f "$APFSMNT" 2>/dev/null
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  umount -f "$FSMNT" 2>/dev/null
  DEV=""; VOL=""
  sleep 3

  # nomount: fsck_apfs refuses to check a mounted volume, and its refusal exits
  # non-zero — which reads exactly like a filesystem problem, or gets swallowed
  # and reads exactly like a pass. Check before mounting.
  attach no nomount || return 1
  run 300 FSCK fsck_apfs -n "/dev/$VOL" || return 1
  mount_volume || return 1
  run 300 VERIFY verify_files "$APFSMNT/crashwork" || return 1
  echo "  after crash: $(ctl stats)"
  teardown
  echo "CRASH-PASS"
}

scenario_corrupt() {
  echo "=== corrupt: payload flipped on the wire; digests must catch it"
  if [ "${DIGEST:-None}" != "CRC32C" ]; then
    echo "  SKIPPED — rerun with DIGEST=CRC32C so digests are negotiated on"
    return 0
  fi
  attach || return 1
  run 300 WRITE write_files "$APFSMNT/corruptwork" 2 16 || return 1

  echo "  $(ctl fault corruptdatain on)"
  # The claim under test is *not* "reads fail". It is that corrupted bytes
  # never reach the application: either the digest check kills the session, or
  # the read errors. Silently returning wrong data is the failure.
  run 240 CORRUPTREAD verify_files "$APFSMNT/corruptwork"
  local rc=$?
  echo "  $(ctl fault corruptdatain off)"
  if [ $rc -eq 124 ]; then echo "  WEDGED under corruption"; return 1; fi
  if grep -q MISMATCH /tmp/rstep.out 2>/dev/null; then
    echo "  CORRUPTION-REACHED-APPLICATION — the digest did not catch it"
    return 1
  fi
  echo "  no corrupted bytes surfaced (read errored or the session dropped)"

  sleep 5
  run 300 REVERIFY verify_files "$APFSMNT/corruptwork" || return 1
  teardown
  echo "CORRUPT-PASS"
}

scenario_pause() {
  echo "=== pause: portal stops accepting, then comes back"
  # The first version of this held the portal down for the entire measurement
  # window and then asserted that the write did not block — which is not a
  # claim anyone should make. A network disk that is genuinely unreachable is
  # *allowed* to block; open-iscsi blocks for two minutes by default. The
  # claim worth testing is the one after it: once the portal is back, the
  # stack has to make progress again rather than stay dead.
  attach || return 1
  ( write_files "$APFSMNT/pausework" 4 16 >/tmp/pausewrite.out 2>&1
    echo "rc=$?" >>/tmp/pausewrite.out ) &
  local writer=$!
  sleep 5
  echo "  $(ctl pause)"
  echo "  $(ctl drop)"
  # Hold it down well past recovery exhaustion (5 attempts over ~16s of
  # backoff) so the session genuinely gives up rather than papering over it.
  sleep 60
  if kill -0 $writer 2>/dev/null; then
    echo "  writer still blocked after 60s of downtime (allowed)"
  else
    echo "  writer already returned during the outage (also allowed)"
  fi
  echo "  $(ctl resume)"

  local waited=0
  while kill -0 $writer 2>/dev/null && [ $waited -lt 180 ]; do sleep 3; waited=$((waited+3)); done
  if kill -0 $writer 2>/dev/null; then
    kill -9 $writer 2>/dev/null
    echo "  WEDGED — still blocked ${waited}s after the portal came back"
    return 1
  fi
  echo "  writer returned ${waited}s after resume"
  sed 's/^/    /' /tmp/pausewrite.out

  # However the interrupted write ended, a fresh one must work now.
  run 240 RECOVER write_files "$APFSMNT/pausework2" 1 8 || return 1
  run 240 VERIFY verify_files "$APFSMNT/pausework2" || return 1
  teardown
  echo "PAUSE-PASS"
}

# -------------------------------------------------------------------- main

SCENARIOS=("$@")
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(baseline drop stall crash pause)

start_sim || exit 1
echo "=== simulator: $(ctl status)"

FAILED=0
FIRST=1
for s in "${SCENARIOS[@]}"; do
  # Only the first scenario formats; the rest reuse the filesystem, which is
  # what makes "the data is still there afterwards" a meaningful claim.
  if [ $FIRST -eq 1 ] && [ "$s" != baseline ]; then
    attach format >/dev/null 2>&1 && teardown
  fi
  FIRST=0
  if ! "scenario_$s"; then
    # macOS ships bash 3.2, which has no ${var^^}.
    echo "$(echo "$s" | tr '[:lower:]' '[:upper:]')-FAIL"
    FAILED=$((FAILED+1))
    teardown
  fi
  echo
done

echo "=== $((${#SCENARIOS[@]} - FAILED))/${#SCENARIOS[@]} scenarios passed"
[ $FAILED -eq 0 ] && echo RESILIENCE-PASS || echo RESILIENCE-FAIL
exit $FAILED
