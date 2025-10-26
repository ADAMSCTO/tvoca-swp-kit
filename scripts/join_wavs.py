#!/usr/bin/env python3
import argparse, os, wave
ap=argparse.ArgumentParser()
ap.add_argument("--indir",required=True)
ap.add_argument("--out",required=True)
ap.add_argument("--gap_ms",type=int,default=150)
a=ap.parse_args()
files=sorted([f for f in os.listdir(a.indir) if f.lower().endswith(".wav")])
if not files: raise SystemExit("No WAVs found")
def silence(ms,fr,nc,sw): return b"\x00"*int(fr*ms/1000.0)*nc*sw
first=os.path.join(a.indir,files[0])
with wave.open(first,"rb") as wf:
  nc,sw,fr=wf.getnchannels(),wf.getsampwidth(),wf.getframerate()
gap=silence(a.gap_ms,fr,nc,sw)
with wave.open(a.out,"wb") as out:
  out.setnchannels(nc); out.setsampwidth(sw); out.setframerate(fr)
  for name in files:
    p=os.path.join(a.indir,name)
    with wave.open(p,"rb") as wf:
      if (wf.getnchannels(),wf.getsampwidth(),wf.getframerate())!=(nc,sw,fr):
        raise SystemExit(f"Param mismatch: {name}")
      out.writeframes(wf.readframes(wf.getnframes()))
    out.writeframes(gap)
print("Wrote",a.out)
