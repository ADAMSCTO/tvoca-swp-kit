#!/usr/bin/env bash
# Usage: render_center_boxed.sh BG.png INPUT.wav INPUT.srt OUT.mp4
# Env vars you can tweak per run:
#   FONT_SIZE (default 28)
#   MARGIN_L, MARGIN_R (default 160 each)
#   MARGIN_V (default 0; 0 keeps text exactly centered vertically)
#   BOX_OPA (hex AA for BackColour alpha, default 96 ~ 59% opacity)
set -euo pipefail

BG="${1:?need background image (png/jpg)}"
WAV="${2:?need input wav}"
SRT="${3:?need input srt}"
OUT="${4:?need output mp4}"

FONT_SIZE="${FONT_SIZE:-28}"
MARGIN_L="${MARGIN_L:-160}"
MARGIN_R="${MARGIN_R:-160}"
MARGIN_V="${MARGIN_V:-0}"
BOX_OPA="${BOX_OPA:-96}"   # 00 transparent .. FF opaque

# Detect background frame size to keep subtitles geometry correct
