#!/usr/bin/env python3
"""Render the wiki 'Audit-Tracker' page from AUDIT/ledger.json (§9 mirror; the ledger wins).

Usage: python3 AUDIT/tools/render_wiki.py <path-to-wiki-clone>/Audit-Tracker.md
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

Json = dict[str, Any]
Task = dict[str, Any]
Column = tuple[str, str]

ROOT = Path(__file__).resolve().parents[1]
SEVERITY_ORDER = {"S0": 0, "S1": 1, "S2": 2, "S3": 3}


def esc(value: object) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", "<br>")


def table(rows: list[Task], cols: list[Column]) -> list[str]:
    if not rows:
        return ["_none_", ""]
    out = ["| " + " | ".join(h for _, h in cols) + " |", "|" + "---|" * len(cols)]
    for row in rows:
        out.append("| " + " | ".join(esc(row.get(k, "")) for k, _ in cols) + " |")
    out.append("")
    return out


def main() -> int:
    dst = Path(sys.argv[1])
    data: Json = cast("Json", json.loads((ROOT / "ledger.json").read_text()))
    tasks: list[Task] = sorted(data["tasks"], key=lambda t: (SEVERITY_ORDER[t["severity"]], t["id"]))
    c: Counter[str] = Counter(t["status"] for t in tasks)
    done, blocked = c["DONE"], c["BLOCKED"]
    open_ = len(tasks) - done - blocked
    out: list[str] = [
        "# Audit Tracker",
        "",
        "Project task and open-bug tracker for the pre-production audit. Mirrors `AUDIT/ledger.md` on the "
        f"`{data['branch']}` branch (the ledger is the source of truth; this page is generated from it by "
        "`AUDIT/tools/render_wiki.py`). Baseline commit `" + data["baseline_commit"] + "`.",
        "",
        f"Updated {datetime.now(UTC).date().isoformat()} · known-total **{len(tasks)}** · done **{done}** · open **{open_}** · blocked **{blocked}**",
        "",
        "Severity: S0 go-live blocker · S1 high · S2 medium · S3 low. Status flow: START → PROGRESS → TEST → AUDIT → DONE, or BLOCKED (with owner).",
        "",
    ]
    cols: list[Column] = [
        ("id", "id"),
        ("severity", "sev"),
        ("module", "module"),
        ("location", "file:line"),
        ("title", "title"),
        ("status", "status"),
    ]
    out += [
        "## Open S0 / S1",
        "",
        *table(
            [t for t in tasks if t["severity"] in ("S0", "S1") and t["status"] not in ("DONE", "BLOCKED")],
            cols,
        ),
    ]
    out += [
        "## Blocked (owner: repository maintainer unless stated)",
        "",
        *table(
            [t for t in tasks if t["status"] == "BLOCKED"],
            [*cols, ("blocked_reason", "reason / options")],
        ),
    ]
    out += [
        "## Open S2 / S3",
        "",
        *table(
            [t for t in tasks if t["severity"] in ("S2", "S3") and t["status"] not in ("DONE", "BLOCKED")],
            cols,
        ),
    ]
    out += [
        "## Deferred",
        "",
        *table(
            [t for t in tasks if t.get("deferred")],
            [*cols, ("notes", "owner / rationale")],
        ),
    ]
    out += [
        "## Changelog of completed audit tasks",
        "",
        *table(
            sorted([t for t in tasks if t["status"] == "DONE"], key=lambda t: t["id"]),
            [
                ("id", "id"),
                ("severity", "sev"),
                ("title", "title"),
                ("fix_summary", "fix"),
                ("commit", "commit"),
            ],
        ),
    ]
    dst.write_text("\n".join(out) + "\n")
    print(f"wrote {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
