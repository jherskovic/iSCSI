#!/bin/bash
# vm-deploy-dext.sh — build, install, and activate the current dext + daemon on
# the SIP-off test VM, handling the reboot dance a virtual (always-matched) dext
# needs to swap versions. Run from the repo root on the host.
#
#   scripts/vm-deploy-dext.sh [vm-host]
#
# PARKED: Backend B is out of scope for the shipping v1 (FSKit only), so the
# app no longer embeds the dext — and a dext can only be activated by a host app
# that embeds it. To use this script, re-add the dependency in apps/project.yml:
#
#     targets:
#       iSCSIApp:
#         dependencies:
#           - target: iSCSIDext        # <- add these two lines back
#             embed: true
#
# ...then `cd apps && xcodegen generate`. Do NOT commit that with a release:
# the DriverKit entitlements are approval-gated, so their presence makes every
# Developer ID export fail at profile resolution. The guard below refuses to run
# rather than deploy an app with no dext inside it.
#
# Requires: ssh key auth to the VM; the VM password in $ISCSI_VM_PASS (for
# sudo reboot + keychain unlock); UTM hosting the VM if you want auto-recovery.
#
# The dance (why it looks like this):
#  - CFBundleVersion must be bumped in apps/iSCSIDext/Info.plist BEFORE this
#    script, or sysextd silently keeps the old dext running.
#  - The app must LAUNCH to request activation (OSSystemExtensionRequest).
#  - An always-matched virtual dext only actually swaps at boot, so we reboot
#    after activation; if the new version still isn't active (activation
#    landed too late pre-reboot), we relaunch + reboot once more.
set -euo pipefail

VM=${1:-herko@192.168.0.34}
PASS=${ISCSI_VM_PASS:-herko}
DD='~/Library/Developer/Xcode/DerivedData/iSCSIInitiator-*/Build/Products/Debug'

wait_for_vm() {
  until ssh -o BatchMode=yes -o ConnectTimeout=4 "$VM" true 2>/dev/null; do sleep 10; done
}

active_version() {
  ssh -o BatchMode=yes "$VM" 'systemextensionsctl list | grep "activated enabled" | head -1' \
    | sed -E 's/.*\(([^)]*)\).*/\1/'
}

# "activated enabled" only means STAGED. While a row for an older version is
# still "terminating for upgrade via delegate", that older dext is the one
# actually executing — you will deploy new code, see DEPLOY-OK, and then spend
# an hour debugging the previous build. Ask whether any stale row remains.
stale_versions() {
  ssh -o BatchMode=yes "$VM" "systemextensionsctl list | grep iSCSIDext | grep -v 'activated enabled'" \
    | sed -E 's/.*\(([^)]*)\).*/\1/' | grep -v "/$1\$" || true
}

wanted_version() {
  plutil -extract CFBundleVersion raw apps/iSCSIDext/Info.plist
}

if ! grep -q 'target: iSCSIDext' apps/project.yml; then
  cat >&2 <<'EOF'
REFUSING TO DEPLOY: apps/project.yml does not embed the dext in iSCSIApp, so the
app that would be installed contains no driver extension and activation would
silently do nothing.

Re-add it under targets.iSCSIApp.dependencies:

    - target: iSCSIDext
      embed: true

then `cd apps && xcodegen generate` and re-run. See this file's header for why
it must not be committed alongside a release build.
EOF
  exit 1
fi

echo "== sync source"
rsync -a --delete --exclude .build --exclude .git --exclude apps/build --exclude .swiftpm ./ "$VM":iSCSI/

echo "== build app (dext) + daemon on VM"
# rsync, not rm -rf + cp: replacing the bundle wholesale drops the pluginkit
# registration of the embedded FSKit extension, and the enablement entry is then
# pruned at the next boot. See docs/backend-a-fskit-notes.md:552-569.
ssh -o BatchMode=yes "$VM" "security unlock-keychain -p '$PASS' ~/Library/Keychains/login.keychain-db >/dev/null 2>&1;
  cd ~/iSCSI/apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Debug build 2>&1 | grep -E 'BUILD (SUCCEEDED|FAILED)' &&
  cd ~/iSCSI && swift build -c release 2>&1 | tail -1 &&
  mkdir -p '/Applications/iSCSI Initiator.app' &&
  rsync -a --delete $DD/'iSCSI Initiator.app'/ '/Applications/iSCSI Initiator.app'/"

WANT=$(wanted_version)
echo "== activate v$WANT + reboot"
ssh -o BatchMode=yes "$VM" "open '/Applications/iSCSI Initiator.app'; sleep 10; echo '$PASS' | sudo -S reboot" 2>/dev/null || true
sleep 20; wait_for_vm

if [[ "$(active_version)" != *"/$WANT" ]]; then
  echo "== activation landed late; relaunch + reboot again"
  ssh -o BatchMode=yes "$VM" "open '/Applications/iSCSI Initiator.app'; sleep 12; echo '$PASS' | sudo -S reboot" 2>/dev/null || true
  sleep 20; wait_for_vm
fi

[[ "$(active_version)" == *"/$WANT" ]] || { echo "DEPLOY-FAILED (staged $(active_version), wanted $WANT)"; exit 1; }

# Reboot until the previous version stops holding the driver.
for _ in 1 2 3; do
  stale=$(stale_versions "$WANT")
  [[ -z "$stale" ]] && break
  echo "== v$WANT staged but $(echo "$stale" | tr '\n' ' ')still running; rebooting"
  ssh -o BatchMode=yes "$VM" "echo '$PASS' | sudo -S reboot" >/dev/null 2>&1 || true
  sleep 25; wait_for_vm; sleep 5
done

if [[ -n "$(stale_versions "$WANT")" ]]; then echo "DEPLOY-FAILED (old version won't release)"; exit 1; fi
echo "== running: $(active_version)"
echo DEPLOY-OK
