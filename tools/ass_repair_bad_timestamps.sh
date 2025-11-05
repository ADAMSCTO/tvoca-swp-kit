#!/usr/bin/env bash
# Fix ASS "Bad timestamp" problems by ensuring End > Start on Dialogue lines.
# Usage: ass_repair_bad_timestamps.sh IN.ass OUT.ass

set -euo pipefail
IN="${1:?need IN.ass}"
OUT="${2:?need OUT.ass}"

awk -F',' '
  function hms_to_sec(t,  a,b,c,ms, x) {
    # t like H:MM:SS.cs (ASS centiseconds)
    split(t, a, ":"); 
    b = a[1] + 0;              # hours
    c = a[2] + 0;              # minutes
    split(a[3], ms, ".");      # seconds . centiseconds
    # If no decimal part, assume .00
    x = (ms[1]+0) + ((length(ms)>1 ? ("0." ms[2]) : 0))  # seconds + .centi
    return b*3600 + c*60 + x
  }
  function sec_to_ass(x,  h,m,s,cs) {
    if (x < 0) x = 0
    h = int(x/3600); x -= h*3600
    m = int(x/60);   x -= m*60
    # centiseconds (two digits)
    s  = int(x); 
    cs = int( (x - s) * 100 + 0.5 )
    if (cs == 100) { s += 1; cs = 0 }
    return h ":" sprintf("%02d", m) ":" sprintf("%02d", s) "." sprintf("%02d", cs)
  }

  BEGIN{
    OFS=","
  }

  # Pass through non-Dialogue lines unchanged
  $0 !~ /^Dialogue:/ { print; next }

  {
    # ASS Events format: Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    # Some files include spaces after commas -> we preserve by reconstructing with OFS=","
    start = $2
    end   = $3

    st = hms_to_sec(start)
    en = hms_to_sec(end)

    # If end <= start, bump end minimally
    if (en <= st) {
      en = st + 0.30
    }

    $2 = sec_to_ass(st)
    $3 = sec_to_ass(en)

    # Optionally drop empty text events after cleanup
    # Text is field 10 and beyond (commas in text are allowed), but we can quick-check $0 length
    if (length($0) < 15) next

    print
  }
' "$IN" > "$OUT.tmp"

# If resulting file has zero Dialogue events, keep it but caller should detect and handle
mv -f "$OUT.tmp" "$OUT"
