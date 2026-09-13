#!/usr/bin/env python3
"""mark_done.py <ids comma> <fullsuite-log> : after a green full suite, move the listed TEST tasks to DONE,
append the suite result to their evidence_after, re-render the ledger and commit (ledger + log)."""
import json, re, subprocess, sys

ids = sys.argv[1].split(",")
log = sys.argv[2]
text = open(log, errors="replace").read()
summary = re.findall(r"Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)", text)
if not summary:
    sys.exit(f"{log}: no XCTest summary line found")
executed, failures, unexpected = summary[-1]
if failures != "0" or unexpected != "0":
    sys.exit(f"{log}: suite not green ({executed} executed, {failures} failures, {unexpected} unexpected)")
warnings = len(re.findall(r"warning:", text))
note = f"Full suite ({log}): {executed} executed, 0 failures, {warnings} compiler warnings."

path = "AUDIT/ledger.json"
data = json.load(open(path))
hit = []
for task in data["tasks"]:
    if task["id"] in ids:
        if task["status"] != "TEST":
            sys.exit(f"{task['id']} is {task['status']}, not TEST")
        task["status"] = "DONE"
        prev = task.get("evidence_after") or ""
        prev = re.sub(r"\s*Full suite pending\.?$|\s*Full suite: (next batch run|pending)\.?$", "", prev).rstrip()
        task["evidence_after"] = (prev + " " if prev else "") + note
        hit.append(task["id"])
missing = set(ids) - set(hit)
if missing:
    sys.exit(f"ids not found: {sorted(missing)}")
json.dump(data, open(path, "w"), indent=2)
subprocess.check_call(["python3", "AUDIT/tools/render_ledger.py"], stdout=subprocess.DEVNULL)
subprocess.check_call(["git", "add", path, "AUDIT/ledger.md", log])
subprocess.check_call(["git", "commit", "-q", "-m",
    "audit(ledger): " + " ".join(ids) + f" DONE after batch suite ({executed}/{executed})\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"])
print("DONE:", hit, note)
