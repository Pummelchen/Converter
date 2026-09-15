#!/usr/bin/env bash
# §1 requires a formatter for every language in the repository. Swift ships `swift format` with the
# toolchain (Xcode 27 / Swift 6.4); .swift-format records the project's conventions (4-space
# indentation, 120 columns) and this script enforces them.
#
# Usage: scripts/check-format.sh          # fail on any formatting difference
#        scripts/check-format.sh --write  # reformat the tree in place
set -euo pipefail
cd "$(dirname "$0")/.."

paths=(Sources/converter Sources/Tests Sources/BW64Bridge)

if [ "${1:-}" = "--write" ]; then
  swift format --in-place --recursive --parallel --configuration .swift-format "${paths[@]}"
  echo "reformatted ${paths[*]} with .swift-format"
  exit 0
fi

# `swift format lint` exits 0 even when it reports differences on this toolchain, so the gate is the
# report itself: any output at all means the tree is not formatted.
report="$(swift format lint --recursive --parallel --configuration .swift-format "${paths[@]}" 2>&1 || true)"
if [ -n "$report" ]; then
  printf '%s\n' "$report"
  echo "::error::swift format found formatting differences; run scripts/check-format.sh --write" >&2
  exit 1
fi
echo "swift format clean: $(swift format --version)"
