#!/usr/bin/env python3
import argparse, json, re, os
ap=argparse.ArgumentParser()
ap.add_argument("--input",required=True)
ap.add_argument("--out",required=True)
ap.add_argument("--wps",type=float,default=3.0)
ap.add_argument("--gap",type=float,default=0.15)
ap.add_argument("--lead",type=float,default=0.3)
ap.add_argument("--maxlen",type=int,default=80)
a=ap.parse_args()
def wrap(t,m):
  w=t.strip().split(); L=[]; c=""
  for x in w:
    if len(c)+len(x)+1>m and c: L.append(c); c=x
    else: c=(c+" "+x).strip()
  if c: L.append(c); return " \n".join(L)
def fmt(t):
  ms=int(round((t-int(t))*1000)); s=int(t)%60; m=(int(t)//60)%60; h=(int(t)//3600)
  return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"
data=json.load(open(a.input,"r",encoding="utf-8"))
lines=[l.strip() for l in data.get("lines",[]) if l.strip()]
t=a.lead; i=1; out=[]
for ln in lines:
  dur=max(1.2,len(re.findall(r"\\w+",ln))/max(0.8,a.wps))
  out.append(f"{i}\\n{fmt(t)} --> {fmt(t+dur)}\\n{wrap(ln,a.maxlen)}\\n"); i+=1; t+=dur+a.gap
os.makedirs(os.path.dirname(a.out),exist_ok=True)
open(a.out,"w",encoding="utf-8").write("\\n".join(out))
print("Wrote",a.out)
