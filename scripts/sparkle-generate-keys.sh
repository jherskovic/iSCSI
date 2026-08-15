#!/bin/bash
# Generate the Sparkle EdDSA key pair, once, for this project.
#
#   scripts/sparkle-generate-keys.sh
#
# The private key goes into your login keychain and never touches this repo or
# any build product. The public key is printed for pasting into
# apps/iSCSIApp/Info.plist, where it is compiled into the app and used to verify
# every update it downloads.
#
# Losing the private key means losing the ability to ship updates to anyone
# already running the app: they will reject anything signed with a new key, and
# the only route back is asking every user to download a fresh copy by hand.
# Back it up somewhere you would also keep a signing certificate.
set -euo pipefail

cd "$(dirname "$0")/.."

TOOL=$(find ~/Library/Developer/Xcode/DerivedData \
    -path "*/artifacts/sparkle/Sparkle/bin/generate_keys" -type f 2>/dev/null | head -1)

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
REPLACE_WITH_SPARKLE_PUBLIC_KEY under the SUPublicEDKey key.

scripts/release.sh refuses to build a notarized release until you do.
EOF
