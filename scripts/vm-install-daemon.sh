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
# The shipping plist (apps/iSCSIApp/LaunchDaemons/) uses BundleProgram, which is
# resolved relative to the app bundle and is therefore meaningless for a loose
# binary in /usr/local/libexec. Rather than check in a second plist — the exact
# thing that let the two previous copies drift apart — synthesize the dev one
# here from the same label. It is the only difference between the two, and it is
# visible in six lines instead of buried in a parallel file.
ssh -o BatchMode=yes "$VM" "echo '$PASS' | sudo -S sh -c '
  mkdir -p /usr/local/libexec
  install -m 755 ~/iSCSI/.build/release/iscsid /usr/local/libexec/iscsid
  cat > /Library/LaunchDaemons/$LABEL.plist <<PLIST
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>/usr/local/libexec/iscsid</string>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>ProcessType</key><string>Adaptive</string>
</dict></plist>
PLIST
  chmod 644 /Library/LaunchDaemons/$LABEL.plist
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

echo "== done"
echo "   iscsid now logs through os.Logger, not /var/log/iscsid.err. On the VM:"
echo "     log show --predicate 'subsystem == \"me.herko.iSCSIInitiator\"' --last 10m"
echo "     log stream --predicate 'subsystem == \"me.herko.iSCSIInitiator\"'"
