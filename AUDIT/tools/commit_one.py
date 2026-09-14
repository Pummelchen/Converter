#!/usr/bin/env python3
"""commit_one.py <ids comma> <msgfile> <status> <fix_summary> <evidence_after> file... : stage files, set ledger status/fields, commit, stamp sha in a follow-up ledger commit."""
import json,os,subprocess,sys
ids=sys.argv[1].split(","); msg=open(sys.argv[2]).read(); status=sys.argv[3]; fix=sys.argv[4]; after=sys.argv[5]; files=sys.argv[6:]
def unstaged_tracked_leftovers():
    """Tracked files with worktree changes that are not staged.

    The batch helpers stage only the paths their caller lists, so a file that was edited but not
    listed silently stays behind (it happened once: VideoPipeline.swift). Refuse to commit in that
    state unless AUDIT_ALLOW_DIRTY=1 is set deliberately.
    """
    out = subprocess.check_output(["git", "status", "--porcelain"]).decode()
    leftovers = []
    for line in out.splitlines():
        if len(line) < 4:
            continue
        worktree = line[1]
        if worktree in ("M", "D", "R", "T"):
            leftovers.append(line[3:])
    return leftovers


def require_clean_of_leftovers():
    leftovers = unstaged_tracked_leftovers()
    if leftovers and os.environ.get("AUDIT_ALLOW_DIRTY") != "1":
        sys.exit(
            "refusing to commit: tracked files are modified but not staged; add them to the file "
            "list (or set AUDIT_ALLOW_DIRTY=1 to override):\n  " + "\n  ".join(leftovers)
        )

p="AUDIT/ledger.json"; d=json.load(open(p))
for t in d["tasks"]:
    if t["id"] in ids:
        t["status"]="TEST" if status=="DONE" else status; t["fix_summary"]=fix; t["evidence_after"]=after
json.dump(d,open(p,"w"),indent=2); subprocess.check_call(["python3","AUDIT/tools/render_ledger.py"],stdout=subprocess.DEVNULL)
subprocess.check_call(["git","add"]+files+["AUDIT/ledger.json","AUDIT/ledger.md","AUDIT/evidence"])
require_clean_of_leftovers()
subprocess.check_call(["git","commit","-q","-m",msg]); sha=subprocess.check_output(["git","rev-parse","--short","HEAD"]).decode().strip()
d=json.load(open(p))
for t in d["tasks"]:
    if t["id"] in ids: t["commit"]=sha; t["status"]=status
json.dump(d,open(p,"w"),indent=2); subprocess.check_call(["python3","AUDIT/tools/render_ledger.py"],stdout=subprocess.DEVNULL)
subprocess.check_call(["git","add","AUDIT/ledger.json","AUDIT/ledger.md"])
subprocess.check_call(["git","commit","-q","-m","audit(ledger): stamp "+", ".join(ids)+" with "+sha+"\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"])
print(sha, ids, status)
