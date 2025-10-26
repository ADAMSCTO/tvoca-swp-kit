#!/usr/bin/env bash
# Back-compat wrapper for legacy v1 flags (-i/-o) → uses new profile-based engine.
# Default voice family: female (AMY). Override with --male.

set -euo pipefail
BASE="/c/jf/jirehfaith_swp_kit"
SAY="$BASE/piper/piper_say.sh"

IN_TXT=""
OUT_WAV=""
VOICE_FAMILY="female"   # default AMY
LEN=""
NS=""
NW=""
SIL=""

usage() {
  echo "Usage: $(basename "$0") -i INPUT.txt -o OUTPUT.wav [--male] [--len N] [--noise N] [--noisew N]"
  echo "Notes: --len/--noise/--noisew (if given) temporarily override the profile for this call."
  exit 1
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) IN_TXT="$2"; shift 2 ;;
    -o) OUT_WAV="$2"; shift 2 ;;
    --male) VOICE_FAMILY="male"; shift ;;
    --len) LEN="$2"; shift 2 ;;
    --noise) NS="$2"; shift 2 ;;
    --noisew) NW="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$IN_TXT" && -n "$OUT_WAV" ]] || usage
[[ -f "$IN_TXT" ]] || { echo "Input not found: $IN_TXT" >&2; exit 2; }

# If no overrides, just call piper_say.sh directly
if [[ -z "${LEN}${NS}${NW}" ]]; then
  "$SAY" "$VOICE_FAMILY" --file "$IN_TXT" "$OUT_WAV"
  exit 0
fi

# With overrides: temporarily source the profile, override, then call piper directly
PROFILES="$BASE/voice/profiles"
ENVFILE="$PROFILES/${VOICE_FAMILY}-default.env"
[ -f "$ENVFILE" ] || { echo "Missing profile: $ENVFILE" >&2; exit 3; }

set -a; . "$ENVFILE"; set +a
PIPER="$BASE/piper/piper.exe"
WAVS_DIR="$(dirname "$OUT_WAV")"; mkdir -p "$WAVS_DIR"

# keep existing if empty
: "${LENGTH_SCALE:=${LEN:-$LENGTH_SCALE}}"
: "${NOISE_SCALE:=${NS:-$NOISE_SCALE}}"
: "${NOISE_W:=${NW:-$NOISE_W}}"

cat "$IN_TXT" | "$PIPER" \
  --model "$MODEL_PATH" \
  --config "$CONFIG_PATH" \
  --length_scale "$LENGTH_SCALE" \
  --noise_scale "$NOISE_SCALE" \
  --noise_w "$NOISE_W" \
  --output_file "$OUT_WAV"

echo "OK → $OUT_WAV"
