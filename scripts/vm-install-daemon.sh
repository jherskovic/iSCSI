#!/bin/bash
# vm-install-daemon.sh — build iscsid and install it as a LaunchDaemon on the VM.
# Run from the repo root on the host.
#
#   scripts/vm-install-daemon.sh [vm-host]
#
# The daemon vends its XPC service with NSXPCListener(machServiceName:), which
# requires launchd to own the Mach service name — running the binary from a
# shell leaves the listener with nothing to attach to, and every client gets
# "Couldn't communicate with a helper application".
set -euo pipefail

VM=${1:-herko@192.168.0.34}
PASS=${ISCSI_VM_PASS:-herko}
LABEL=me.herko.iSCSIInitiator.daemon

echo "== sync source"
rsync -a --delete --exclude .build --exclude .git --exclude apps/build --exclude .swiftpm ./ "$VM":iSCSI/

echo "== build iscsid (release)"
ssh -o BatchMode=yes "$VM" "cd ~/iSCSI && swift build -c release --product iscsid 2>&1 | tail -2"

echo "== install binary + plist"
ssh -o BatchMode=yes "$VM" "echo '$PASS' | sudo -S sh -c '
  mkdir -p /usr/local/libexec
  install -m 755 ~/iSCSI/.build/release/iscsid /usr/local/libexec/iscsid
  install -m 644 ~/iSCSI/packaging/$LABEL.plist /Library/LaunchDaemons/$LABEL.plist
  chown root:wheel /Library/LaunchDaemons/$LABEL.plist
'"

echo "== (re)load the service"
# bootout first so a rebuild actually replaces the running daemon; ignore the
# error when it was not loaded.
ssh -o BatchMode=yes "$VM" "echo '$PASS' | sudo -S sh -c '
  launchctl bootout system/$LABEL 2>/dev/null || true
  launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist
  sleep 1
  launchctl print system/$LABEL | head -12
'"

echo "== done; log at /var/log/iscsid.err on the VM"
