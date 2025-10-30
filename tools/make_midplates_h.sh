#!/usr/bin/env bash
# Build horizontal (1920x1080) emotion mid-plates mirroring the vertical generator
# Output: assets/bg_mid_h/<emotion>.png
set -euo pipefail

OUTDIR="assets/bg_mid_h"
mkdir -p "$OUTDIR"

DUR=0.1  # lavfi duration; we only grab 1 frame

# Helper: emit a solid color plate (1920x1080)
# usage: solid "#RRGGBB"
solid() {
  local hex="$1"
  local c="0x${hex#\#}"   # #RRGGBB -> 0xRRGGBB
  echo "color=c=${c}:s=1920x1080:d=${DUR}"
}

# Render one plate with filters, into OUT
# Filters: optional boxblur, vignette (compat), brightness/saturation/contrast, optional grain
render_plate() {
  local src="$1"   # lavfi source
  local out="$2"   # output path
  local blur="$3"  # e.g., "2" or "0"
  local bri="$4"   # brightness -1..1 (e.g., 0.10)
  local sat="$5"   # saturation (1.0 = none)
  local cont="$6"  # contrast   (1.0 = none)
  local grain="$7" # noise strength (0 = none)
  local use_vig="$8" # "1" to add vignette

  local vf="format=yuv444p"
  if [[ "$blur" != "0" ]]; then
    vf="${vf},boxblur=${blur}:1"
  fi
  if [[ "$use_vig" == "1" ]]; then
    # Compatible vignette (defaults)
    vf="${vf},vignette=eval=init"
  fi
  vf="${vf},eq=brightness=${bri}:saturation=${sat}:contrast=${cont}"
  if [[ "$grain" != "0" ]]; then
    vf="${vf},noise=alls=${grain}:allf=t"
  fi
  vf="${vf},format=rgba"

  ffmpeg -v error -y -f lavfi -i "$src" -frames:v 1 -vf "$vf" "$out"
  echo " - $out"
}

# name base blur bri sat cont grain vig
make_an_emotion() {
  local name="$1" base="$2" blur="$3" bri="$4" sat="$5" cont="$6" grain="$7" vig="$8"
  local src; src="$(solid "$base")"
  render_plate "$src" "${OUTDIR}/${name}.png" "$blur" "$bri" "$sat" "$cont" "$grain" "$vig"
}

echo "Building horizontal (1920x1080) emotion mid-plates into ${OUTDIR}"

# Negative → soothing/comforting palettes (mirrors vertical intents)
make_an_emotion "anger"               "#3A6EA5"  "1"  "0.12" "0.98" "1.04" "3" "1"
make_an_emotion "anxiety"             "#5FA3A2"  "2"  "0.12" "0.98" "1.04" "3" "1"
make_an_emotion "despair"             "#B79C7B"  "1"  "0.06" "0.95" "0.98" "1" "1"
make_an_emotion "fear"                "#2F7F7B"  "1"  "0.12" "0.98" "1.06" "3" "1"
make_an_emotion "financial_trials"    "#3C75B0"  "1"  "0.12" "0.98" "1.06" "2" "1"
make_an_emotion "grief"               "#6D75A8"  "1"  "0.10" "0.95" "1.02" "2" "1"
make_an_emotion "illness"             "#6BAF92"  "1"  "0.12" "0.92" "1.02" "2" "1"
make_an_emotion "relationship_trials" "#A78BB7"  "1"  "0.16" "1.08" "1.04" "1" "1"

# Positive/neutral → uplifting, clean
make_an_emotion "hope"                "#3F8AC9"  "0"  "0.12" "1.12" "1.04" "0" "1"
make_an_emotion "joy"                 "#4FBF64"  "0"  "0.12" "1.18" "1.04" "0" "0"
make_an_emotion "love"                "#B46C8C"  "0"  "0.10" "1.10" "1.04" "0" "0"
make_an_emotion "peace"               "#6FAED6"  "0"  "0.12" "1.00" "1.00" "0" "1"
make_an_emotion "perseverance"        "#4A6A7A"  "0"  "0.10" "1.00" "1.06" "1" "1"
make_an_emotion "success"             "#2E9A6D"  "0"  "0.12" "1.05" "1.06" "0" "0"
make_an_emotion "protection"          "#3A5BBB"  "0"  "0.10" "1.00" "1.06" "1" "1"

echo "Done."
