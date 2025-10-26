#!/usr/bin/env bash
set -euo pipefail

BASE="/c/jf/jirehfaith_swp_kit"
PIPER="$BASE/piper/piper.exe"
PROFILES="$BASE/voice/profiles"
WAVS="$BASE/voice/wavs"

[ -x "$PIPER" ] || { echo "piper.exe not found at $PIPER"; exit 1; }
[ -f "$PROFILES/male-default.env" ] || { echo "Missing $PROFILES/male-default.env"; exit 1; }
mkdir -p "$WAVS"

# Load active male profile (Ryan by default unless switched)
set -a
. "$PROFILES/male-default.env"
set +a

# Usage:
#   piper_say_male.sh "Your text..." [out.wav]
#   piper_say_male.sh --file input.txt [out.wav]
TEXT=""
OUTFILE="${2:-}"

if [ "${1:-}" = "--file" ]; then
  SRC="${2:-}"
  [ -f "$SRC" ] || { echo "File not found: $SRC"; exit 1; }
  TEXT="$(cat "$SRC")"
  OUTFILE="${3:-}"
else
  TEXT="${1:-}"
fi

[ -n "$TEXT" ] || { echo "Usage: piper_say_male.sh \"Your text...\" [out.wav]  OR  piper_say_male.sh --file input.txt [out.wav]"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
: "${OUTFILE:=$WAVS/male_${TS}.wav}"

printf "%s" "$TEXT" | "$PIPER" \
  --model "$MODEL_PATH" \
  --config "$CONFIG_PATH" \
  --length_scale "$LENGTH_SCALE" \
  --noise_scale "$NOISE_SCALE" \
  --noise_w "$NOISE_W" \
  --output_file "$OUTFILE"

echo "OK → $OUTFILE"
