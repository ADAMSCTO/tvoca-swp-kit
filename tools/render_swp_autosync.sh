#!/usr/bin/env bash
# Thin wrapper: delegate to render_swp_unified.sh (single source of truth)
# Usage: tools/render_swp_autosync.sh [--size=WxH] <bg.png> <in.wav> <in.srt> <out.mp4>
set -euo pipefail

SIZE=""
ARGS=()
for a in "$@"; do
  case "$a" in
    --size=*) SIZE="${a#--size=}";;
    *) ARGS+=("$a");;
  esac
done

if [ ${#ARGS[@]} -lt 4 ]; then
  echo "Usage: $0 [--size=WxH] <bg.png> <in.wav> <in.srt> <out.mp4>"
  exit 2
fi

BG="${ARGS[0]}"; IN_WAV="${ARGS[1]}"; IN_SRT="${ARGS[2]}"; OUT_MP4="${ARGS[3]}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/tools/render_swp_unified.sh"

# TEMPO_BIAS is respected by the unified renderer (default 1=on). To disable: TEMPO_BIAS=0 env.
if [ -n "$SIZE" ]; then
  exec "$R" --size="$SIZE" "$BG" "$IN_WAV" "$IN_SRT" "$OUT_MP4"
else
  exec "$R" "$BG" "$IN_WAV" "$IN_SRT" "$OUT_MP4"
fi
