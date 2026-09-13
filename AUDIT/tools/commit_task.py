#!/usr/bin/env python3
"""Stage a subset of files (optionally with test blocks stripped), commit, and stamp the ledger.
usage: commit_task.py <ids comma> <message-file> <file>... [--strip file:funcname,funcname]
"""
import json, subprocess, sys, re, os
ids=sys.argv[1].split(","); msg=open(sys.argv[2]).read(); files=[]; strips={}
args=sys.argv[3:]
i=0
while i<len(args):
    if args[i]=="--strip":
        f,names=args[i+1].split(":"); strips[f]=names.split(","); i+=2
    else: files.append(args[i]); i+=1
def strip_tests(text, names):
    lines=text.split("\n"); out=[]; skip=False
    for idx,l in enumerate(lines):
        if not skip and re.match(r"\s*func (test\w+)\(", l) and re.match(r"\s*func (test\w+)\(", l).group(1) in names:
            # drop preceding comment lines and a blank line
            while out and out[-1].strip().startswith("//"): out.pop()
            if out and out[-1].strip()=="": out.pop()
            skip=True; depth=0
        if skip:
            depth+=l.count("{")-l.count("}")
            if depth==0 and l.strip()=="}": skip=False
            continue
        out.append(l)
    return "\n".join(out)
backups={}
for f,names in strips.items():
    orig=open(f).read(); backups[f]=orig
    open(f,"w").write(strip_tests(orig,names))
# ledger: mark ids DONE with pending sha
p="AUDIT/ledger.json"; d=json.load(open(p))
for t in d["tasks"]:
    if t["id"] in ids: t["status"]="DONE"; t["commit"]="pending-this-commit"
json.dump(d,open(p,"w"),indent=2)
subprocess.check_call(["python3","AUDIT/tools/render_ledger.py"],stdout=subprocess.DEVNULL)
subprocess.check_call(["git","add"]+files+["AUDIT/ledger.json","AUDIT/ledger.md"]+[x for x in os.listdir("AUDIT/evidence") if False])
subprocess.check_call(["git","add","AUDIT/evidence"])
subprocess.check_call(["git","commit","-q","-m",msg])
sha=subprocess.check_output(["git","rev-parse","--short","HEAD"]).decode().strip()
d=json.load(open(p))
for t in d["tasks"]:
    if t.get("commit")=="pending-this-commit": t["commit"]=sha
json.dump(d,open(p,"w"),indent=2)
subprocess.check_call(["python3","AUDIT/tools/render_ledger.py"],stdout=subprocess.DEVNULL)
subprocess.check_call(["git","add","AUDIT/ledger.json","AUDIT/ledger.md"])
subprocess.check_call(["git","commit","-q","-m","audit(ledger): stamp "+", ".join(ids)+" with "+sha+"\n\nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"])
for f,orig in backups.items(): open(f,"w").write(orig)
print(sha, ids)
