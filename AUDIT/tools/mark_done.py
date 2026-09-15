#!/usr/bin/env python3
"""mark_done.py <ids comma> <fullsuite-log> : after a green full suite, move the listed TEST tasks to DONE,
append the suite result to their evidence_after, re-render the ledger and commit (ledger + log).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, cast

Json = dict[str, Any]
SUITE_SUMMARY = r"Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)"
STAMP_TRAILER = "\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ids = sys.argv[1].split(",")
    log = sys.argv[2]
    text = Path(log).read_text(errors="replace")
    summary = re.findall(SUITE_SUMMARY, text)
    if not summary:
        sys.exit(f"{log}: no XCTest summary line found")
    executed, failures, unexpected = summary[-1]
    if failures != "0" or unexpected != "0":
        sys.exit(
            f"{log}: suite not green ({executed} executed, {failures} failures, {unexpected} unexpected)"
        )
    warnings = len(re.findall(r"warning:", text))
    note = f"Full suite ({log}): {executed} executed, 0 failures, {warnings} compiler warnings."

    path = Path("AUDIT/ledger.json")
    data: Json = cast("Json", json.loads(path.read_text()))
    hit: list[str] = []
    for task in data["tasks"]:
        if task["id"] in ids:
            if task["status"] != "TEST":
                sys.exit(f"{task['id']} is {task['status']}, not TEST")
            task["status"] = "DONE"
            prev = task.get("evidence_after") or ""
            prev = re.sub(
                r"\s*Full suite pending\.?$|\s*Full suite: (next batch run|pending)\.?$",
                "",
                prev,
            ).rstrip()
            task["evidence_after"] = (prev + " " if prev else "") + note
            hit.append(task["id"])
    missing = set(ids) - set(hit)
    if missing:
        sys.exit(f"ids not found: {sorted(missing)}")
    path.write_text(json.dumps(data, indent=2))
    subprocess.check_call(["python3", "AUDIT/tools/render_ledger.py"], stdout=subprocess.DEVNULL)
    subprocess.check_call(["git", "add", str(path), "AUDIT/ledger.md", log])
    subprocess.check_call(
        [
            "git",
            "commit",
            "-q",
            "-m",
            "audit(ledger): "
            + " ".join(ids)
            + f" DONE after batch suite ({executed}/{executed})"
            + STAMP_TRAILER,
        ]
    )
    print("DONE:", hit, note)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
