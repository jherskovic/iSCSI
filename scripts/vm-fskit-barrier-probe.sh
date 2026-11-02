#!/bin/bash
# vm-fskit-barrier-probe.sh — run on the Mac with a volume the app has attached
# (normally a test VM). Results so far: docs/backend-a-fskit-notes.md, "there
# is no barrier signal".
#
# Does any flush a user can issue reach the FSKit extension? On macOS 26.6 none
# did: `synchronize` never fired, and fsync and F_FULLFSYNC on lun0.img arrived
# as plain writes (docs/backend-a-fskit-notes.md, "there is no barrier
# signal"). That is why every write carries FUA, and why the extension cannot
# buffer or merge writes. This repeats the check through the whole shipping
# stack, on whatever macOS the VM runs: APFS on the attached disk, the
# disk-image engine, FSKit, the extension.
#
# Each step issues one kind of flush. The extension's log is streamed for the
# whole run, with a `logger` marker before each step, so every line is
# attributed by order, not by timestamp. A signal would be:
#   SYNCHRONIZE flags=N     FSKit's volume sync: the barrier itself
#   CLOSE keeping=0         a final close of lun0.img, which the extension flushes on
#   CLOSE (data cache)      the same on macOS 27, when the volume grants a cache mode
# Anything a flush step shows that the idle and write-only steps do not is the
# finding.
#
# Writes a few MiB of new files under <volume>/.barrier-probe-<pid> and removes
# them. Nothing else on the volume is touched; lun0.img and the raw device are
# opened read-only. Use a scratch target anyway. The device step needs sudo
# only when the raw device is not readable by the user running this.
#
# On the host (the VM has no compiler):
#   cc -O2 -arch arm64 -mmacosx-version-min=26.0 -o syncprobe tools/syncprobe.c
#   scp scripts/vm-fskit-barrier-probe.sh syncprobe <vm>:
# On the VM, after attaching a scratch target in the app:
#   ./vm-fskit-barrier-probe.sh /Volumes/<volume>
#
# Run it once per attach engine: as shipped (hdiutil), then after
#   defaults write me.herko.iSCSIInitiator ImageAttachEngine diskimages2
# and a detach and re-attach (macOS 27 only). The two engines reach FSKit
# differently, so one result does not answer for the other.
set -uo pipefail

VOLUME=${1:?usage: vm-fskit-barrier-probe.sh /Volumes/<volume> [path/to/syncprobe]}
VOLUME=${VOLUME%/}
PROBE=${2:-$(cd "$(dirname "$0")" && pwd)/syncprobe}
SETTLE=${SETTLE:-3}                  # seconds to wait after each step
MIB=$((4 * 1024 * 1024))
SUBSYSTEM=me.herko.iSCSIInitiator.fsext
TAG=barrier-probe-$$
OUT=${OUT:-/tmp/fskit-barrier-probe-$(date +%Y%m%d-%H%M%S).log}

[ -x "$PROBE" ] || { echo "no syncprobe at $PROBE; build it from tools/syncprobe.c"; exit 1; }
[ -d "$VOLUME" ] || { echo "$VOLUME is not a mounted volume"; exit 1; }

# The disk image under the volume. `hdiutil info` lists each attached image
# with its devices and their mount points, an APFS container's synthesized
# volumes included, and it lists images from either attach engine. The first
# whole disk after an image-path is that image's own device.
IFS=$'\t' read -r DISK IMAGE < <(/usr/bin/hdiutil info | awk -F'\t' -v mp="$VOLUME" '
  /^image-path/ { image = $0; sub(/^image-path *: */, "", image); whole = ""; next }
  /^\/dev\/disk/ {
    dev = $1; sub(/ +$/, "", dev)
    if (whole == "" && dev ~ /^\/dev\/disk[0-9]+$/) whole = dev
    point = $3; sub(/[ \t]+$/, "", point)
    if (point == mp) { print whole "\t" image; exit }
  }')
if [ -z "${DISK:-}" ] || [ -z "${IMAGE:-}" ]; then
  echo "$VOLUME is not on an attached disk image. hdiutil info says:"
  /usr/bin/hdiutil info
  exit 1
fi
RAW="/dev/r${DISK#/dev/}"
FSKIT_MOUNT=$(/sbin/mount | grep -F " on $(dirname "$IMAGE") " || echo "(not found in the mount table)")

{
  echo "macOS:        $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "volume:       $VOLUME"
  echo "disk image:   $IMAGE"
  echo "device:       $DISK (raw $RAW)"
  echo "FSKit mount:  $FSKIT_MOUNT"
  echo "engine pref:  $(defaults read me.herko.iSCSIInitiator ImageAttachEngine 2>/dev/null || echo 'unset (hdiutil)')"
} | tee "$OUT"

# Which extension process serves this volume. Every attached volume has its
# own, and each logged its target's name when it loaded; without this, the
# other volumes' lines would be counted against these steps.
echo "reading the extension's log for the past week (this can take a minute)..."
TARGET_NAME=$(sed -nE 's#^[a-z]+://[^/]+/([^/]+)/.* on .*#\1#p' <<<"$FSKIT_MOUNT")
LOADS=$(/usr/bin/log show --last 7d --style compact --predicate "subsystem == \"$SUBSYSTEM\"" 2>/dev/null \
  | grep -E "connecting to iscsid|reads: |kernel data cache: |loadResource ok")
EXT_PID=""
if [ -n "$TARGET_NAME" ]; then
  EXT_PID=$(grep -F "target=$TARGET_NAME lun=" <<<"$LOADS" | tail -1 \
    | sed -nE 's/.*iSCSIFSExtension\[([0-9]+):.*/\1/p')
fi
if [ -n "$EXT_PID" ] && ps -p "$EXT_PID" >/dev/null 2>&1; then
  PREDICATE="subsystem == \"$SUBSYSTEM\" AND processID == $EXT_PID"
  LAST_LOAD=$(grep -F "iSCSIFSExtension[$EXT_PID:" <<<"$LOADS" | tail -4)
else
  echo "WARNING: could not tell which extension process serves $VOLUME; counting all of them."
  PREDICATE="subsystem == \"$SUBSYSTEM\""
  LAST_LOAD=$(tail -4 <<<"$LOADS")
fi

# The positive control. An empty result means "no flush reached the extension"
# only if the log shows the extension at all; its load lines also say which
# cache mode this mount runs with.
{
  echo "extension:    ${EXT_PID:-unknown} (${TARGET_NAME:-target unknown})"
  echo "its load, from the log:"
  echo "${LAST_LOAD:-none in the past week}" | sed 's/^/  /'
} | tee -a "$OUT"

# The device flush needs read access to the raw device. An image the app
# attached is usually owned by the user who attached it; otherwise use sudo,
# asked for now so the prompt does not land in the middle of the run.
SUDO=""
if [ ! -r "$RAW" ]; then
  echo
  echo "sudo is needed to open $RAW for the device flush step."
  sudo -v || exit 1
  SUDO=sudo
fi

WORK="$VOLUME/.$TAG"
mkdir "$WORK" || exit 1
STREAM=$(mktemp -t "$TAG")
/usr/bin/log stream --style compact --info \
  --predicate "($PREDICATE) OR (process == \"logger\" AND eventMessage CONTAINS \"$TAG\")" \
  >"$STREAM" 2>&1 &
STREAMER=$!
disown "$STREAMER"     # no "Terminated" notice when it is stopped
cleanup() { kill "$STREAMER" 2>/dev/null; rm -rf "$WORK" "$STREAM"; }
trap cleanup EXIT
sleep 2

STEPS=()
step() {   # step <name> <command...>
  local name=$1; shift
  STEPS+=("$name")
  /usr/bin/logger "$TAG STEP $name"
  sleep 0.5
  echo
  echo "== $name" | tee -a "$OUT"
  "$@" 2>&1 | tee -a "$OUT"
  sleep "$SETTLE"
}

write_then_sync()     { "$PROBE" write "$WORK/sync.bin" "$MIB" && /bin/sync; }
write_then_devflush() { "$PROBE" write "$WORK/dev.bin" "$MIB" && $SUDO "$PROBE" devflush "$RAW"; }

step idle             sleep 2
step write            "$PROBE" write     "$WORK/write.bin" "$MIB"
step fsync            "$PROBE" fsync     "$WORK/fsync.bin" "$MIB"
step F_FULLFSYNC      "$PROBE" fullfsync "$WORK/full.bin"  "$MIB"
step sync             write_then_sync
step lun0.img-sync    "$PROBE" sync-only "$IMAGE"
step device-flush     write_then_devflush
/usr/bin/logger "$TAG STEP end"
sleep 1
kill "$STREAMER" 2>/dev/null

if ! grep -q "$TAG STEP idle" "$STREAM"; then
  echo
  echo "The log stream caught no step markers, so nothing below would mean anything."
  echo "Its output:"; cat "$STREAM"
  exit 1
fi

{
  echo
  echo "== extension log, by step"
  awk -v tag="$TAG" '
    index($0, tag " STEP ") { n = split($0, f, " "); step = f[n]; if (step != "end") print "-- " step; next }
    step != "" && step != "end" { print "   " $0 }' "$STREAM"

  echo
  echo "== counts"
  printf "%-16s %12s %12s %12s %12s\n" step SYNCHRONIZE "final CLOSE" "data CLOSE" "other"
  awk -v tag="$TAG" '
    index($0, tag " STEP ") { n = split($0, f, " "); step = f[n]; order[++k] = step; next }
    step == "" || step == "end" { next }
    /SYNCHRONIZE/ && !/TRACE/      { s[step]++; next }
    /CLOSE keeping=0[^0-9]/        { c[step]++; next }
    /CLOSE \(data cache\)/         { d[step]++; next }
    /OPEN|CLOSE|UPGRADE/           { o[step]++; next }
    END {
      for (i = 1; i <= k; i++) {
        t = order[i]; if (t == "end") continue
        printf "%-16s %12d %12d %12d %12d\n", t, s[t], c[t], d[t], o[t]
      }
    }' "$STREAM"
} | tee -a "$OUT"

# The verdict, from the counts. lun0.img-sync opens the file itself, so a
# close in that step is its own and says nothing about a flush.
SIGNALS=$(awk -v tag="$TAG" '
  index($0, tag " STEP ") { n = split($0, f, " "); step = f[n]; next }
  step == "" || step == "end" { next }
  /SYNCHRONIZE/ && !/TRACE/ { print step ": SYNCHRONIZE"; next }
  step != "lun0.img-sync" && (/CLOSE keeping=0[^0-9]/ || /CLOSE \(data cache\)/) { print step ": final close" }
' "$STREAM" | sort | uniq -c)
{
  echo
  if [ -z "$LAST_LOAD" ] && ! grep -qF "[$SUBSYSTEM" "$STREAM"; then
    echo "VERDICT: inconclusive. The extension logged nothing in the past week, so"
    echo "silence here says nothing. Is $VOLUME on a target the app attached?"
  elif [ -z "$SIGNALS" ]; then
    echo "VERDICT: no flush reached the extension. Same as macOS 26.6: there is no"
    echo "barrier signal on this stack, and writes must stay write-through."
  else
    echo "VERDICT: something reached the extension around a flush:"
    echo "$SIGNALS"
    echo "Check it is absent from the idle and write steps, then repeat the run"
    echo "before relying on it."
  fi
  echo
  echo "Full output: $OUT"
} | tee -a "$OUT"
