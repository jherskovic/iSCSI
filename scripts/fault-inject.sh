#!/bin/bash
# Host-side network fault injection for iSCSI testing, using macOS dummynet
# (dnctl) + pf. Steers traffic to a target IP:port through a shaped pipe so you
# can add latency, loss, and bandwidth caps, or black-hole the link entirely.
#
# Requires sudo. Targets only the iSCSI portal you name, so the rest of your
# network is unaffected.
#
# Usage:
#   sudo scripts/fault-inject.sh latency <target-ip> <ms>
#   sudo scripts/fault-inject.sh loss    <target-ip> <percent>
#   sudo scripts/fault-inject.sh bw      <target-ip> <kbit/s>
#   sudo scripts/fault-inject.sh partition <target-ip>     # 100% loss
#   sudo scripts/fault-inject.sh clear                     # remove all rules
set -euo pipefail

ANCHOR="iscsi-fault"
PIPE=1
PORT=3260

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "must run as root (sudo)" >&2
        exit 1
    fi
}

apply_pf() {
    local ip="$1"
    # Route both directions of the iSCSI conversation into the dummynet pipe.
    cat <<EOF | pfctl -a "$ANCHOR" -f - 2>/dev/null
dummynet in  quick proto tcp from $ip port $PORT to any pipe $PIPE
dummynet out quick proto tcp from any to $ip port $PORT pipe $PIPE
EOF
    pfctl -E 2>/dev/null || true
}

clear_all() {
    dnctl pipe delete $PIPE 2>/dev/null || true
    echo | pfctl -a "$ANCHOR" -f - 2>/dev/null || true
    echo "cleared iSCSI fault-injection rules"
}

require_root
cmd="${1:-}"
case "$cmd" in
    latency)
        ip="$2"; ms="$3"
        dnctl pipe $PIPE config delay "$ms"
        apply_pf "$ip"
        echo "injecting ${ms}ms latency to $ip:$PORT"
        ;;
    loss)
        ip="$2"; pct="$3"
        # dnctl plr takes a fraction 0..1
        plr=$(echo "scale=4; $pct/100" | bc)
        dnctl pipe $PIPE config plr "$plr"
        apply_pf "$ip"
        echo "injecting ${pct}% packet loss to $ip:$PORT"
        ;;
    bw)
        ip="$2"; kbit="$3"
        dnctl pipe $PIPE config bw "${kbit}Kbit/s"
        apply_pf "$ip"
        echo "capping bandwidth to ${kbit}Kbit/s for $ip:$PORT"
        ;;
    partition)
        ip="$2"
        dnctl pipe $PIPE config plr 1
        apply_pf "$ip"
        echo "black-holing $ip:$PORT (100% loss) — run 'clear' to heal"
        ;;
    clear)
        clear_all
        ;;
    *)
        echo "usage: $0 {latency|loss|bw|partition} <ip> [value] | clear" >&2
        exit 1
        ;;
esac
