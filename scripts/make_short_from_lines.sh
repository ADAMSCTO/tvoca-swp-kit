#!/usr/bin/env bash
# Usage:
#  make_short_from_lines.sh <male|female> <bg_path> <lines.txt> <tag> [dur_per_line]
set -euo pipefail
FAM="${1:-}"; BG="${2:-}"; LINES_PATH="${3:-}"; TAG="${4:-}"; DUR="${5:-3.5}"
BASE="/c/jf/jirehfaith_swp_kit"
SRT="$BASE/voice/build/${TAG}.srt"
WAV="$BASE/voice/wavs/${TAG}.wav"
OUT="$BASE/out/${TAG}.mp4"

[ -n "$FAM" ] && [ -f "$BG" ] && [ -f "$LINES_PATH" ] && [ -n "$TAG" ] || {
  echo "Usage: $(basename "$0") <male|female> <bg> <lines.txt> <tag> [dur_per_line]"; exit 1; }

# 1) SRT
"$BASE/scripts/srt_from_lines.sh" "$LINES_PATH" "$SRT" "$DUR"

# 2) TTS (explicit separator to avoid arg confusion)
"$BASE/piper/piper_say.sh" "$FAM" --file "$LINES_PATH" -- "$WAV"

# 3) Render MP4 (captions tweakable via env: FONT_SIZE, MARGIN_V)
FONT_SIZE=${FONT_SIZE:-36} MARGIN_V=${MARGIN_V:-80} \
"$BASE/scripts/render_short_ffmpeg.sh" "$BG" "$WAV" "$SRT" "$OUT"

echo "DONE:"
echo "  SRT: $SRT"
echo "  WAV: $WAV"
echo "  MP4: $OUT"
