#!/usr/bin/env python3
"""commit_one.py <ids comma> <msgfile> <status> <fix_summary> <evidence_after> file... :
stage files, set ledger status/fields, commit, stamp sha in a follow-up ledger commit.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, cast

Json = dict[str, Any]
LEDGER = Path("AUDIT/ledger.json")
STAMP_TRAILER = "\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"


def unstaged_tracked_leftovers() -> list[str]:
    """Tracked files with worktree changes that are not staged.

    The batch helpers stage only the paths their caller lists, so a file that was edited but not
    listed silently stays behind (it happened once: VideoPipeline.swift). Refuse to commit in that
    state unless AUDIT_ALLOW_DIRTY=1 is set deliberately.
    """
    out = subprocess.check_output(["git", "status", "--porcelain"]).decode()
    leftovers: list[str] = []
    for line in out.splitlines():
        if len(line) < 4:
            continue
        worktree = line[1]
        if worktree in ("M", "D", "R", "T"):
            leftovers.append(line[3:])
    return leftovers


def require_clean_of_leftovers() -> None:
    leftovers = unstaged_tracked_leftovers()
    if leftovers and os.environ.get("AUDIT_ALLOW_DIRTY") != "1":
        sys.exit(
            "refusing to commit: tracked files are modified but not staged; add them to the file "
            "list (or set AUDIT_ALLOW_DIRTY=1 to override):\n  " + "\n  ".join(leftovers)
        )


def main() -> int:
    if len(sys.argv) < 6:
        sys.exit(__doc__)
    ids = sys.argv[1].split(",")
    msg = Path(sys.argv[2]).read_text()
    status = sys.argv[3]
    fix = sys.argv[4]
    after = sys.argv[5]
    files = sys.argv[6:]

    data: Json = cast("Json", json.loads(LEDGER.read_text()))
    for task in data["tasks"]:
        if task["id"] in ids:
            task["status"] = "TEST" if status == "DONE" else status
            task["fix_summary"] = fix
            task["evidence_after"] = after
    LEDGER.write_text(json.dumps(data, indent=2))
    subprocess.check_call(["python3", "AUDIT/tools/render_ledger.py"], stdout=subprocess.DEVNULL)
    subprocess.check_call(["git", "add", *files, "AUDIT/ledger.json", "AUDIT/ledger.md", "AUDIT/evidence"])
    require_clean_of_leftovers()
    subprocess.check_call(["git", "commit", "-q", "-m", msg])
    sha = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"]).decode().strip()
    data = cast("Json", json.loads(LEDGER.read_text()))
    for task in data["tasks"]:
        if task["id"] in ids:
            task["commit"] = sha
            task["status"] = status
    LEDGER.write_text(json.dumps(data, indent=2))
    subprocess.check_call(["python3", "AUDIT/tools/render_ledger.py"], stdout=subprocess.DEVNULL)
    subprocess.check_call(["git", "add", "AUDIT/ledger.json", "AUDIT/ledger.md"])
    subprocess.check_call(
        [
            "git",
            "commit",
            "-q",
            "-m",
            "audit(ledger): stamp " + ", ".join(ids) + " with " + sha + STAMP_TRAILER,
        ]
    )
    print(sha, ids, status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
