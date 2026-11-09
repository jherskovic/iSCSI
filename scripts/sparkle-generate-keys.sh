#!/bin/bash
# Generate the Sparkle EdDSA key pair, once, for a checkout that has none yet.
#
#   scripts/sparkle-generate-keys.sh
#
# This project already has its key. SUPublicEDKey in apps/iSCSIApp/Info.plist
# is compiled into every copy of the app that has ever shipped, and those copies
# accept only updates signed with its private half. So this refuses to run while
# Info.plist holds a real key: a new pair cannot replace the old one, it can
# only strand everyone already running the app. The private key's backup and the
# SPARKLE_ED_PRIVATE_KEY secret are covered in docs/releasing.md.
#
# It exists for a fork, or a fresh project, whose Info.plist still carries the
# placeholder. There the private key goes into your login keychain and never
# touches the repo or any build product, and the public key is printed for
# Info.plist.
#
# Losing the private key means losing the ability to ship updates to anyone
# already running the app: they will reject anything signed with a new key, and
# the only route back is asking every user to download a fresh copy by hand.
# Back it up somewhere you would also keep a signing certificate.
set -euo pipefail

cd "$(dirname "$0")/.."

PLIST=apps/iSCSIApp/Info.plist
CURRENT=$(plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null || echo "")
if [ -n "$CURRENT" ] && [ "$CURRENT" != "REPLACE_WITH_SPARKLE_PUBLIC_KEY" ]; then
    cat >&2 <<EOF
REFUSING: $PLIST already holds a Sparkle public key:

    SUPublicEDKey = $CURRENT

Every installed copy of the app trusts that key and only that key. A new key
pair would not replace it; it would make every update signed from then on one
that installed copies refuse.

If you need the private half on this Mac, restore it from the offline backup
(generate_keys -f <file> imports one). If it is truly lost, read the
SPARKLE_ED_PRIVATE_KEY section of docs/releasing.md before doing anything else.
EOF
    exit 1
fi

# This project's DerivedData only, and the newest copy: the first match
# anywhere could be another app's Sparkle, or an older one of ours.
TOOL=$(find ~/Library/Developer/Xcode/DerivedData/iSCSIInitiator-* \
    -path "*/artifacts/sparkle/Sparkle/bin/generate_keys" -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1)

if [ -z "$TOOL" ]; then
    cat >&2 <<'EOF'
generate_keys not found.

It ships inside Sparkle's Swift package artifacts, which appear after the app
has been built at least once:

    cd apps && xcodebuild -project iSCSIInitiator.xcodeproj \
        -scheme 'iSCSI Initiator' -configuration Release \
        -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build

Then run this again.
EOF
    exit 1
fi

echo "== using $TOOL"
"$TOOL"

cat <<'EOF'

Paste the public key printed above into apps/iSCSIApp/Info.plist, replacing
REPLACE_WITH_SPARKLE_PUBLIC_KEY under the SUPublicEDKey key, and the same value
into SHIPPED_PUBLIC_ED_KEY in scripts/check-sparkle-identity.sh, which CI and
release.sh hold it to.

scripts/release.sh refuses to build a notarized release until you do.
EOF
