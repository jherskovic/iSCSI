#!/bin/bash
#
# install-build-tools.sh — xcodegen and create-dmg at pinned versions, each
# verified before anything runs it. CI and release both install through here.
#
#   scripts/install-build-tools.sh <dir> [xcodegen] [create-dmg]
#
# With no tool names, installs both. Each tool's directory is appended to
# $GITHUB_PATH when that is set (so later workflow steps find it) and printed.
#
# Why not `brew install`: the release job runs these with the signing
# certificates, the notary key and the Sparkle private key on the machine, and
# a Homebrew formula is whatever the tap says today. And xcodegen's output is
# what CI's drift check compares the committed .pbxproj against, so a new
# xcodegen arriving unannounced could fail every build over a project nobody
# touched. To move a pin: change the version and its hash or commit here, and
# regenerate the project with that xcodegen in the same change.

set -euo pipefail

XCODEGEN_VERSION=2.46.0
# GitHub's own sha256 digest for the release asset `xcodegen.zip`.
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
CREATE_DMG_TAG=v1.3.0
# The commit the tag names; a tag can be moved, a commit hash cannot.
CREATE_DMG_COMMIT=a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f

dest=${1:?usage: install-build-tools.sh <dir> [xcodegen] [create-dmg]}
shift
tools=("$@")
[ ${#tools[@]} -gt 0 ] || tools=(xcodegen create-dmg)
mkdir -p "$dest"

publish() {
    [ -n "${GITHUB_PATH:-}" ] && echo "$1" >> "$GITHUB_PATH"
    echo "$1"
}

for tool in "${tools[@]}"; do
    case "$tool" in
    xcodegen)
        zip="$dest/xcodegen-$XCODEGEN_VERSION.zip"
        curl -fsSL --retry 3 -o "$zip" \
            "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
        echo "$XCODEGEN_SHA256  $zip" | shasum -a 256 -c - >/dev/null \
            || { echo "xcodegen $XCODEGEN_VERSION does not match its pinned hash" >&2; exit 1; }
        rm -rf "$dest/xcodegen-$XCODEGEN_VERSION"
        unzip -q "$zip" -d "$dest/xcodegen-$XCODEGEN_VERSION"
        # Run from where it unpacked: xcodegen finds its setting presets
        # relative to its own binary.
        bin=$(find "$dest/xcodegen-$XCODEGEN_VERSION" -type f -name xcodegen -perm -100 | head -1)
        [ -n "$bin" ] || { echo "no xcodegen binary in the $XCODEGEN_VERSION release" >&2; exit 1; }
        publish "$(dirname "$bin")"
        ;;
    create-dmg)
        dir="$dest/create-dmg"
        rm -rf "$dir"
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$CREATE_DMG_TAG" \
            https://github.com/create-dmg/create-dmg "$dir"
        got=$(git -C "$dir" rev-parse HEAD)
        [ "$got" = "$CREATE_DMG_COMMIT" ] \
            || { echo "create-dmg $CREATE_DMG_TAG is $got, pinned $CREATE_DMG_COMMIT" >&2; exit 1; }
        # The script finds its support/ directory beside itself.
        publish "$dir"
        ;;
    *)
        echo "unknown tool: $tool" >&2
        exit 2
        ;;
    esac
done
