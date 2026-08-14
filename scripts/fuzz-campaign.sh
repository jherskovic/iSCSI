#!/bin/bash
# Run a fuzzing campaign: N independent seeds, each for a bounded time, under
# AddressSanitizer.
#
#   scripts/fuzz-campaign.sh [iterations] [seconds-per-seed] [first-seed]
#
# Each seed is an independent deterministic run, so any failure reproduces
# exactly with the printed `pdu-fuzz derive <seed> <iteration>` command — which
# is the whole point of using distinct seeds rather than one long run.
#
# Exits non-zero if any seed failed, and leaves the failing output in
# fuzz-failures/ for triage.
set -uo pipefail
cd "$(dirname "$0")/.."

ITERATIONS="${1:-100}"
PER_SEED="${2:-20}"
FIRST_SEED="${3:-1}"
OUTDIR="fuzz-failures"

echo "== building pdu-fuzz with ASan"
swift build -c release --product pdu-fuzz -Xswiftc -sanitize=address >/dev/null || {
    echo "BUILD-FAILED"; exit 1;
}
BIN="$(swift build -c release --product pdu-fuzz -Xswiftc -sanitize=address --show-bin-path)/pdu-fuzz"

mkdir -p "$OUTDIR"
failures=0
start=$(date +%s)

for i in $(seq 0 $((ITERATIONS - 1))); do
    seed=$((FIRST_SEED + i))
    out="$OUTDIR/seed-$seed.log"
    if ! "$BIN" fuzz "$PER_SEED" "$seed" > "$out" 2>&1; then
        echo "FAIL seed=$seed  (see $out)"
        failures=$((failures + 1))
    else
        rm -f "$out"
    fi
    # Progress every 10 seeds; a campaign is long enough that silence is
    # indistinguishable from a hang.
    if [ $(((i + 1) % 10)) -eq 0 ]; then
        el=$(($(date +%s) - start))
        echo "  [$((i + 1))/$ITERATIONS] ${el}s elapsed, $failures failure(s)"
    fi
done

el=$(($(date +%s) - start))
echo "== campaign done: $ITERATIONS seeds x ${PER_SEED}s in ${el}s, $failures failure(s)"
[ "$failures" -eq 0 ] && { echo "FUZZ-CLEAN"; rmdir "$OUTDIR" 2>/dev/null; exit 0; }
echo "FUZZ-FAILURES"
exit 1
