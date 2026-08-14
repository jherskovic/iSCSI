#!/bin/bash
# Build a notarized, stapled DMG of iSCSI Initiator.
#
#   scripts/release.sh                 full pipeline (needs notary credentials)
#   scripts/release.sh --skip-notarize signed DMG only — for iterating on the
#                                      pipeline itself. The output is NOT valid
#                                      for the M0-b enablement test, which is
#                                      specifically about a notarized build.
#
# Environment:
#   NOTARY_PROFILE   notarytool keychain profile name (default: iSCSINotary)
#
# Two-pass notarization is deliberate: we notarize and staple the .app first,
# then build, notarize and staple the DMG. Stapling only the DMG would leave a
# user who copies the app off the image with no stapled ticket, so the app fails
# Gatekeeper the first time they open it offline. The cost is one extra
# submission round trip; the benefit is an app that validates anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$PWD

NOTARY_PROFILE="${NOTARY_PROFILE:-iSCSINotary}"
SKIP_NOTARIZE=0
[ "${1:-}" = "--skip-notarize" ] && SKIP_NOTARIZE=1

APP_NAME="iSCSI Initiator"
SCHEME="iSCSI Initiator"
TEAM_ID="4A27X5PJP3"
PBXPROJ="apps/iSCSIInitiator.xcodeproj/project.pbxproj"

BUILD="$REPO/build"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
STAGE="$BUILD/dmg-stage"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. preflight
say "preflight"

VERSION=$(awk '/MARKETING_VERSION:/ {gsub(/"/,"",$2); print $2; exit}' apps/project.yml)
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from apps/project.yml"
echo "  version                $VERSION"

security find-identity -v -p codesigning 2>/dev/null \
    | grep -q "Developer ID Application: .*($TEAM_ID)" \
    || die "no 'Developer ID Application' identity for team $TEAM_ID in the keychain"
echo "  signing identity       Developer ID Application ($TEAM_ID)"

for t in xcodegen create-dmg; do
    command -v "$t" >/dev/null || die "$t not installed (brew install $t)"
done

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || die \
"no notarytool credentials under profile '$NOTARY_PROFILE'.

Create them once with an App Store Connect API key (Developer role or above):
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
        --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXX.p8 \\
        --key-id XXXXXXXX --issuer <issuer-uuid>

Keep the .p8 outside this repo. Or re-run with --skip-notarize to build an
unnotarized DMG for pipeline testing only."
    echo "  notary profile         $NOTARY_PROFILE"
else
    printf '\033[33m  NOTARIZATION SKIPPED — output is for pipeline testing only\033[0m\n'
fi

if [ -n "$(git status --porcelain)" ]; then
    printf '\033[33m  warning: working tree is dirty; the DMG will not match any commit\033[0m\n'
fi

# ----------------------------------------------------- 1. generate + drift gate
say "regenerating the Xcode project"

# The FSKit appex used to be embedded by a hand-patch in the .pbxproj that
# apps/project.yml did not declare, so a plain `xcodegen generate` silently
# produced an app with no filesystem module and no build error. If the pbxproj
# was clean going in and dirty coming out, project.yml and the checked-in
# project have diverged again — stop rather than ship a broken DMG.
PBX_WAS_DIRTY=0
[ -n "$(git status --porcelain -- "$PBXPROJ")" ] && PBX_WAS_DIRTY=1

( cd apps && xcodegen generate >/dev/null )

if [ "$PBX_WAS_DIRTY" -eq 1 ]; then
    printf '\033[33m  drift gate SKIPPED — %s was already modified\033[0m\n' "$PBXPROJ"
elif [ -n "$(git status --porcelain -- "$PBXPROJ")" ]; then
    git --no-pager diff --stat -- "$PBXPROJ"
    die "xcodegen changed the committed project. apps/project.yml has drifted from
$PBXPROJ. Review the diff above and commit it if it is correct."
else
    echo "  no drift"
fi

# --------------------------------------------------------------- 2/3. build it
say "archiving"
rm -rf "$ARCHIVE" "$EXPORT" "$STAGE"
mkdir -p "$BUILD"
xcodebuild -project apps/iSCSIInitiator.xcodeproj \
    -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates archive >"$BUILD/archive.log" 2>&1 \
    || { tail -40 "$BUILD/archive.log"; die "archive failed (full log: $BUILD/archive.log)"; }

# An archive containing more than one installed product gets no
# ApplicationProperties, and -exportArchive then reports only
#   exportOptionsPlist error for key "method" expected one {} but found developer-id
# which says nothing about the actual cause. Diagnose it here instead. The usual
# trigger is a helper target (a tool, a second app) missing SKIP_INSTALL=YES.
if ! plutil -extract ApplicationProperties raw -expect dictionary \
        "$ARCHIVE/Info.plist" >/dev/null 2>&1; then
    echo "  archive products:" >&2
    find "$ARCHIVE/Products" -maxdepth 3 -mindepth 1 | sed "s|$ARCHIVE/Products|    |" >&2
    die "the archive has no ApplicationProperties, so -exportArchive cannot pick a
distribution method. This usually means a helper target is being installed as a
second top-level product; set SKIP_INSTALL: YES on it so it is only embedded."
fi

say "exporting Developer ID build"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist packaging/ExportOptions-DeveloperID.plist \
    -exportPath "$EXPORT" -allowProvisioningUpdates >"$BUILD/export.log" 2>&1 \
    || { tail -40 "$BUILD/export.log"; die "export failed (full log: $BUILD/export.log)"; }

APP="$EXPORT/$APP_NAME.app"
[ -d "$APP" ] || die "expected $APP after export; found: $(ls "$EXPORT")"

# ------------------------------------------------------- 4. signature assertions
say "verifying signatures"

# Guard against R6 from the other direction: even with the drift gate above, an
# app that ships without its filesystem module cannot possibly work, so make it
# a hard failure rather than something a user discovers after downloading.
[ -d "$APP/Contents/Extensions/iSCSIFSExtension.appex" ] \
    || die "the FSKit extension is missing from $APP/Contents/Extensions/"

[ -x "$APP/Contents/MacOS/iscsid" ] \
    || die "the daemon is missing from $APP/Contents/MacOS/iscsid"

# SMAppService resolves a daemon by the *filename* of its plist, so a Label that
# disagrees with the filename registers a service that can never be looked up
# again — including by unregister(), which leaves the user with a root daemon
# they cannot remove. It is silent at build time and at register() time, and
# only shows up as "approved but nothing happens". Assert it here.
LD="$APP/Contents/Library/LaunchDaemons"
[ -d "$LD" ] || die "no $LD in the bundle — SMAppService will find nothing"
PLIST_COUNT=$(find "$LD" -name '*.plist' | wc -l | tr -d ' ')
[ "$PLIST_COUNT" -eq 1 ] \
    || die "expected exactly one LaunchDaemon plist, found $PLIST_COUNT in $LD"
DAEMON_PLIST=$(find "$LD" -name '*.plist')
DAEMON_LABEL=$(plutil -extract Label raw "$DAEMON_PLIST")
[ "$DAEMON_LABEL.plist" = "$(basename "$DAEMON_PLIST")" ] \
    || die "LaunchDaemon Label ($DAEMON_LABEL) does not match its filename
($(basename "$DAEMON_PLIST")). SMAppService looks the service up by filename."
grep -q "<key>BundleProgram</key>" "$DAEMON_PLIST" \
    || die "$(basename "$DAEMON_PLIST") does not use BundleProgram. An absolute
Program path goes stale the moment the user moves the app."
echo "  ok  LaunchDaemon $DAEMON_LABEL (one plist, label matches filename)"

# ClientAuthorization skips the XPC code-signing check under #if DEBUG. That is
# safe only for as long as Release does not define DEBUG — true today, and
# silently untrue the day someone edits SWIFT_ACTIVE_COMPILATION_CONDITIONS or
# archives with the wrong configuration. The warning text is a string literal on
# the bypass path, so its presence in the binary is a compile-time fact rather
# than an inference. A root daemon that accepts every connection must never be
# something we can ship by accident.
if strings -a "$APP/Contents/MacOS/iscsid" | grep -q "Never ship this binary"; then
    die "iscsid was built with the DEBUG XPC-authorization bypass compiled in.
It would accept a connection from any process on the machine. Archive Release."
fi
echo "  ok  iscsid has no DEBUG authorization bypass"

# The DMG filename comes from project.yml; the bundle's version comes from its
# Info.plist. Nothing tied them together, and for two releases they disagreed —
# "iSCSI Initiator-0.1.2.dmg" contained an app reporting 0.1.0, because the
# Info.plists hardcoded the version instead of substituting $(MARKETING_VERSION).
# Silent, and poisonous later: Sparkle decides whether an update is needed by
# comparing the appcast's version to the installed bundle's, so a bundle stuck at
# 0.1.0 either updates forever or never.
for pair in "$APP:app" \
            "$APP/Contents/Extensions/iSCSIFSExtension.appex:FSKit extension"; do
    bundle=${pair%:*}; label=${pair##*:}
    got=$(plutil -extract CFBundleShortVersionString raw "$bundle/Contents/Info.plist")
    [ "$got" = "$VERSION" ] \
        || die "$label reports version $got but this release is $VERSION.
Check that its Info.plist uses \$(MARKETING_VERSION) rather than a literal."
done
echo "  ok  every bundle reports version $VERSION"

check_binary() {
    local path="$1" label="$2" out
    [ -e "$path" ] || return 0
    out=$(codesign -dv --verbose=4 "$path" 2>&1)

    grep -q "flags=.*runtime" <<<"$out" \
        || die "$label: hardened runtime not enabled"
    grep -q "^Timestamp=" <<<"$out" \
        || die "$label: no secure timestamp (signed with --timestamp=none?)"
    grep -q "^TeamIdentifier=$TEAM_ID" <<<"$out" \
        || die "$label: wrong team ($(grep '^TeamIdentifier' <<<"$out"))"
    grep -q "^Authority=Developer ID Application" <<<"$out" \
        || die "$label: not signed with Developer ID Application"

    echo "  ok  $label"
}

# Every Mach-O in the bundle, not just the ones we remember to list. Frameworks
# such as Sparkle carry nested signable units (Autoupdate, Updater.app) that are
# easy to miss by hand.
while IFS= read -r f; do
    case "$(file -b "$f")" in
        *Mach-O*) check_binary "$f" "${f#"$APP"/}" ;;
    esac
done < <(find "$APP" -type f -perm +111 -not -path "*/_CodeSignature/*")

check_binary "$APP/Contents/Extensions/iSCSIFSExtension.appex" "iSCSIFSExtension.appex"
check_binary "$APP" "$APP_NAME.app"

for b in "$APP" "$APP/Contents/Extensions/iSCSIFSExtension.appex"; do
    [ -f "$b/Contents/embedded.provisionprofile" ] \
        || die "${b#"$EXPORT"/}: no embedded.provisionprofile"
done
echo "  ok  embedded provisioning profiles present"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# ------------------------------------------------------------- 5. notarize app
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    say "notarizing the app (pass 1 of 2)"
    ZIP="$BUILD/$APP_NAME-app.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "app notarization failed; inspect with: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

# ------------------------------------------------------------------- 6/7. dmg
say "building the DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# An unnotarized build gets a different filename, so it can never overwrite a
# real one. It did once: a --skip-notarize run at the same version replaced an
# already-notarized DMG, and the only reason anyone noticed was `stapler staple`
# later reporting "Record not found" — the file no longer hashed to anything
# Apple had seen. Everything downstream had spent an hour treating it as
# notarized, including an experiment whose entire point was that it was.
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    DMG="$BUILD/$APP_NAME-$VERSION-UNNOTARIZED.dmg"
else
    DMG="$BUILD/$APP_NAME-$VERSION.dmg"
fi
rm -f "$DMG"

create-dmg \
    --volname "$APP_NAME" \
    --window-size 660 400 \
    --icon "$APP_NAME.app" 170 190 \
    --app-drop-link 480 190 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" >"$BUILD/dmg.log" 2>&1 \
    || { tail -20 "$BUILD/dmg.log"; die "create-dmg failed (log: $BUILD/dmg.log)"; }

codesign --sign "Developer ID Application: Jorge Herskovic ($TEAM_ID)" \
    --timestamp "$DMG"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    say "notarizing the DMG (pass 2 of 2)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
        || die "DMG notarization failed; inspect with: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
    xcrun stapler staple "$DMG"
fi

# --------------------------------------------------------------- 8. final gate
say "verifying the artifact the user will actually download"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    xcrun stapler validate "$DMG"     | sed 's/^/  /'
    xcrun stapler validate "$APP"     | sed 's/^/  /'
    spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  /'
    spctl -a -vvv -t exec    "$APP"  2>&1 | sed 's/^/  /'

    # Validate the app *inside the image*, not just the one in export/. They are
    # different files: the DMG's copy is made with `cp -R`, and the whole point
    # of stapling the app separately is that it keeps working after a user drags
    # it off the image and opens it offline. Checking export/ cannot see a copy
    # step that lost the ticket.
    MNT=$(mktemp -d)
    hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
    if xcrun stapler validate "$MNT/$APP_NAME.app" >/dev/null 2>&1; then
        echo "  ok  the app inside the DMG is stapled too"
        hdiutil detach "$MNT" >/dev/null
    else
        hdiutil detach "$MNT" >/dev/null
        die "the app inside the DMG has no stapled ticket, even though the one in
export/ does. A user who drags it off the image and opens it offline would be
told it cannot be verified. Check how the DMG staging copy is made."
    fi
    rmdir "$MNT" 2>/dev/null || true
else
    printf '\033[33m  skipped: an unnotarized DMG cannot pass spctl or stapler\033[0m\n'
fi

say "done"
echo "  $DMG"
ls -lh "$DMG" | awk '{print "  " $5}'
echo
echo "Install it the way a user would — mount the DMG and DRAG the app to"
echo "/Applications. Copying with cp -R does not reproduce the quarantine and"
echo "translocation state that a real download produces."
