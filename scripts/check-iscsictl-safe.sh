#!/bin/bash
# Assert that an iscsictl binary carries none of the commands that write to a
# target directly.
#
#   scripts/check-iscsictl-safe.sh <path/to/iscsictl>
#
# wipe, write-bench and verify --write reach the target straight from the CLI,
# past the daemon's one-writer check. They are for `swift run`, never for the
# bundle, and they compile only under ISCSICTL_DESTRUCTIVE, which Package.swift
# defines and the Xcode target does not.
#
# scripts/release.sh runs this on the exported app, and CI's app job on its
# unsigned build — that one is linker-signed ad hoc, which is enough to run.
# One script, so the two cannot drift apart.
set -euo pipefail

CTL="${1:?usage: check-iscsictl-safe.sh <path/to/iscsictl>}"

die() { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

[ -x "$CTL" ] || die "no executable iscsictl at $CTL"

# Not `strings | grep -q`: under pipefail, grep exits at the first match, strings
# dies on the closed pipe, the pipeline fails, and `if` reads a match as no match.
# This check was written that way, and on a binary containing the string it fired
# 0 times in 20. Reading everything first leaves no pipe to break.
binary_contains() {
    local text
    text=$(strings -a "$1")
    grep -q -e "$2" <<<"$text"
}

# Ask the tool, not `strings`: an optimized build keeps a string of up to 15
# bytes inline in the code, so a `write-bench` marker passed a binary with that
# command in it. --help on an unknown subcommand exits 0 with its parent's help,
# so each answer has to show it is the one asked for, or a rename would pass.
ctl_help() {
    local help
    help=$("$CTL" "$@" --help) || die "iscsictl $* --help failed"
    grep -q -e "USAGE: iscsictl $* " <<<"$help" \
        || die "iscsictl $* --help answered for something else. Did the command move?"
    printf '%s\n' "$help"
}

for group in iscsi nvme; do
    commands=$(ctl_help "$group")
    for command in wipe write-bench; do
        if grep -q -e "$command" <<<"$commands"; then
            die "iscsictl $group has $command, which must not be in the bundle.
It belongs behind ISCSICTL_DESTRUCTIVE, which stays out of the Xcode target."
        fi
    done
    verify=$(ctl_help "$group" verify)
    if grep -q -e "--write" <<<"$verify"; then
        die "iscsictl $group verify has --write, which must not be in the bundle.
It belongs behind ISCSICTL_DESTRUCTIVE, which stays out of the Xcode target."
    fi
done

# The compile flag itself, whatever is listed. These sit inside long strings,
# which `strings` can see.
for marker in DESTRUCTIVE "pass --write"; do
    if binary_contains "$CTL" "$marker"; then
        die "iscsictl contains \"$marker\": ISCSICTL_DESTRUCTIVE is on in this build.
It must stay out of the Xcode target."
    fi
done
echo "  ok  iscsictl has no destructive commands"
