#!/bin/bash
# Host-side network fault injection for iSCSI and NVMe/TCP testing, using macOS
# dummynet (dnctl) + pf. Steers traffic to a target IP's iSCSI (3260) and
# NVMe/TCP (4420) ports through a shaped pipe so you can add latency, loss, and
# bandwidth caps, or black-hole the link entirely.
#
# Requires sudo. Targets only the portal you name, so the rest of your network
# is unaffected.
#
# Usage:
#   sudo scripts/fault-inject.sh latency <target-ip> <ms>
#   sudo scripts/fault-inject.sh loss    <target-ip> <percent>
#   sudo scripts/fault-inject.sh bw      <target-ip> <kbit/s>
#   sudo scripts/fault-inject.sh partition <target-ip>     # 100% loss
#   sudo scripts/fault-inject.sh clear                     # remove all rules
set -euo pipefail

# Under com.apple, because that is the anchor point the stock /etc/pf.conf
# evaluates: its `dummynet-anchor "com.apple/*"` steps into every anchor below
# com.apple, including one created later. The top-level anchor this used to
# load, "iscsi-fault", was referenced by nothing in the main ruleset, so pf
# never looked at it and nothing was injected, while every command reported
# success because pfctl's stderr went to /dev/null. Referencing a new anchor
# from the main ruleset would mean reloading that ruleset, which drops the
# anchors system services insert into it at runtime (see the warning at the top
# of /etc/pf.conf); a child of com.apple needs no reload at all.
#
# Not run as part of any automated check (it needs root): if `partition` ever
# leaves a login working, look at `sudo pfctl -a com.apple -s Anchors` first.
ANCHOR="com.apple/iscsi-fault"
PIPE=1
PORTS="{ 3260, 4420 }"     # iSCSI, NVMe/TCP
# pf counts enable references (pfctl -E), and each holder releases its own
# (pfctl -X <token>), so pf goes back to disabled only if nothing else wants it.
# The tokens this script took are kept here for `clear`.
TOKENS=/var/run/iscsi-fault.pf-tokens

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "must run as root (sudo)" >&2
        exit 1
    fi
}

# The address goes into a pf rule verbatim, so it must be an address and
# nothing else (an IPv4 or IPv6 literal; no names, no spaces, no braces).
valid_ip() {
    case "$1" in
        ''|*[!0-9A-Fa-f.:]*) echo "not an IP address: '$1'" >&2; exit 1 ;;
    esac
}

apply_pf() {
    local ip="$1" out token
    # Both directions of the conversation go through the one pipe.
    pfctl -a "$ANCHOR" -f - <<EOF
dummynet in  quick proto tcp from $ip port $PORTS to any pipe $PIPE
dummynet out quick proto tcp from any to $ip port $PORTS pipe $PIPE
EOF
    out=$(pfctl -E 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
    token=$(awk '/^Token/ {print $NF}' <<<"$out")
    if [ -n "$token" ]; then
        echo "$token" >>"$TOKENS"
    else
        printf 'warning: pfctl -E gave no token; clear cannot release it:\n%s\n' "$out" >&2
    fi
}

clear_all() {
    # Best effort: deleting a pipe that is not there is not worth an error.
    dnctl pipe delete $PIPE 2>/dev/null || true
    echo | pfctl -a "$ANCHOR" -f -
    if [ -f "$TOKENS" ]; then
        while read -r token; do
            [ -n "$token" ] || continue
            pfctl -X "$token" || true
        done <"$TOKENS"
        rm -f "$TOKENS"
    fi
    echo "cleared fault-injection rules"
}

require_root
cmd="${1:-}"
case "$cmd" in
    latency)
        ip="${2:?usage: latency <ip> <ms>}"; ms="${3:?usage: latency <ip> <ms>}"
        valid_ip "$ip"
        dnctl pipe $PIPE config delay "$ms"
        apply_pf "$ip"
        echo "injecting ${ms}ms latency to $ip ports 3260 and 4420"
        ;;
    loss)
        ip="${2:?usage: loss <ip> <percent>}"; pct="${3:?usage: loss <ip> <percent>}"
        valid_ip "$ip"
        # dnctl plr takes a fraction 0..1
        plr=$(echo "scale=4; $pct/100" | bc)
        dnctl pipe $PIPE config plr "$plr"
        apply_pf "$ip"
        echo "injecting ${pct}% packet loss to $ip ports 3260 and 4420"
        ;;
    bw)
        ip="${2:?usage: bw <ip> <kbit/s>}"; kbit="${3:?usage: bw <ip> <kbit/s>}"
        valid_ip "$ip"
        dnctl pipe $PIPE config bw "${kbit}Kbit/s"
        apply_pf "$ip"
        echo "capping bandwidth to ${kbit}Kbit/s for $ip ports 3260 and 4420"
        ;;
    partition)
        ip="${2:?usage: partition <ip>}"
        valid_ip "$ip"
        dnctl pipe $PIPE config plr 1
        apply_pf "$ip"
        echo "black-holing $ip ports 3260 and 4420 (100% loss) — run 'clear' to heal"
        ;;
    clear)
        clear_all
        ;;
    *)
        echo "usage: $0 {latency|loss|bw|partition} <ip> [value] | clear" >&2
        exit 1
        ;;
esac
