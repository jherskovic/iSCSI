#!/bin/bash
# Tear down what iscsi-attach.sh set up, innermost layer first.
#
#   sudo scripts/iscsi-detach.sh <portal> <target-iqn> [lun]
#
# Order matters: unmount the filesystem, detach the disk image, then unmount
# the FSKit volume. Detaching the image while its backing file is still served
# is the only ordering that cannot deadlock, since DiskImages holds the file
# open and the extension cannot go away underneath it.
set -uo pipefail

PORTAL="${1:?usage: iscsi-detach.sh <portal> <target-iqn> [lun]}"
TARGET="${2:?usage: iscsi-detach.sh <portal> <target-iqn> [lun]}"
LUN="${3:-0}"

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")
TAG=$(printf '%s|%s|%s' "$PORTAL" "$TARGET" "$LUN" | shasum -a 256 | cut -c1-16)
HIDDEN="$REAL_HOME/Library/Caches/me.herko.iSCSIInitiator/$TAG"

IMG="$HIDDEN/lun0.img"

# Which device is backed by our image? Ask hdiutil rather than guessing, so a
# stale disk number cannot detach someone else's image.
DEV=$(hdiutil info 2>/dev/null | awk -v img="$IMG" '
    $0 ~ /^image-path/ { path = substr($0, index($0, ":") + 2) }
    path == img && $1 ~ /^\/dev\/disk[0-9]+$/ { print $1; exit }
')

if [ -n "${DEV:-}" ]; then
    echo "== unmounting filesystems on $DEV"
    diskutil unmountDisk "$DEV" 2>&1 | sed 's/^/    /' || true
    echo "== detaching $DEV"
    hdiutil detach "$DEV" 2>&1 | sed 's/^/    /' || hdiutil detach "$DEV" -force 2>&1 | sed 's/^/    /'
else
    echo "== no attached image for $IMG"
fi

if /sbin/mount | grep -qF " $HIDDEN "; then
    echo "== unmounting the FSKit volume"
    umount "$HIDDEN" 2>/dev/null || umount -f "$HIDDEN"
fi

# The directory is a mount point, never storage; removing it when empty keeps
# Caches tidy. rmdir, not rm -rf: if anything is actually in there, something
# is wrong and deleting it silently would hide that.
rmdir "$HIDDEN" 2>/dev/null || true
echo "DETACH-OK"
