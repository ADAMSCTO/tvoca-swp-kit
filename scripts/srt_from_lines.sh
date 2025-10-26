#!/usr/bin/env bash
# Convert a plain text file of lines into a basic SRT with uniform durations.
# Usage: srt_from_lines.sh input_lines.txt output.srt [seconds_per_line]
set -euo pipefail

IN="${1:-}"; OUT="${2:-}"; DUR="${3:-3.5}"
[ -n "$IN" ] && [ -n "$OUT" ] || { echo "Usage: $(basename "$0") input.txt output.srt [seconds_per_line]"; exit 1; }
[ -f "$IN" ] || { echo "Missing input: $IN"; exit 2; }

# function to format seconds → HH:MM:SS,mmm
ts() {
  python - "$1" <<'PY'
import sys
t=float(sys.argv[1]); 
h=int(t//3600); t-=h*3600
m=int(t//60);   t-=m*60
s=int(t);       ms=int(round((t-s)*1000))
print(f"{h:02d}:{m:02d}:{s:02d},{ms:03d}")
PY
}

idx=0
start=0.0
> "$OUT"
# Read non-empty lines and emit SRT cues
while IFS= read -r line || [ -n "$line" ]; do
  # skip empty visual lines but still advance time for consistency (optional: comment next two lines to ignore)
  if [ -z "$line" ]; then 
    start=$(python - <<PY
s=$start; d=$DUR
print(s+d)
PY
)
    continue
  fi

  idx=$((idx+1))
  end=$(python - <<PY
s=$start; d=$DUR
print(s+d)
PY
)
  echo "$idx" >> "$OUT"
  printf "%s --> %s\n" "$(ts "$start")" "$(ts "$end")" >> "$OUT"
  echo "$line" >> "$OUT"
  echo >> "$OUT"
  start="$end"
done < "$IN"

echo "Wrote SRT → $OUT (lines=$(grep -c . "$IN"), dur_per_line=${DUR}s)"
