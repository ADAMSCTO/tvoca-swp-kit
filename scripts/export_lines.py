#!/usr/bin/env python3
import argparse, json, os
ap=argparse.ArgumentParser()
src=ap.add_mutually_exclusive_group(required=True)
src.add_argument("--json")
src.add_argument("--txt")
ap.add_argument("--outdir",required=True)
a=ap.parse_args()
def write(lines,outdir):
  os.makedirs(outdir,exist_ok=True)
  for i,ln in enumerate(lines,1):
    open(os.path.join(outdir,f"{i:02d}.txt"),"w",encoding="utf-8").write(ln.strip()+"\n")
  print("Wrote",len(lines),"files to",outdir)
if a.json:
  data=json.load(open(a.json,"r",encoding="utf-8"))
  lines=[l.strip() for l in data.get("lines",[]) if l.strip()]
  write(lines,a.outdir)
else:
  lines=[l.strip() for l in open(a.txt,"r",encoding="utf-8").read().splitlines() if l.strip()]
  write(lines,a.outdir)
