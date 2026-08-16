#!/bin/bash
# Build a notarized, stapled DMG of iSCSI Initiator.
#
#   scripts/release.sh                 full pipeline (needs notary credentials)
#   scripts/release.sh --publish       …and create the GitHub release from it
#   scripts/release.sh --skip-notarize signed DMG only — for iterating on THIS
#                                      SCRIPT and nothing else.
#
# Never install --skip-notarize output on a test machine. macOS behaves
# differently around notarization, so results from an unnotarized build do not
# predict the shipping one, and a build that is not what you think it is costs
# far more than the ten minutes the notary takes. Its output is named
# ...-UNNOTARIZED.dmg so it cannot be mistaken for or overwrite a real release.
#
# Environment — interactive Mac (the default):
#   NOTARY_PROFILE     notarytool keychain profile name (default: iSCSINotary)
#                      and the Sparkle key is read from the login keychain.
#
# Environment — a CI runner, which has no keychain profile and nobody to unlock
# anything. Setting ASC_KEY_PATH switches every credential over at once:
#   ASC_KEY_PATH       App Store Connect API key (.p8), for notarytool. Setting
#                      it also switches the export to resolve provisioning
#                      profiles from disk rather than the portal — see the long
#                      note at the credential switch below. The FSKit-entitled
#                      profiles come from packaging/profiles/, not from Apple.
#   ASC_KEY_ID         its key ID
#   ASC_ISSUER_ID      its issuer UUID
#   SPARKLE_ED_KEY_FILE  Sparkle's EdDSA private key, exported with
#                        `generate_keys -x`. Without it, sign_update looks in
#                        the keychain and finds nothing.
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
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --publish)       PUBLISH=1 ;;
        *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done
[ "$SKIP_NOTARIZE" -eq 1 ] && [ "$PUBLISH" -eq 1 ] && {
    echo "--publish and --skip-notarize are mutually exclusive: publishing an" >&2
    echo "unnotarized build would ship Gatekeeper failures to every downloader." >&2
    exit 2
}

APP_NAME="iSCSI Initiator"
SCHEME="iSCSI Initiator"
TEAM_ID="4A27X5PJP3"
GH_REPO="jherskovic/iSCSI"
MIN_SYSTEM="26.0"
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

if [ "$PUBLISH" -eq 1 ]; then
    command -v gh >/dev/null || die "gh not installed (brew install gh), needed by --publish"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"
    gh release view "v$VERSION" >/dev/null 2>&1 && die \
"a release v$VERSION already exists. Bump MARKETING_VERSION in apps/project.yml,
or delete the release first if you are re-cutting it deliberately. Overwriting a
published asset would break Sparkle for anyone who has already downloaded it:
the appcast signature covers the bytes, and the bytes would change."
    echo "  publish                v$VERSION (does not exist yet)"
fi

# An App Store Connect API key authenticates the notary submission and lets
# xcodebuild talk to the portal without an Apple ID signed into Xcode.
#
# What it cannot do is create a Developer ID provisioning profile. Measured on a
# runner, 2026-08-16:
#
#     error: exportArchive Team "Jorge Herskovic" does not have permission to
#            create "Developer ID" provisioning profiles.
#     error: exportArchive No profiles for 'me.herko.iSCSIInitiator.fsext' were found
#
# Nothing about the key is wrong; the portal will not mint that profile type for
# an API key at all. So on CI the export is run with profile creation FORBIDDEN
# and resolves from the profiles in packaging/profiles/ instead, which the
# workflow installs before this runs. Verified locally: the same export with
# -allowProvisioningUpdates removed succeeds against on-disk profiles alone.
#
# Manual signing is not the alternative — the profiles are Xcode-managed, and
# `signingStyle: manual` refuses those outright:
#
#     error: ... is Xcode managed, but signing settings require a manually
#            managed profile.
#
# `${ARRAY[@]+"${ARRAY[@]}"}` rather than `"${ARRAY[@]}"`: macOS ships bash 3.2,
# where expanding an empty array under `set -u` is an unbound-variable error.
XCODE_AUTH=()
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
if [ -n "${ASC_KEY_PATH:-}" ]; then
    [ -f "$ASC_KEY_PATH" ] || die "ASC_KEY_PATH is set but $ASC_KEY_PATH does not exist"
    [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] \
        || die "ASC_KEY_PATH is set, so ASC_KEY_ID and ASC_ISSUER_ID must be too"
    XCODE_AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
                -authenticationKeyID "$ASC_KEY_ID"
                -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
    echo "  credentials            App Store Connect API key $ASC_KEY_ID"
fi

# On a Mac, let the export refresh profiles as needed — that is what regenerates
# them when entitlements change. On CI, pass nothing: both the flag and the auth
# keys exist only to power a mint attempt that is guaranteed to fail, and their
# absence is what makes Xcode use what is already on disk.
if [ -n "${ASC_KEY_PATH:-}" ]; then
    EXPORT_AUTH=()
    echo "  export signing         from installed profiles (no portal calls)"
else
    EXPORT_AUTH=(-allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"})
fi

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 || die \
"no usable notary credentials.

On a Mac, store them once with an App Store Connect API key (Developer role or
above):
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
        --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXX.p8 \\
        --key-id XXXXXXXX --issuer <issuer-uuid>

In CI, set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID instead.

Keep the .p8 outside this repo. Or re-run with --skip-notarize to build an
unnotarized DMG for pipeline testing only."
    [ -n "${ASC_KEY_PATH:-}" ] || echo "  notary profile         $NOTARY_PROFILE"
else
    printf '\033[33m  NOTARIZATION SKIPPED — output is for pipeline testing only\033[0m\n'
fi

# Sparkle's EdDSA key. The public half is compiled into the app; the private
# half lives in the login keychain of whoever cuts releases. Shipping the
# placeholder would produce an app that downloads updates it cannot verify —
# which Sparkle refuses to install, so the failure lands on users as an updater
# that silently never works.
SU_KEY=$(plutil -extract SUPublicEDKey raw apps/iSCSIApp/Info.plist 2>/dev/null || echo "")
if [ "$SU_KEY" = "REPLACE_WITH_SPARKLE_PUBLIC_KEY" ] || [ -z "$SU_KEY" ]; then
    if [ "$SKIP_NOTARIZE" -eq 1 ]; then
        printf '\033[33m  warning: Sparkle public key not set; updates will not work\033[0m\n'
    else
        die "SUPublicEDKey in apps/iSCSIApp/Info.plist is still the placeholder.

Generate the key pair once — the private half goes into your login keychain and
never touches this repo:

    ./scripts/sparkle-generate-keys.sh

Then paste the public key it prints into apps/iSCSIApp/Info.plist."
    fi
else
    echo "  sparkle key            ${SU_KEY:0:12}…"
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
    -allowProvisioningUpdates ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} \
    archive >"$BUILD/archive.log" 2>&1 \
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
    -exportPath "$EXPORT" \
    ${EXPORT_AUTH[@]+"${EXPORT_AUTH[@]}"} >"$BUILD/export.log" 2>&1 \
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
    xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait \
        || die "app notarization failed; inspect the rejection with:
    xcrun notarytool log <submission-id> <the same credentials>"
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
#
# The filename has no space in it, and that is not cosmetic. GitHub rewrites
# spaces in release asset names to periods, so "iSCSI Initiator-0.3.2.dmg"
# uploads and is then served as "iSCSI.Initiator-0.3.2.dmg" — while the appcast
# points at the %20 spelling and gets a 404. Sparkle surfaces that as a failed
# download with no indication of why, and it survives every check that looks at
# the file rather than the URL. Not encoding GitHub's sanitisation rule here:
# just never giving it anything to sanitise. The volume name below, and the app
# inside, keep the space.
DMG_BASE="iSCSI-Initiator-$VERSION"
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    DMG="$BUILD/$DMG_BASE-UNNOTARIZED.dmg"
else
    DMG="$BUILD/$DMG_BASE.dmg"
fi
rm -f "$DMG"

# create-dmg drives Finder over AppleScript to place the icons, which fails
# intermittently on a machine nobody is sitting at — the runner's window server
# is there, but slow to answer, and the failure is "Could not access the disk
# image" rather than anything about windows. Retry before giving up.
dmg_attempt=0
until create-dmg \
        --volname "$APP_NAME" \
        --window-size 660 400 \
        --icon "$APP_NAME.app" 170 190 \
        --app-drop-link 480 190 \
        --hide-extension "$APP_NAME.app" \
        --no-internet-enable \
        "$DMG" "$STAGE" >"$BUILD/dmg.log" 2>&1
do
    dmg_attempt=$((dmg_attempt + 1))
    rm -f "$DMG"
    [ "$dmg_attempt" -ge 3 ] && { tail -20 "$BUILD/dmg.log"; die "create-dmg failed 3 times (log: $BUILD/dmg.log)"; }
    printf '\033[33m  create-dmg failed, retrying (%d/3)\033[0m\n' "$dmg_attempt"
    sleep 5
done

codesign --sign "Developer ID Application: Jorge Herskovic ($TEAM_ID)" \
    --timestamp "$DMG"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    say "notarizing the DMG (pass 2 of 2)"
    xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait \
        || die "DMG notarization failed; inspect the rejection with:
    xcrun notarytool log <submission-id> <the same credentials>"
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
    # LaunchServices registers the app inside a mounted image, and detaching
    # does NOT unregister it. Left alone, every release run adds another bundle
    # claiming FSShortName "iSCSI", until `mount -F` cannot resolve the name at
    # all and reports it as "not found". Fourteen accumulated on the author's
    # Mac before anyone noticed.
    LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$LSREG" ] && "$LSREG" -u "$MNT/$APP_NAME.app" >/dev/null 2>&1 || true

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

# ------------------------------------------------------- 9. sign for Sparkle
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    say "signing for Sparkle"

    SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
    if [ -z "$SIGN_UPDATE" ]; then
        SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData \
            -path "*/artifacts/sparkle/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)
    fi
    [ -n "$SIGN_UPDATE" ] || die "sign_update not found. It ships in Sparkle's package
artifacts, which appear once the app has been built at least once. Override the
search with SPARKLE_SIGN_UPDATE=/path/to/sign_update."

    # With no key file, sign_update reads the private key from the login
    # keychain — right on a Mac, impossible on a runner, where the key arrives
    # as a file instead.
    SIGN_KEY=()
    if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
        [ -f "$SPARKLE_ED_KEY_FILE" ] \
            || die "SPARKLE_ED_KEY_FILE is set but $SPARKLE_ED_KEY_FILE does not exist"
        SIGN_KEY=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
    fi

    # Signed AFTER notarization and stapling, never before. Stapling rewrites the
    # DMG, so a signature taken earlier describes a file that no longer exists —
    # and Sparkle would reject the very build we just shipped.
    SIGNED=$("$SIGN_UPDATE" ${SIGN_KEY[@]+"${SIGN_KEY[@]}"} "$DMG")
    # sign_update prints  sparkle:edSignature="..." length="..."  — note that
    # only the signature carries the namespace prefix. Matching both spellings
    # of length, because that asymmetry is not something to rely on.
    ED_SIG=$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNED")
    ED_LEN=$(sed -n 's/.*[ :]length="\([0-9]*\)".*/\1/p' <<<"$SIGNED")
    [ -n "$ED_SIG" ] && [ -n "$ED_LEN" ] || die "could not read a signature out of: $SIGNED"
    echo "  ok  signed, $ED_LEN bytes"

    BUILD_NUMBER=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
    ASSET_URL="https://github.com/$GH_REPO/releases/download/v$VERSION/$(basename "$DMG")"

    # ------------------------------------------------- 10. publish, then verify
    #
    # Publishing comes BEFORE the appcast is written, and the order is the whole
    # point. The feed is a promise that a file exists at a URL; making the
    # promise first is how this repo ended up advertising three downloads that
    # GitHub had never heard of. Anything that goes wrong below leaves a
    # published release and no feed entry, which is invisible to users — the
    # reverse is a failed download for everyone.
    if [ "$PUBLISH" -eq 1 ]; then
        say "publishing v$VERSION"
        NOTES=$(mktemp)
        if [ -f "docs/release-notes/$VERSION.md" ]; then
            cat "docs/release-notes/$VERSION.md" >"$NOTES"
            gh release create "v$VERSION" --title "$VERSION" \
                --notes-file "$NOTES" "$DMG" >/dev/null
        else
            # No hand-written notes: let GitHub assemble them from the commits.
            gh release create "v$VERSION" --title "$VERSION" \
                --generate-notes "$DMG" >/dev/null
        fi
        rm -f "$NOTES"
        echo "  https://github.com/$GH_REPO/releases/tag/v$VERSION"

        # The gate that would have caught the %20 bug. A signature is over bytes;
        # an appcast entry is over a URL. Check that the URL actually serves
        # those bytes before promising it does. GitHub's CDN can take a moment
        # to make a fresh asset addressable, hence the retries.
        say "verifying the URL the appcast is about to promise"
        SERVED=""
        for attempt in 1 2 3 4 5; do
            SERVED=$(curl -sIL "$ASSET_URL" \
                | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub(/\r/,""); v=$2} END{print v}')
            [ "$SERVED" = "$ED_LEN" ] && break
            sleep 5
        done
        [ "$SERVED" = "$ED_LEN" ] || die "$ASSET_URL serves ${SERVED:-nothing} bytes, but the
signature in the appcast covers $ED_LEN. Sparkle would download that file and
reject it — or fail outright on a 404 — and would say nothing useful about why.
The release is published; the feed has NOT been updated, so no user sees this."
        echo "  ok  $ASSET_URL serves $SERVED bytes"
    fi

    # Everything needed to write the feed entry, as data. CI builds from a tag
    # but the feed lives on main, so it cannot just commit the appcast.xml this
    # script edited — it has to re-apply the same entry to main's copy. Writing
    # the values down is also how a failed run can be finished by hand without
    # rebuilding, since the signature is over bytes that already exist.
    cat >"$BUILD/release-metadata.env" <<EOF
VERSION='$VERSION'
BUILD_NUMBER='$BUILD_NUMBER'
ED_SIGNATURE='$ED_SIG'
ED_LENGTH='$ED_LEN'
ASSET_URL='$ASSET_URL'
MIN_SYSTEM='$MIN_SYSTEM'
EOF

    say "updating the appcast"
    scripts/update-appcast.py \
        --version "$VERSION" --build "$BUILD_NUMBER" \
        --signature "$ED_SIG" --length "$ED_LEN" --url "$ASSET_URL" \
        --min-system "$MIN_SYSTEM"
fi

say "done"
echo "  $DMG"
ls -lh "$DMG" | awk '{print "  " $5}'
echo
if [ "$SKIP_NOTARIZE" -eq 0 ] && [ "$PUBLISH" -eq 0 ]; then
    echo "The appcast now points at a URL that does not exist yet. Publish before"
    echo "committing it, or re-run with --publish to do both in the right order:"
    echo
    echo "    gh release create v$VERSION --title $VERSION --generate-notes \"$DMG\""
    echo "    git commit -m 'Release $VERSION' appcast.xml"
    echo
fi
echo "Install it the way a user would — mount the DMG and DRAG the app to"
echo "/Applications. Copying with cp -R does not reproduce the quarantine and"
echo "translocation state that a real download produces."
