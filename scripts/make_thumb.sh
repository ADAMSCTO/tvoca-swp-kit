#!/usr/bin/env bash
# Usage: make_thumb.sh "<TITLE>" "<SUBLINE>" <bg_path> <out_png>
set -euo pipefail

TITLE="${1:-}"; SUB="${2:-}"; BG="${3:-}"; OUT="${4:-}"
[ -n "$TITLE" ] && [ -n "$SUB" ] && [ -f "$BG" ] && [ -n "$OUT" ] || {
  echo "Usage: $(basename "$0") \"TITLE\" \"SUBLINE\" <bg> <out.png>"; exit 1; }

mkdir -p "$(dirname "$OUT")"

# Escape text for FFmpeg drawtext (escape \  :  ,  ' )
esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g' -e 's/,/\\,/g' -e "s/'/\\\\'/g"
}
TTL_ESC="$(esc "$TITLE")"
SUB_ESC="$(esc "$SUB")"

# Build filter graph (no single quotes so variables expand)
VF=$(
  cat <<EOF
scale=1080:1920:force_original_aspect_ratio=increase,
crop=1080:1920,
format=yuv420p,
drawbox=x=0:y=0:w=1080:h=320:color=black@0.35:t=fill,
drawtext=text='${TTL_ESC}':font=Arial:fontsize=68:fontcolor=white:x=(w-text_w)/2:y=120:borderw=3:bordercolor=black@1.0,
drawtext=text='${SUB_ESC}':font=Arial:fontsize=36:fontcolor=white:x=(w-text_w)/2:y=h-140:borderw=2:bordercolor=black@1.0
EOF
)

ffmpeg -y -i "$BG" -vf "$VF" -frames:v 1 "$OUT"
echo "OK → $OUT"
