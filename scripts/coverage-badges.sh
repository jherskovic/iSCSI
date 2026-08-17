#!/bin/bash
# Turn the leftovers of `swift test --enable-code-coverage` into two
# shields.io endpoint documents: a test count and a line-coverage percentage.
#
# Usage: scripts/coverage-badges.sh <test-log> <output-dir>
#   swift test --no-parallel --enable-code-coverage 2>&1 | tee /tmp/test.log
#   scripts/coverage-badges.sh /tmp/test.log /tmp/badges
#
# .github/workflows/ci.yml force-pushes the output onto the `badges` branch,
# which README.md points shields.io at. Nothing here talks to a third-party
# coverage service, so there is no account and no secret to keep alive.
set -euo pipefail

LOG="${1:?usage: coverage-badges.sh <test-log> <output-dir>}"
OUT="${2:?usage: coverage-badges.sh <test-log> <output-dir>}"
# Resolved before the cd below, so a relative argument still means what the
# caller meant.
LOG=$(cd "$(dirname "$LOG")" && pwd)/$(basename "$LOG")
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

cd "$(dirname "$0")/.."

BIN=$(swift build --show-bin-path)
PROFDATA="$BIN/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
    echo "no profile data at $PROFDATA — was swift test run with --enable-code-coverage?" >&2
    exit 1
fi

# llvm-cov wants every instrumented binary that contributed to the merged
# profile. There are two test bundles and the export silently reports only the
# first one's translation units if the second is omitted — which reads as a
# plausible coverage number rather than as an error.
objects=()
for bundle in "$BIN"/*.xctest; do
    [ -d "$bundle" ] || continue
    objects+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
done
if [ ${#objects[@]} -eq 0 ]; then
    echo "no .xctest bundles under $BIN" >&2
    exit 1
fi
# Worth printing: locally SwiftPM builds one bundle per test target, and on the
# CI runner it builds a single merged one. Both are correct and neither is
# obvious from the numbers below.
echo "covering: $(printf '%s\n' "${objects[@]}" | grep -v '^-object$' | xargs -n1 basename | tr '\n' ' ')"

SUMMARY=$(mktemp)
trap 'rm -f "$SUMMARY"' EXIT

# The tests themselves are instrumented too, and counting them would inflate
# the number by a few points while measuring nothing: test code is covered by
# definition.
xcrun llvm-cov export \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex='(^|/)(Tests|\.build|checkouts)/' \
    -summary-only \
    "${objects[@]}" > "$SUMMARY"

python3 - "$SUMMARY" "$LOG" "$OUT" <<'PY'
import json
import pathlib
import re
import sys

summary_path, log_path, out_dir = sys.argv[1:4]

lines = json.loads(pathlib.Path(summary_path).read_text())["data"][0]["totals"]["lines"]
percent = lines["percent"]

# swift-testing prints one summary per test bundle — one line on CI's merged
# bundle, two locally — so the total is a sum and not a last-line read.
log = pathlib.Path(log_path).read_text(errors="replace")
counts = [int(n) for n in re.findall(r"Test run with (\d+) test", log)]
if not counts:
    sys.exit(f"found no 'Test run with N tests' line in {log_path}; refusing to publish a made-up count")
total = sum(counts)


def color(pct):
    for threshold, name in ((90, "brightgreen"), (80, "green"), (70, "yellowgreen"),
                            (60, "yellow"), (50, "orange")):
        if pct >= threshold:
            return name
    return "red"


def write(name, label, message, badge_color):
    body = {
        "schemaVersion": 1,
        "label": label,
        "message": message,
        "color": badge_color,
        # raw.githubusercontent.com caches for about five minutes anyway;
        # asking shields for less would only add requests.
        "cacheSeconds": 300,
    }
    pathlib.Path(out_dir, name).write_text(json.dumps(body) + "\n")
    print(f"{name}: {label} {message}")


write("tests.json", "tests", f"{total} passing", "brightgreen")
write("coverage.json", "coverage", f"{percent:.1f}%", color(percent))
print(f"({lines['covered']}/{lines['count']} lines; {len(counts)} test-run summary line(s))")
PY
