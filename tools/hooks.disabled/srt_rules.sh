#!/usr/bin/env bash
# srt_rules.sh — inject a 1.1s scroll-stop title before the original SRT
# Env: SRT_IN, SRT_OUT, SIZE (1080x1920|1920x1080)

set -euo pipefail

: "${SRT_IN:?SRT_IN missing}"
: "${SRT_OUT:?SRT_OUT missing}"
SIZE="${SIZE:-1920x1080}"

# --- Customize this one-liner title safely in UI/Notepad ---
TITLE="Feeling anxious? Pray this with me…"
# -----------------------------------------------------------

# 1) New first cue (index 1) for 1.1s
{
  printf "1\n"
  printf "00:00:00,000 --> 00:00:01,100\n"
  printf "%s\n\n" "$TITLE"
} > "$SRT_OUT"

# 2) Append original cues, re-numbered starting at 2
awk 'BEGIN{RS=""; ORS="\n\n"}{
  gsub(/\r/,"");               # strip CR if present
  sub(/^[0-9]+\n/,"");         # drop original numeric index
  printf("%d\n%s\n\n", NR+1, $0);
}' "$SRT_IN" >> "$SRT_OUT"

# 3) Log
echo "[srt_rules] injected title + renumbered into $SRT_OUT" >> voice/build/hooks.log
