#!/bin/bash
# m0b-observe.sh — capture the FSKit enablement state in one shot.
#
#   scripts/m0b-observe.sh [label]
#
# Milestone 0-b asks one question: can a notarized Developer ID build be enabled
# in System Settings → General → Login Items & Extensions → File System
# Extensions? Answering it means comparing the same set of facts at several
# points — before touching the switch, after touching it, and after a reboot,
# on both macOS 27 and a SIP-on 26.x machine. Doing that by hand across two
# machines loses observations.
#
# Everything here is read-only. The mount probe, which needs root, is opt-in:
#
#   scripts/m0b-observe.sh after-toggle --mount
#
# Output is appended to build/m0b-<host>-<osversion>.log so a run's history
# reads as a sequence. Pass a label to say where in the sequence you are.
set -uo pipefail

cd "$(dirname "$0")/.."

LABEL="${1:-observation}"
DO_MOUNT=0
[ "${2:-}" = "--mount" ] && DO_MOUNT=1

MODULE_ID="me.herko.iSCSIInitiator.fsext"
APP="/Applications/iSCSI Initiator.app"
APPEX="$APP/Contents/Extensions/iSCSIFSExtension.appex"
SETTINGS="$HOME/Library/Group Containers/group.com.apple.fskit.settings"

OS=$(sw_vers -productVersion)
mkdir -p build
LOG="build/m0b-$(hostname -s)-$OS.log"

exec > >(tee -a "$LOG") 2>&1

hr() { printf '\n\033[1m--- %s\033[0m\n' "$*"; }
echo
echo "==================================================================="
echo "  $LABEL"
echo "  $(date '+%Y-%m-%d %H:%M:%S')   macOS $OS   $(hostname -s)"
echo "==================================================================="

hr "host"
# SIP must be ON. A SIP-off machine can self-assert entitlements, which is
# precisely the thing under test, so a pass there would mean nothing.
csrutil status
echo "developer mode: $(systemextensionsctl developer 2>/dev/null | tail -1)"

hr "installed app"
if [ ! -d "$APP" ]; then
    echo "NOT INSTALLED at $APP"
    echo "(install by mounting the DMG and DRAGGING — cp -R does not reproduce"
    echo " the quarantine state a real download produces)"
else
    echo "path:         $APP"
    case "$APP" in
        */AppTranslocation/*) echo "TRANSLOCATED — run it from /Applications instead" ;;
        *)                    echo "translocated: no" ;;
    esac
    printf 'quarantine:   '
    xattr -p com.apple.quarantine "$APP" 2>/dev/null || echo "(none)"
    printf 'version:      '
    plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null

    # Confirm we are looking at the notarized artifact and not a stale dev
    # build — the whole experiment turns on which one is installed.
    for b in "$APP" "$APPEX"; do
        echo
        echo "  $(basename "$b")"
        codesign -dv --verbose=4 "$b" 2>&1 \
            | grep -E "^(Identifier|Authority=Developer|TeamIdentifier|Timestamp|CodeDirectory)" \
            | sed 's/^/    /'
        # stapler ships with the developer tools. On the clean acceptance VM they
        # are absent, and calling xcrun there pops "install developer tools?" —
        # which would ruin the one property that makes that machine worth having.
        # Say "unknown" rather than "NO": an unstapled-looking result on a box
        # with no stapler is a false negative, and a nested appex legitimately
        # has no ticket of its own on any machine (it is covered by the outer
        # bundle's), so "NO" reads as a defect where there is none.
        printf '    stapled ticket: '
        if xcode-select -p >/dev/null 2>&1; then
            xcrun stapler validate "$b" >/dev/null 2>&1 && echo yes || echo "NO"
        else
            echo "unknown (no developer tools here — do not install them)"
        fi
    done
    echo
    printf 'gatekeeper:   '
    spctl -a -vv "$APP" 2>&1 | tail -1
fi

hr "pluginkit registration"
# If the module is not registered, "enabled" is not even a question yet.
pluginkit -m -v -p com.apple.fskit.fsmodule 2>/dev/null | sed 's/^/  /'
echo
if pluginkit -m -p com.apple.fskit.fsmodule 2>/dev/null | grep -q "$MODULE_ID"; then
    echo "  => $MODULE_ID IS registered"
else
    echo "  => $MODULE_ID is NOT registered"
fi

hr "enabledModules.plist  (the gate)"
# fskit_agent keeps an entry only if it postdates the module's current pluginkit
# registration, and prunes the rest at boot. See docs/backend-a-fskit-notes.md.
if [ -f "$SETTINGS/enabledModules.plist" ]; then
    plutil -p "$SETTINGS/enabledModules.plist" | sed 's/^/  /'
    if grep -q "$MODULE_ID" "$SETTINGS/enabledModules.plist" 2>/dev/null; then
        echo "  => OURS IS PRESENT"
    else
        echo "  => ours is ABSENT — this absence is the whole gate"
    fi
else
    echo "  no enabledModules.plist (readable?): $SETTINGS"
fi

hr "probeOrder.plist"
[ -f "$SETTINGS/probeOrder.plist" ] \
    && plutil -p "$SETTINGS/probeOrder.plist" | sed 's/^/  /' \
    || echo "  absent"

hr "can this user even write the settings container?  (M0-b.2)"
# The app-driven fallback needs to write here. This is a foreign group
# container, so TCC may deny it — and TCC denials are invisible to access(2),
# which is what `test -w` calls. A `-w` check would cheerfully report "writable"
# on a path that returns EPERM at open(). So actually create a file.
#
# Caveat worth remembering when reading these logs: a shell inherits the
# terminal's TCC grants, which are usually broader than a freshly installed
# app's. A pass here is necessary but not sufficient — the real answer comes
# from the app attempting the same write. This just rules out the easy no.
PROBE="$SETTINGS/.iscsi-write-probe"
if [ ! -d "$SETTINGS" ]; then
    echo "  container does not exist: $SETTINGS"
elif (: > "$PROBE") 2>/dev/null; then
    rm -f "$PROBE"
    echo "  wrote and removed a probe file — the fallback path is possible"
    echo "  (from THIS shell's TCC context; verify again from the app)"
else
    echo "  WRITE DENIED (errno $?) — the app-driven fallback would need"
    echo "  Full Disk Access, which becomes a step in the setup state machine"
fi

hr "recent fskit complaints"
log show --last 10m --style compact \
    --predicate 'process == "fskit_agent" OR process == "fskitd" OR subsystem == "com.apple.FSKit"' \
    2>/dev/null | tail -30 | sed 's/^/  /' || echo "  (none)"

if [ "$DO_MOUNT" -eq 1 ]; then
    hr "mount probe (needs sudo)"
    # proto mode: served from a local file inside the extension's container, so
    # this tests FSKit end-to-end with no daemon, no network and no target.
    MNT="$HOME/fsmnt"; mkdir -p "$MNT"
    echo "  sudo mount -F -t iSCSI iscsi://proto/lun0 $MNT"
    if sudo mount -F -t iSCSI iscsi://proto/lun0 "$MNT" 2>&1 | sed 's/^/    /'; then
        echo "  => MOUNTED"
        ls -la "$MNT" | sed 's/^/    /'
        sudo umount "$MNT" 2>/dev/null && echo "  (unmounted)"
    else
        echo "  => mount failed (see message above)"
    fi
fi

echo
echo "logged to $LOG"
