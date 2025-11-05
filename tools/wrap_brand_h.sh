#!/usr/bin/env bash
# Build 1920x1080 branded HORIZONTAL backgrounds from mid-plates
# Input dir:  assets/bg_mid_h
# Output dir: assets/bg_h
# Mirrors vertical: purple top/bottom bars + centered URL + top banner overlay.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN_DIR="$ROOT/assets/bg_mid_h"
OUT_DIR="$ROOT/assets/bg_h"

W=1920
H=1080
TOP_H=112
FOOTER_H=112

# Brand colors (match vertical)
PURPLE="0x6A0DAD"
GOLD="0xD4AF37"

# Top banner artwork (PNG with transparency)
BRAND="$ROOT/assets/brand/top-T.png"
HAS_BRAND=0
[ -f "$BRAND" ] && HAS_BRAND=1

# Prefer real Segoe UI if available; else fall back to logical name
SEGOE_WIN_1="C:/Windows/Fonts/segoeui.ttf"
SEGOE_WIN_2="/c/Windows/Fonts/segoeui.ttf"
if [[ -f "$SEGOE_WIN_1" ]]; then
  DRAWFONT="fontfile='${SEGOE_WIN_1//:/\\:}'"
elif [[ -f "$SEGOE_WIN_2" ]]; then
  DRAWFONT="fontfile='${SEGOE_WIN_2//:/\\:}'"
else
  DRAWFONT="font='Segoe UI'"
fi

mkdir -p "$OUT_DIR"
echo "Wrapping mid-plates from $IN_DIR → $OUT_DIR"
echo " - top banner: $([[ $HAS_BRAND -eq 1 ]] && echo present || echo MISSING)"

EMOTIONS=( anger anxiety despair fear financial_trials grief hope illness joy love perseverance relationship_trials peace success protection )

for e in "${EMOTIONS[@]}"; do
  IN="$IN_DIR/$e.png"
  OUT="$OUT_DIR/$e.png"
  if [[ ! -f "$IN" ]]; then
    echo "  [skip] $IN not found"
    continue
  fi

  if [[ $HAS_BRAND -eq 1 ]]; then
    # 2 inputs: mid-plate + brand
    FILTER="
      [0:v]format=rgba,setsar=1[a];
      [a]drawbox=x=0:y=0:w=${W}:h=${TOP_H}:color=${PURPLE}:t=fill[top];
      [top]drawbox=x=0:y=$((H - FOOTER_H)):w=${W}:h=${FOOTER_H}:color=${PURPLE}:t=fill[foot];
      [1:v]scale=-1:${TOP_H}[b];
      [foot][b]overlay=x=(main_w-overlay_w)/2:y=0:format=auto[withbrand];
      [withbrand]drawtext=${DRAWFONT}:text='jirehfaith.com':fontsize=64:fontcolor=${GOLD}:x=(w-text_w)/2:y=h-${FOOTER_H}/2-text_h/2[outv]
    "
    ffmpeg -v warning -y \
      -i "$IN" -i "$BRAND" \
      -filter_complex "$FILTER" \
      -map "[outv]" -frames:v 1 -update 1 -f image2 "$OUT" >/dev/null
  else
    # 1 input: just mid-plate
    FILTER="
      [0:v]format=rgba,setsar=1[a];
      [a]drawbox=x=0:y=0:w=${W}:h=${TOP_H}:color=${PURPLE}:t=fill[top];
      [top]drawbox=x=0:y=$((H - FOOTER_H)):w=${W}:h=${FOOTER_H}:color=${PURPLE}:t=fill[foot];
      [foot]drawtext=${DRAWFONT}:text='jirehfaith.com':fontsize=64:fontcolor=${GOLD}:x=(w-text_w)/2:y=h-${FOOTER_H}/2-text_h/2[outv]
    "
    ffmpeg -v warning -y \
      -i "$IN" \
      -filter_complex "$FILTER" \
      -map "[outv]" -frames:v 1 -update 1 -f image2 "$OUT" >/dev/null
  fi

  echo "  - $OUT"
done

echo "Done."
