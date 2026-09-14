#!/usr/bin/env bash
# Enforce the swiftlint baseline as a ratchet: no new violations, and never more error-level
# violations than the recorded budget. It is deliberately not a formatter or a rewrite: the
# structural rules (file_length, type_body_length, function_body_length, cyclomatic_complexity)
# and the 120-character line_length preference are accepted debt, documented in the #0073 commit.
#
# The check is version-aware: a swiftlint upgrade changes the rule set, so a different version
# reports the new counts and exits 0 rather than failing a build for a tool change. Re-record the
# budget with --write after reviewing the delta.
#
# Usage: scripts/lint-budget.sh [--write]
set -euo pipefail
cd "$(dirname "$0")/.."

budget_file="scripts/lint-budget.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

version="$(swiftlint version)"
# swiftlint exits non-zero when it finds violations; the JSON report is still complete.
swiftlint lint --quiet --reporter json Sources/converter Sources/Tests > "$work/lint.json" || true

python3 - "$budget_file" "$work/lint.json" "$version" "${1:-}" <<'PY'
import collections
import json
import sys

budget_path, report_path, version, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
budget = json.load(open(budget_path))
findings = json.load(open(report_path))

by_rule = collections.Counter(f["rule_id"] for f in findings)
errors = sum(1 for f in findings if f["severity"].lower().startswith("error"))
total = len(findings)

if mode == "--write":
    budget.update(
        swiftlint=version,
        total=total,
        errors=errors,
        by_rule=dict(sorted(by_rule.items())),
    )
    open(budget_path, "w").write(json.dumps(budget, indent=2) + "\n")
    print(f"recorded budget for swiftlint {version}: {total} violations, {errors} error-level")
    sys.exit(0)

print(
    f"swiftlint {version}: {total} violations ({errors} error-level) — "
    f"budget {budget['total']} / {budget['errors']} recorded with swiftlint {budget['swiftlint']}"
)

if version != budget["swiftlint"]:
    print(
        f"::warning::swiftlint {version} differs from the budget's {budget['swiftlint']}; "
        "counts are informational until the budget is re-recorded with --write"
    )
    sys.exit(0)

regressions = []
for rule, count in sorted(by_rule.items()):
    allowed = budget["by_rule"].get(rule, 0)
    if count > allowed:
        regressions.append(f"  {rule}: {allowed} -> {count}")

if total > budget["total"] or errors > budget["errors"] or regressions:
    print("::error::swiftlint regression against the recorded budget")
    print(f"  total: {budget['total']} -> {total}")
    print(f"  errors: {budget['errors']} -> {errors}")
    for line in regressions:
        print(line)
    print("Fix the new violations, or lower the code they replace; do not raise the budget silently.")
    sys.exit(1)

print("no new violations")
PY
