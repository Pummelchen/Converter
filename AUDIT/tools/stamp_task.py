#!/usr/bin/env python3
"""stamp_task.py <ids comma> <sha> <status> <fix_summary> <evidence_after>
For a task commit that already exists on the branch (e.g. cherry-picked from a worker worktree):
set status/fix/evidence/commit in the ledger, re-render, and commit the ledger files only.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any, cast

Json = dict[str, Any]


def main() -> int:
    if len(sys.argv) < 6:
        sys.exit(__doc__)
    ids = sys.argv[1].split(",")
    sha = sys.argv[2]
    status = sys.argv[3]
    fix = sys.argv[4]
    after = sys.argv[5]
    subprocess.check_call(["git", "cat-file", "-e", sha + "^{commit}"])
    path = Path("AUDIT/ledger.json")
    data: Json = cast("Json", json.loads(path.read_text()))
    hit: list[str] = []
    for task in data["tasks"]:
        if task["id"] in ids:
            task["status"] = status
            task["fix_summary"] = fix
            task["evidence_after"] = after
            task["commit"] = sha
            hit.append(task["id"])
    missing = set(ids) - set(hit)
    if missing:
        sys.exit(f"ids not found: {sorted(missing)}")
    path.write_text(json.dumps(data, indent=2))
    subprocess.check_call(["python3", "AUDIT/tools/render_ledger.py"], stdout=subprocess.DEVNULL)
    subprocess.check_call(["git", "add", str(path), "AUDIT/ledger.md"])
    subprocess.check_call(
        [
            "git",
            "commit",
            "-q",
            "-m",
            "audit(ledger): stamp "
            + ", ".join(ids)
            + " with "
            + sha
            + "\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>",
        ]
    )
    print(sha, hit, status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
