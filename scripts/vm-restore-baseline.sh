#!/bin/bash
# vm-restore-baseline.sh — restore the test VM from its clean baseline clone.
#
# Run on the HOST. UTM cannot snapshot this VM (macOS guests use the Apple
# Virtualization backend, and `utmctl` has no snapshot subcommand), so the
# baseline is an APFS copy-on-write clone of the whole .utm bundle taken while
# the guest was cleanly shut down. Cloning and restoring are both effectively
# instant and cost no extra disk until the two copies diverge.
#
# Why this exists: reproducing the hang wedges the guest every time, and the
# only recovery is a forced power-off. Dozens of those risk corrupting guest
# state for real — and a forced power-off is the most likely explanation for
# any future "the VM stopped auto-logging in" surprise.
#
#   scripts/vm-restore-baseline.sh              # restore VM from baseline
#   scripts/vm-restore-baseline.sh --recapture  # replace baseline with current
#
# WARNING: restoring rolls back the WHOLE guest disk, which includes the
# deployed dext, the built binaries and the synced source tree. After a restore
# the VM runs whatever version the baseline was captured at — not what you last
# deployed. The symptom is subtle and confusing: a brand-new iscsictl
# subcommand reports "Unknown option", or a fix you just deployed appears not
# to work. Re-run scripts/vm-deploy.sh after restoring, or --recapture once the
# VM is at the version you want to keep returning to.
set -euo pipefail

VM_UUID=${VM_UUID:-6B1E9443-D808-430E-8C1A-44DDBC2C2C4F}
UTM=/Applications/UTM.app/Contents/MacOS/utmctl
LIVE="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents/macOS - throwaway.utm"
BASE="$HOME/VM-baseline/macOS-throwaway-BASELINE.utm"

stop_vm() {
  echo "== stopping VM"
  "$UTM" stop "$VM_UUID" 2>/dev/null || true
  for _ in $(seq 1 24); do
    [ "$("$UTM" status "$VM_UUID" 2>/dev/null || echo unknown)" = "stopped" ] && return 0
    sleep 5
  done
  echo "== graceful stop timed out; forcing"
  "$UTM" stop "$VM_UUID" --force 2>/dev/null || true
  sleep 5
}

if [ "${1:-}" = "--recapture" ]; then
  # Only ever recapture from a guest that shut down CLEANLY — a baseline taken
  # from a wedged or force-killed guest preserves exactly the damage it is
  # meant to undo.
  stop_vm
  echo "== recapturing baseline from current VM"
  rm -rf "$BASE"
  mkdir -p "$(dirname "$BASE")"
  cp -Rc "$LIVE" "$BASE"
  echo "== baseline updated: $BASE"
  exit 0
fi

[ -d "$BASE" ] || { echo "no baseline at $BASE — run with --recapture first"; exit 1; }

stop_vm
echo "== restoring from baseline"
rm -rf "$LIVE"
cp -Rc "$BASE" "$LIVE"
echo "== starting VM"
"$UTM" start "$VM_UUID"
until ssh -o BatchMode=yes -o ConnectTimeout=5 herko@192.168.0.34 true 2>/dev/null; do sleep 10; done
echo "== VM up:"
ssh -o BatchMode=yes herko@192.168.0.34 "uptime; stat -f 'console=%Su' /dev/console"
echo RESTORE-OK
