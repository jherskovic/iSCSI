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
# to work. Re-run scripts/vm-install-daemon.sh (or, for Backend B,
# scripts/parked/vm-deploy-dext.sh) after restoring, or --recapture once the
# VM is at the version you want to keep returning to.
#
# Environment: VM_UUID (utmctl's id for the VM) and VM_HOST (its ssh login,
# default herko@192.168.0.34).
set -euo pipefail

VM_UUID=${VM_UUID:-6B1E9443-D808-430E-8C1A-44DDBC2C2C4F}
VM_HOST=${VM_HOST:-herko@192.168.0.34}
UTM=/Applications/UTM.app/Contents/MacOS/utmctl
LIVE="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents/macOS - throwaway.utm"
BASE="$HOME/VM-baseline/macOS-throwaway-BASELINE.utm"

die() { echo "FATAL: $*" >&2; exit 1; }

vm_status() { "$UTM" status "$VM_UUID" 2>/dev/null || echo unknown; }

FORCED=0
stop_vm() {
  echo "== stopping VM"
  "$UTM" stop "$VM_UUID" 2>/dev/null || true
  for _ in $(seq 1 24); do
    [ "$(vm_status)" = "stopped" ] && return 0
    sleep 5
  done
  echo "== graceful stop timed out; forcing"
  FORCED=1
  "$UTM" stop "$VM_UUID" --force 2>/dev/null || true
  sleep 5
}

# Neither the bundle nor the baseline is touched unless utmctl says the VM is
# stopped. A forced stop that did not take leaves a running guest writing into
# the very files about to be deleted or copied.
require_stopped() {
  local s
  s=$(vm_status)
  [ "$s" = "stopped" ] || die "the VM is '$s', not 'stopped'; refusing to touch its files.
Stop it in UTM, then re-run."
}

# cp -c clones on APFS, so a full copy is instant and free. Each copy goes to a
# temporary name next to its destination and is renamed into place only once
# it is complete, so a failed or interrupted copy never leaves the VM or the
# baseline half-written, or gone. The temporary name does not end in .utm, so
# UTM does not pick it up as a second VM.
replace_with_copy() {  # replace_with_copy <source> <destination>
  local src="$1" dst="$2" tmp="$2.copying" old="$2.replaced"
  rm -rf "$tmp" "$old"
  mkdir -p "$(dirname "$dst")"
  cp -Rc "$src" "$tmp" || { rm -rf "$tmp"; die "copying $src failed; $dst is untouched"; }
  if [ -e "$dst" ]; then
    mv "$dst" "$old"
  fi
  mv "$tmp" "$dst"
  rm -rf "$old"
}

if [ "${1:-}" = "--recapture" ]; then
  # Only ever recapture from a guest that shut down CLEANLY — a baseline taken
  # from a wedged or force-killed guest preserves exactly the damage it is
  # meant to undo.
  [ -d "$LIVE" ] || die "no VM at $LIVE to recapture from"
  stop_vm
  require_stopped
  [ "$FORCED" -eq 0 ] || die "the VM had to be force-stopped, so it did not shut down cleanly.
The baseline is unchanged. Boot it, shut it down from inside, and re-run."
  echo "== recapturing baseline from current VM"
  replace_with_copy "$LIVE" "$BASE"
  echo "== baseline updated: $BASE"
  exit 0
fi

[ -d "$BASE" ] || die "no baseline at $BASE — run with --recapture first"

stop_vm
require_stopped
echo "== restoring from baseline"
replace_with_copy "$BASE" "$LIVE"
echo "== starting VM"
"$UTM" start "$VM_UUID"
until ssh -o BatchMode=yes -o ConnectTimeout=5 "$VM_HOST" true 2>/dev/null; do sleep 10; done
echo "== VM up:"
ssh -o BatchMode=yes "$VM_HOST" "uptime; stat -f 'console=%Su' /dev/console"
echo RESTORE-OK
