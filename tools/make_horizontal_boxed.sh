#!/usr/bin/env bash
# Usage: make_horizontal_boxed.sh BG.png INPUT.wav INPUT.srt OUT.mp4
# Defaults can be overridden via env:
#   FONT_SIZE=150  MARGIN_L=160  MARGIN_R=160  MARGIN_V=0  BOX_OPA=96  LEAD_MS=200
# Notes:
#   - 16:9 horizontal (1920x1080) PlayRes
#   - Centered boxed captions (Alignment=5, BorderStyle=3)
#   - Parity with make_vertical_boxed.sh — only the PlayRes/canvas differs.

set -euo pipefail

BG="${1:?need BG image (png/jpg)}"
WAV="${2:?need WAV file}"
SRT_IN="${3:?need SRT file}"
OUT="${4:?need output MP4}"

FONT_SIZE="${FONT_SIZE:-150}"
MARGIN_L="${MARGIN_L:-160}"
MARGIN_R="${MARGIN_R:-160}"
MARGIN_V="${MARGIN_V:-0}"
BOX_OPA="${BOX_OPA:-96}"      # 00 transparent .. FF opaque
LEAD_MS="${LEAD_MS:-200}"     # ms caption delay after speech onset

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
BUILD="$ROOT/voice/build"
OUTDIR="$(dirname "$OUT")"
mkdir -p "$BUILD" "$OUTDIR"

# 1) Auto-sync SRT to WAV (outputs *_autosync.srt)
SRT_SYNC="$BUILD/$(basename "${SRT_IN%.*}").autosync.srt"
bash "$TOOLS/srt_autosync.sh" "$SRT_IN" "$WAV" "$SRT_SYNC" "$LEAD_MS"

# 2) Convert autosynced SRT to ASS
ASS="$BUILD/$(basename "${SRT_IN%.*}").autosync.ass"
ffmpeg -hide_banner -y -i "$SRT_SYNC" -c:s ass "$ASS" >/dev/null 2>&1

# 3) Ensure 16:9 PlayRes and inject/replace CenterBox style
#    (BackColour format AABBGGRR; black with alpha BOX_OPA)
if ! grep -q '^PlayResX:' "$ASS"; then
  sed -i '1{/^\[Script Info\]$/!q}; t; a PlayResX: 1920\nPlayResY: 1080' "$ASS"
fi
sed -i -E 's/^PlayResX:.*/PlayResX: 1920/; s/^PlayResY:.*/PlayResY: 1080/' "$ASS"

# Insert or replace "Style: CenterBox"
STYLE_LINE="Style: CenterBox,Arial,${FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,&H${BOX_OPA}000000,0,0,0,0,100,100,0,0,3,0,0,5,${MARGIN_L},${MARGIN_R},${MARGIN_V},1"
if grep -q '^Style: CenterBox,' "$ASS"; then
  # replace existing CenterBox line
  sed -i -E "s|^Style: CenterBox,.*$|${STYLE_LINE}|" "$ASS"
else
  # add after Styles Format line
  awk -v ins="$STYLE_LINE" '
    BEGIN{added=0}
    /^\[V4\+ Styles\]/{print; getline; print; print ins; added=1; next}
    {print}
    END{ if(!added) exit 0 }
  ' "$ASS" > "$ASS.tmp" && mv -f "$ASS.tmp" "$ASS"
fi

# 4) Switch all Dialogue lines to CenterBox style
sed -i -E '/^Dialogue:/ s/,Default,/,CenterBox,/' "$ASS"

# 5) Render horizontal MP4 with ASS (boxed captions, no overlays)
ASS_WIN="$(cygpath -w "$ASS" | sed 's/\\/\\\\/g; s/:/\\:/')"
ffmpeg -hide_banner -y -loop 1 -framerate 30 -i "$BG" -i "$WAV" \
  -vf "ass='${ASS_WIN}'" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT"

echo
echo "[OK] Rendered:"
cygpath -w "$OUT"
