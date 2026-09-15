#!/usr/bin/env bash
# §1 requires the repository's Python to be formatted, linted and strictly typed. The audit tooling
# in AUDIT/tools/ is the only Python here; ruff and mypy read their settings from pyproject.toml
# (mypy takes its file list from there too, so it is run without arguments).
#
# Usage: scripts/check-python.sh
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in ruff mypy; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is not installed (brew install $tool)" >&2
    exit 1
  fi
done

ruff format --check AUDIT/tools
ruff check AUDIT/tools
mypy
echo "python tooling clean: $(ruff --version), $(mypy --version)"
