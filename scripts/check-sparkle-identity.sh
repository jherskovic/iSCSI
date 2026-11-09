#!/bin/bash
# Assert that an Info.plist names the feed and the update key that every
# installed copy of the app already trusts.
#
#   scripts/check-sparkle-identity.sh <Info.plist>
#
# CI runs this on apps/iSCSIApp/Info.plist; scripts/release.sh on the plist of
# the app it just built. Both values are a contract with copies of the app that
# are already installed, and neither can be changed from this side:
#
# - SUFeedURL names jherskovic/iSCSI ON PURPOSE. The repository was renamed to
#   jherskovic/iSCSI-NVMe-TCP, and every shipped copy reaches the feed through
#   GitHub's redirect from the old name. "Correcting" it here changes nothing
#   for those copies. Never create a repository called jherskovic/iSCSI: that
#   ends the redirect, and every installed copy then reads its feed from
#   whatever the new repository holds.
#
# - SUPublicEDKey is the public half of the Sparkle key. A new key means every
#   installed copy rejects every update signed from then on, and the only
#   remedy is asking each user to download a fresh build by hand.
#
# A change to either belongs in a deliberate, reviewed commit that edits this
# file too, never as a side effect of something else.
set -euo pipefail

SHIPPED_FEED_URL="https://raw.githubusercontent.com/jherskovic/iSCSI/main/appcast.xml"
SHIPPED_PUBLIC_ED_KEY="uXyWZVcSiXV7mioZMJ/GJWQb2iroZFO6XsI/DM4xeYY="

PLIST="${1:?usage: check-sparkle-identity.sh <Info.plist>}"
[ -f "$PLIST" ] || { echo "FATAL: no plist at $PLIST" >&2; exit 1; }

status=0
check() {  # check <key> <expected>
    local got
    got=$(plutil -extract "$1" raw "$PLIST" 2>/dev/null || echo "")
    if [ "$got" = "$2" ]; then
        echo "  ok  $1 is $2"
    else
        echo "FATAL: $1 in $PLIST is '${got:-<missing>}', but every installed copy" >&2
        echo "       of the app trusts '$2'. See the header of $0." >&2
        status=1
    fi
}

check SUFeedURL "$SHIPPED_FEED_URL"
check SUPublicEDKey "$SHIPPED_PUBLIC_ED_KEY"
exit "$status"
