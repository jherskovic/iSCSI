#!/bin/bash
# vm-sim-bench.sh — raw iSCSI throughput against the local simulator.
#
# Every previous measurement was bounded by the LAN: reads plateaued at ~98
# MB/s and that was the transport, not us. Over loopback against a RAM-backed
# LUN there is no transport ceiling, so what is left is our own per-command
# cost — and the target's negotiation parameters are finally ours to change.
#
# Three questions:
#   1. What does the stack cost per command once the network is gone?
#   2. What does FUA cost when the target commits instantly (i.e. the pure
#      round-trip cost of write-through, with no ZIL behind it)?
#   3. Does raising FirstBurstLength help? The NAS caps it at 64 KiB, so a
#      1 MiB write sends 64 KiB unsolicited and then waits for an R2T for the
#      rest. That was Strategy 5 in write-performance-strategies.md and it was
#      untestable, because it is the target's setting.
#
# Usage (on the VM): scripts/vm-sim-bench.sh
set -uo pipefail
cd ~/iSCSI || exit 1

SIM=.build/release/iscsi-target-sim
CTL=.build/release/iscsictl
IQN=iqn.2026-08.me.herko.sim:lun0
PORT=3260
CTLPORT=3262
MB=${MB:-1024}
CAP=${CAP:-2048}

cleanup() { pkill -f iscsi-target-sim 2>/dev/null; }
trap cleanup EXIT

for FB in 65536 262144 1048576; do
  pkill -f iscsi-target-sim 2>/dev/null; sleep 1
  # RAM backing on purpose: a file-backed LUN would measure the VM's disk.
  "$SIM" --port "$PORT" --control-port "$CTLPORT" --block-size 4096 \
         --capacity-mib "$CAP" --first-burst "$FB" \
         >/Users/herko/logs/simbench.log 2>&1 &
  for _ in $(seq 1 20); do
    [ "$(printf 'ping\n' | nc -w 5 127.0.0.1 $CTLPORT 2>/dev/null)" = ok ] && break
    sleep 1
  done

  echo "================ FirstBurstLength = $FB"
  echo "---- write, no FUA"
  "$CTL" write-bench 127.0.0.1 --target "$IQN" --megabytes "$MB" --chunk 1048576 2>&1 | sed 's/^/  /'
  echo "---- write, FUA (what the shipping daemon does)"
  "$CTL" write-bench 127.0.0.1 --target "$IQN" --megabytes "$MB" --chunk 1048576 --fua 2>&1 | sed 's/^/  /'
  echo "---- read"
  "$CTL" read-bench 127.0.0.1 --target "$IQN" --megabytes "$MB" --chunk 1048576 2>&1 | sed 's/^/  /'
  echo
done
