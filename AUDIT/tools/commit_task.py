#!/usr/bin/env python3
"""Stage a subset of files (optionally with test blocks stripped), commit, and stamp the ledger.
usage: commit_task.py <ids comma> <message-file> <file>... [--strip file:funcname,funcname]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, cast

Json = dict[str, Any]
LEDGER = Path("AUDIT/ledger.json")
STAMP_TRAILER = "\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
TEST_FUNC = re.compile(r"\s*func (test\w+)\(")


def strip_tests(text: str, names: list[str]) -> str:
    """Remove the named `func test…` blocks (and their leading comments) from Swift source."""
    lines = text.split("\n")
    out: list[str] = []
    skip = False
    depth = 0
    for line in lines:
        match = TEST_FUNC.match(line)
        if not skip and match is not None and match.group(1) in names:
            # drop preceding comment lines and a blank line
            while out and out[-1].strip().startswith("//"):
                out.pop()
            if out and out[-1].strip() == "":
                out.pop()
            skip = True
            depth = 0
        if skip:
            depth += line.count("{") - line.count("}")
            if depth == 0 and line.strip() == "}":
                skip = False
            continue
        out.append(line)
    return "\n".join(out)


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
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ids = sys.argv[1].split(",")
    msg = Path(sys.argv[2]).read_text()
    files: list[str] = []
    strips: dict[str, list[str]] = {}
    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--strip":
            target, _, names = args[i + 1].partition(":")
            strips[target] = names.split(",")
            i += 2
        else:
            files.append(args[i])
            i += 1

    backups: dict[str, str] = {}
    for target, func_names in strips.items():
        original = Path(target).read_text()
        backups[target] = original
        Path(target).write_text(strip_tests(original, func_names))

    # ledger: mark ids DONE with pending sha
    data: Json = cast("Json", json.loads(LEDGER.read_text()))
    for task in data["tasks"]:
        if task["id"] in ids:
            task["status"] = "DONE"
            task["commit"] = "pending-this-commit"
    LEDGER.write_text(json.dumps(data, indent=2))
    subprocess.check_call(["python3", "AUDIT/tools/render_ledger.py"], stdout=subprocess.DEVNULL)
    subprocess.check_call(["git", "add", *files, "AUDIT/ledger.json", "AUDIT/ledger.md"])
    subprocess.check_call(["git", "add", "AUDIT/evidence"])
    require_clean_of_leftovers()
    subprocess.check_call(["git", "commit", "-q", "-m", msg])
    sha = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"]).decode().strip()
    data = cast("Json", json.loads(LEDGER.read_text()))
    for task in data["tasks"]:
        if task.get("commit") == "pending-this-commit":
            task["commit"] = sha
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
    for target, original in backups.items():
        Path(target).write_text(original)
    print(sha, ids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
