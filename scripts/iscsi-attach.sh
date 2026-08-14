#!/bin/bash
# Attach an iSCSI LUN as a real block device, end to end.
#
#   sudo scripts/iscsi-attach.sh <portal> <target-iqn> [lun]
#   sudo scripts/iscsi-attach.sh 192.168.0.101 iqn.me.herko...:my-target 0
#
# Three layers get set up:
#   1. the FSKit volume that serves the LUN as lun0.img
#   2. DiskImages attaching that file, producing /dev/diskN
#   3. whatever filesystem is on it, mounted normally by DiskArbitration
#
# Step 1's mount point is deliberately hidden under ~/Library/Caches. It is an
# implementation detail — the user wants the volume, not the raw LUN — and a
# visible mount containing a 40 GiB "lun0.img" invites someone to copy, back up
# or delete it. Caches is the right place: it is per-user, conventionally
# ignored by Time Machine and by the user, and nothing there is precious.
#
# Nothing is *stored* in Caches. lun0.img is a live 1:1 view of the LUN served
# by the extension, so a cache sweep cannot lose data: while the volume is
# mounted the mount point's contents are the extension's, not the directory's,
# and once unmounted the leftover directory is empty and recreated on demand.
set -uo pipefail

PORTAL="${1:?usage: iscsi-attach.sh <portal> <target-iqn> [lun]}"
TARGET="${2:?usage: iscsi-attach.sh <portal> <target-iqn> [lun]}"
LUN="${3:-0}"

# Run as root (mount -F needs it), but hide the mount in the *invoking* user's
# Caches, not root's.
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")

# One directory per target+LUN so several LUNs can be attached at once. The
# name is a hash: an IQN contains characters that are awkward in a path, and
# the directory is never meant to be read by a human anyway.
TAG=$(printf '%s|%s|%s' "$PORTAL" "$TARGET" "$LUN" | shasum -a 256 | cut -c1-16)
HIDDEN="$REAL_HOME/Library/Caches/me.herko.iSCSIInitiator/$TAG"

# Created under sudo, so hand both levels back to the user whose Caches this
# is — otherwise root-owned directories accumulate in their home and ordinary
# cleanup cannot remove them.
mkdir -p "$HIDDEN"
chown "$REAL_USER" "$(dirname "$HIDDEN")" "$HIDDEN" 2>/dev/null || true

if /sbin/mount | grep -qF " $HIDDEN "; then
    echo "already attached at $HIDDEN"
else
    echo "== serving LUN as a file (hidden at $HIDDEN)"
    if ! mount -F -t iSCSI "iscsi://$PORTAL/$TARGET/$LUN" "$HIDDEN"; then
        echo "FAILED to mount the FSKit volume." >&2
        echo "  - is iscsid running?  sudo launchctl print system/me.herko.iSCSIInitiator.daemon" >&2
        echo "  - is the module enabled? see docs/backend-a-fskit-notes.md" >&2
        exit 1
    fi
fi

IMG="$HIDDEN/lun0.img"
[ -f "$IMG" ] || { echo "no lun0.img at $IMG" >&2; exit 1; }
echo "== LUN size: $(stat -f %z "$IMG") bytes"

echo "== attaching with DiskImages"
# -noverify: there is no checksum to verify on a raw LUN, and the scan would
# read the entire device over the network before anything could be mounted.
OUT=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -noverify "$IMG" 2>&1)
rc=$?
echo "$OUT" | sed 's/^/    /'
if [ $rc -ne 0 ]; then
    echo "FAILED to attach the image." >&2
    echo "  If this says 'no mountable file systems', the LUN is blank —" >&2
    echo "  partition and format it, then re-run." >&2
    exit 1
fi

DEV=$(echo "$OUT" | awk 'NR==1{print $1}')
echo "== attached as $DEV"

# Report mount points from hdiutil's own output. Grepping /sbin/mount for $DEV
# is wrong: APFS mounts a *synthesized* container disk with a different number
# (disk8 -> disk9s1), so that check reports "not mounted" on a healthy volume.
MOUNTS=$(echo "$OUT" | awk '$3 ~ /^\// {print $3}')
if [ -n "$MOUNTS" ]; then
    echo "== mounted at:"
    echo "$MOUNTS" | sed 's/^/    /'
else
    echo "== no filesystem mounted — the LUN is blank or unformatted"
fi
echo "ATTACH-OK $DEV"
