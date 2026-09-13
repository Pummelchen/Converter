#!/usr/bin/env python3
"""commit_one.py <ids comma> <msgfile> <status> <fix_summary> <evidence_after> file... : stage files, set ledger status/fields, commit, stamp sha in a follow-up ledger commit."""
import json,subprocess,sys
ids=sys.argv[1].split(","); msg=open(sys.argv[2]).read(); status=sys.argv[3]; fix=sys.argv[4]; after=sys.argv[5]; files=sys.argv[6:]
p="AUDIT/ledger.json"; d=json.load(open(p))
for t in d["tasks"]:
    if t["id"] in ids:
        t["status"]="TEST" if status=="DONE" else status; t["fix_summary"]=fix; t["evidence_after"]=after
json.dump(d,open(p,"w"),indent=2); subprocess.check_call(["python3","AUDIT/tools/render_ledger.py"],stdout=subprocess.DEVNULL)
subprocess.check_call(["git","add"]+files+["AUDIT/ledger.json","AUDIT/ledger.md","AUDIT/evidence"])
subprocess.check_call(["git","commit","-q","-m",msg]); sha=subprocess.check_output(["git","rev-parse","--short","HEAD"]).decode().strip()
d=json.load(open(p))
for t in d["tasks"]:
    if t["id"] in ids: t["commit"]=sha; t["status"]=status
json.dump(d,open(p,"w"),indent=2); subprocess.check_call(["python3","AUDIT/tools/render_ledger.py"],stdout=subprocess.DEVNULL)
subprocess.check_call(["git","add","AUDIT/ledger.json","AUDIT/ledger.md"])
subprocess.check_call(["git","commit","-q","-m","audit(ledger): stamp "+", ".join(ids)+" with "+sha+"\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"])
print(sha, ids, status)
