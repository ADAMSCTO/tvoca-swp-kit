#!/usr/bin/env bash
# piper_say.sh — speak with current male/female default profile
# Usage:
#   piper_say.sh male   "Text here" [out.wav]
#   piper_say.sh female --file input.txt [out.wav]
set -euo pipefail

BASE="/c/jf/jirehfaith_swp_kit"
PIPER="$BASE/piper/piper.exe"
PROFILES="$BASE/voice/profiles"
WAVS="$BASE/voice/wavs"

VOICE="${1:-}"; shift || true
[ -n "$VOICE" ] || { echo "Usage: $(basename "$0") <male|female> [TEXT | --file PATH] [OUT.wav]"; exit 1; }

case "$VOICE" in
  male)   ENVFILE="$PROFILES/male-default.env" ;;
  female) ENVFILE="$PROFILES/female-default.env" ;;
  *) echo "Voice must be 'male' or 'female'"; exit 1 ;;
esac

[ -x "$PIPER" ] || { echo "piper.exe not found at $PIPER"; exit 2; }
[ -f "$ENVFILE" ] || { echo "Missing profile: $ENVFILE"; exit 3; }
mkdir -p "$WAVS"

# Load profile
set -a
. "$ENVFILE"
set +a

TEXT=""; OUTFILE=""
SRC_PATH=""

# Parse the rest: allow optional '--', '--file PATH', plain TEXT, and optional OUTFILE
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift ;;  # ignore separator
    --file)
      SRC_PATH="${2:-}"
      [ -n "$SRC_PATH" ] && [ -f "$SRC_PATH" ] || { echo "Missing path after --file"; exit 4; }
      TEXT="$(cat "$SRC_PATH")"
      shift 2
      ;;
    *)
      if [[ -z "$TEXT" ]]; then
        TEXT="$1"; shift
      else
        OUTFILE="$1"; shift
      fi
      ;;
  esac
done

# Fallbacks
TS="$(date +%Y%m%d_%H%M%S)"
: "${OUTFILE:=$WAVS/${VOICE}_${TS}.wav}"

[ -n "$TEXT" ] || { echo "No text provided"; exit 5; }

# Synthesize
printf "%s" "$TEXT" | "$PIPER" \
  --model "$MODEL_PATH" \
  --config "$CONFIG_PATH" \
  --length_scale "$LENGTH_SCALE" \
  --noise_scale "$NOISE_SCALE" \
  --noise_w "$NOISE_W" \
  --output_file "$OUTFILE"

echo "OK → $OUTFILE"
