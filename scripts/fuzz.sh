#!/bin/bash
# Fuzz the PDU decoder under AddressSanitizer.
#
# Apple's Xcode toolchain ships no libFuzzer runtime (for Swift or clang), so
# this uses pdu-fuzz's built-in deterministic mutation engine. The harness
# keeps an LLVMFuzzerTestOneInput entry point, so a swift.org toolchain with
# -sanitize=fuzzer support can drive the same body coverage-guided.
#
# Usage: scripts/fuzz.sh [seconds] [seed]
set -euo pipefail
cd "$(dirname "$0")/.."

SECONDS_TO_RUN="${1:-30}"
SEED="${2:-1}"

echo "Building pdu-fuzz with ASan..."
swift build -c release --product pdu-fuzz -Xswiftc -sanitize=address >/dev/null
BIN="$(swift build -c release --product pdu-fuzz -Xswiftc -sanitize=address --show-bin-path)/pdu-fuzz"

exec "$BIN" fuzz "$SECONDS_TO_RUN" "$SEED"
