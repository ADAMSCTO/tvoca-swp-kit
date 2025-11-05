#!/usr/bin/env bash
# Usage: make_title_poster.sh --size=1080x1920 "out/title.png"
# Env:
#   TOP_BANNER (required)  – text to render
#   FONT_NAME (Arial), FONT_SIZE (150), MARGIN_L/R/V (160/160/0), BOX_OPA (96)
#   BG_PNG (optional)      – background image to composite (emotion background)

set -euo pipefail

# --- args ---
SIZE=""; if [[ "${1:-}" == --size=* ]]; then SIZE="${1#--size=}"; shift; fi
OUT="${1:?need output PNG path}"

# --- env defaults ---
TOP_BANNER="${TOP_BANNER:-}"
if [[ -z "$TOP_BANNER" ]]; then
  echo "[err] TOP_BANNER is empty; export TOP_BANNER and try again." >&2
  exit 2
fi

FONT_NAME="${FONT_NAME:-Arial}"
FONT_SIZE="${FONT_SIZE:-150}"
MARGIN_L="${MARGIN_L:-160}"
MARGIN_R="${MARGIN_R:-160}"
MARGIN_V="${MARGIN_V:-0}"
BOX_OPA="${BOX_OPA:-96}"

PRX="${SIZE%x*}"; PRY="${SIZE#*x}"
if [[ -z "${PRX:-}" || -z "${PRY:-}" || "$PRX" == "$SIZE" || "$PRY" == "$SIZE" ]]; then
  echo "[err] --size=WxH required, e.g. --size=1080x1920" >&2
  exit 3
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/voice/build"; mkdir -p "$BUILD" "$(dirname "$OUT")"

# --- build ASS (CenterBox style) ---
ASS="$BUILD/.poster_title.${PRX}x${PRY}.ass"
esc="${TOP_BANNER//\\/\\\\}"; esc="${esc//\{/\{}"; esc="${esc//\}/\}}"
esc="${esc//$'\r'/}"; esc="${esc//$'\n'/\\N}"

{
  printf "%s\n" "[Script Info]" \
  "ScriptType: v4.00+" \
  "PlayResX: ${PRX}" \
  "PlayResY: ${PRY}" \
  "" \
  "[V4+ Styles]" \
  "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding" \
  "Style: CenterBox,${FONT_NAME},${FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,&H${BOX_OPA}000000,0,0,0,0,100,100,0,0,3,0,0,5,${MARGIN_L},${MARGIN_R},${MARGIN_V},1" \
  "" \
  "[Events]" \
  "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text" \
  "Dialogue: 0,0:00:00.00,0:00:10.00,CenterBox,,0,0,0,,{\an5\b1}${esc}"
} > "$ASS"

# Mixed paths for ffmpeg (Windows)
_to_mixed() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$p"; else printf "%s" "$p"; fi
}

_escape_drive_colon() { # turn C:/... into C\:/...
  local s="$1"
  case "$s" in
    [A-Za-z]:/*) printf "%s" "${s:0:1}\\:${s:2}";;
    *) printf "%s" "$s";;
  esac
}

ASS_MIXED="$(_to_mixed "$ASS")"
ASS_FF="$(_escape_drive_colon "$ASS_MIXED")"

# Optional BG
BG_FF=""
if [[ -n "${BG_PNG:-}" && -f "${BG_PNG}" ]]; then
  BG_MIXED="$(_to_mixed "$BG_PNG")"
  BG_FF="$(_escape_drive_colon "$BG_MIXED")"
  echo "[info] Using BG_PNG: $BG_FF"
fi

# --- build filtergraph ---
if [[ -n "$BG_FF" ]]; then
  # Cover: scale up preserving AR then center-crop
  # (force_original_aspect_ratio=increase is supported; 'cover' is not)
  VF="scale=${PRX}:${PRY}:force_original_aspect_ratio=increase,crop=${PRX}:${PRY},ass=filename='${ASS_FF}':original_size=${PRX}x${PRY}"
  IN_OPTS=(-i "$BG_MIXED")
else
  # Solid color background
  IN_OPTS=(-f lavfi -i "color=size=${PRX}x${PRY}:rate=30")
  VF="ass=filename='${ASS_FF}':original_size=${PRX}x${PRY}"
fi

# --- render 1 frame ---
ffmpeg -hide_banner -y "${IN_OPTS[@]}" -vf "$VF" -frames:v 1 "$OUT"

echo "[OK] Poster written:"
if command -v cygpath >/dev/null 2>&1; then cygpath -w "$OUT"; else echo "$OUT"; fi
