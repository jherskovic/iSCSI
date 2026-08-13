#!/bin/bash
# vm-flush-probe.sh — run ON the VM. Attaches the scratch LUN, then asks the raw
# device to flush via ioctl, with no filesystem anywhere in the picture, and
# reports whether the request reached the daemon as SYNCHRONIZE CACHE.
set -uo pipefail
cd ~/iSCSI || exit 1

TARGET=${TARGET:-iqn.me.herko.planet-express:iscsi-driver-testing}
PORTAL=${PORTAL:-192.168.0.101}
LOG=/tmp/flushprobe-iscsid.log
CTL=.build/release/iscsictl

# Find our LUN by identity: a killed daemon leaves the IOMedia node behind, so
# "the disk that wasn't there a moment ago" finds nothing on the second run.
our_disk() {
  ioreg -r -c IOSCSIPeripheralDeviceType00 -l 2>/dev/null \
    | grep -m1 -o '"BSD Name" = "disk[0-9]*"' | grep -o 'disk[0-9]*'
}

echo "== wipe LUN (so nothing auto-mounts)"
$CTL wipe "$PORTAL" --target "$TARGET" >/tmp/flushprobe-wipe.log 2>&1 \
  || { echo "WIPE FAILED"; tail -5 /tmp/flushprobe-wipe.log; exit 1; }

echo "== attach"
$CTL dext-attach --portal "$PORTAL" --target "$TARGET" >"$LOG" 2>&1 &
ATTACH=$!
trap 'kill $ATTACH 2>/dev/null' EXIT

DISK=""
for _ in $(seq 1 45); do
  sleep 1
  d=$(our_disk)
  if [ -n "$d" ] && diskutil info "$d" >/dev/null 2>&1; then DISK="/dev/$d"; break; fi
done
if [ -z "$DISK" ]; then
  echo "NO DISK APPEARED"; tail -20 "$LOG"; exit 1
fi
RAW="/dev/r${DISK#/dev/}"
echo "== our disk: $DISK (raw $RAW)"
sleep 2

MARK=$(wc -l < "$LOG")

echo "== dkflush"
echo "${VMPASS:-herko}" | sudo -S ./dkflush "$RAW" --write

echo
echo "== what the daemon saw after the mark:"
tail -n "+$((MARK + 1))" "$LOG" | grep -E "FLUSH|unsupported|failed" | head -20
echo "-- FLUSH count: $(tail -n "+$((MARK + 1))" "$LOG" | grep -c FLUSH)"
echo "-- total FLUSH this session: $(grep -c FLUSH "$LOG")"
echo
echo "== opcodes the dext reported unsupported (whole session):"
grep "unsupported opcode" "$LOG" | sort | uniq -c | head
