#!/usr/bin/env bash
set -euo pipefail

OUTDIR="assets/bg"
mkdir -p "$OUTDIR"

# Fonts & brand assets
ARIAL="/c/Windows/Fonts/arial.ttf"
[ -f "$ARIAL" ] || { echo "ERROR: $ARIAL not found at $ARIAL"; exit 1; }

# Brand colors
ROYAL="0x6A0DAD"   # royal purple bars (top+bottom)
GOLD="0xD4AF37"    # gold URL text

# Heights
TOP_H=200          # height of top & bottom bars (px)

# Prefer transparent top banner (for perfect color match), else fall back
TOP_BANNER="assets/brand/top-T.png"
if [ ! -f "$TOP_BANNER" ]; then
  TOP_BANNER="assets/brand/top.png"
fi
use_top_banner=0
[ -f "$TOP_BANNER" ] && use_top_banner=1

# Optional logo fallback if no top banner
LOGO="assets/logo.png"
use_logo=0
[ -f "$LOGO" ] && use_logo=1

# 15 emotions
EMOTIONS=( anger anxiety despair fear financial_trials grief hope illness joy love peace perseverance relationship_trials success protection )

# Solid color fallback for mid area (only used if no bg_mid/EMOTION.png exists)
color_for () {
  case "$1" in
    anger) echo "0x2b0d0d" ;;
    anxiety) echo "0x101318" ;;
    despair) echo "0x1a1a1a" ;;
    fear) echo "0x0f1220" ;;
    financial_trials) echo "0x102018" ;;
    grief) echo "0x141416" ;;
    hope) echo "0x0e1a2b" ;;
    illness) echo "0x13201b" ;;
    joy) echo "0x162217" ;;
    love) echo "0x1a1016" ;;
    peace) echo "0x0e1820" ;;
    perseverance) echo "0x1a1e14" ;;
    relationship_trials) echo "0x1b1320" ;;
    success) echo "0x0f1d12" ;;
    protection) echo "0x12201a" ;;
    *) echo "0x101318" ;;
  esac
}

echo "Building 1080x1920 branded backgrounds into $OUTDIR"
for e in "${EMOTIONS[@]}"; do
  out="$OUTDIR/${e}.png"

  MID="assets/bg_mid/${e}.png"
  use_mid=0
  [ -f "$MID" ] && use_mid=1

  if [ "$use_top_banner" -eq 1 ]; then
    # With top banner (preferred):
    # Inputs:
    #   0: mid base (bg_mid/EMOTION.png) OR solid color plate
    #   1: top banner (keeps AR; fits inside 1080xTOP_H)
    #   2: bottom bar (royal 1080xTOP_H)
    #   3: top bar (royal 1080xTOP_H)
    if [ "$use_mid" -eq 1 ]; then
      ffmpeg -v error -y \
        -i "$MID" \
        -i "$TOP_BANNER" \
        -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
        -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
        -filter_complex "\
          [0:v] scale=1080:1920:flags=lanczos,format=rgba [base]; \
          [1:v] scale=1080:${TOP_H}:force_original_aspect_ratio=decrease:flags=lanczos [ban]; \
          [base][3:v] overlay=x=0:y=0 [topbar]; \
          [topbar][ban] overlay=x=(main_w-overlay_w)/2:y=( ${TOP_H}-overlay_h )/2 [withtop]; \
          [withtop][2:v] overlay=x=0:y=main_h-${TOP_H} [withbars]; \
          [withbars] drawtext=fontfile=${ARIAL}:text='jirehfaith.com':fontsize=54:fontcolor=${GOLD}:x=(w-text_w)/2:y=(h-${TOP_H})+(( ${TOP_H}-text_h)/2) \
        " \
        -frames:v 1 "$out"
    else
      bg="$(color_for "$e")"
      ffmpeg -v error -y \
        -f lavfi -i "color=c=${bg}:s=1080x1920:d=0.1" \
        -i "$TOP_BANNER" \
        -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
        -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
        -filter_complex "\
          [0:v] format=rgba [base]; \
          [1:v] scale=1080:${TOP_H}:force_original_aspect_ratio=decrease:flags=lanczos [ban]; \
          [base][3:v] overlay=x=0:y=0 [topbar]; \
          [topbar][ban] overlay=x=(main_w-overlay_w)/2:y=( ${TOP_H}-overlay_h )/2 [withtop]; \
          [withtop][2:v] overlay=x=0:y=main_h-${TOP_H} [withbars]; \
          [withbars] drawtext=fontfile=${ARIAL}:text='jirehfaith.com':fontsize=54:fontcolor=${GOLD}:x=(w-text_w)/2:y=(h-${TOP_H})+(( ${TOP_H}-text_h)/2) \
        " \
        -frames:v 1 "$out"
    fi
  else
    # Fallback: no banner. Use color bars as inputs and (optionally) overlay logo in top bar.
    if [ "$use_mid" -eq 1 ]; then
      if [ "$use_logo" -eq 1 ]; then
        ffmpeg -v error -y \
          -i "$MID" \
          -i "$LOGO" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -filter_complex "\
            [0:v] scale=1080:1920:flags=lanczos,format=rgba [base]; \
            [base][2:v] overlay=x=0:y=0 [topbar]; \
            [1:v] scale='min(600\,iw)':'-1' [lg]; \
            [topbar][lg] overlay=x=(main_w-overlay_w)/2:y=( ${TOP_H}-overlay_h )/2 [withlogo]; \
            [withlogo][3:v] overlay=x=0:y=main_h-${TOP_H} [withbars]; \
            [withbars] drawtext=fontfile=${ARIAL}:text='jirehfaith.com':fontsize=54:fontcolor=${GOLD}:x=(w-text_w)/2:y=(h-${TOP_H})+(( ${TOP_H}-text_h)/2) \
          " \
          -frames:v 1 "$out"
      else
        ffmpeg -v error -y \
          -i "$MID" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -filter_complex "\
            [0:v] scale=1080:1920:flags=lanczos,format=rgba [base]; \
            [base][1:v] overlay=x=0:y=0 [topbar]; \
            [topbar][2:v] overlay=x=0:y=main_h-${TOP_H} [withbars]; \
            [withbars] drawtext=fontfile=${ARIAL}:text='JirehFaith':fontsize=90:fontcolor=white:x=(w-text_w)/2:y=( ${TOP_H}-text_h)/2, \
                      drawtext=fontfile=${ARIAL}:text='jirehfaith.com':fontsize=54:fontcolor=${GOLD}:x=(w-text_w)/2:y=(h-${TOP_H})+(( ${TOP_H}-text_h)/2) \
          " \
          -frames:v 1 "$out"
      fi
    else
      bg="$(color_for "$e")"
      if [ "$use_logo" -eq 1 ]; then
        ffmpeg -v error -y \
          -f lavfi -i "color=c=${bg}:s=1080x1920:d=0.1" \
          -i "$LOGO" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -filter_complex "\
            [0:v] format=rgba [base]; \
            [base][2:v] overlay=x=0:y=0 [topbar]; \
            [1:v] scale='min(600\,iw)':'-1' [lg]; \
            [topbar][lg] overlay=x=(main_w-overlay_w)/2:y=( ${TOP_H}-overlay_h )/2 [withlogo]; \
            [withlogo][3:v] overlay=x=0:y=main_h-${TOP_H} [withbars]; \
            [withbars] drawtext=fontfile=${ARIAL}:text='jirehfaith.com':fontsize=54:fontcolor=${GOLD}:x=(w-text_w)/2:y=(h-${TOP_H})+(( ${TOP_H}-text_h)/2) \
          " \
          -frames:v 1 "$out"
      else
        ffmpeg -v error -y \
          -f lavfi -i "color=c=${bg}:s=1080x1920:d=0.1" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -f lavfi -i "color=c=${ROYAL}:s=1080x${TOP_H}:d=0.1" \
          -filter_complex "\
            [0:v] format=rgba [base]; \
            [base][1:v] overlay=x=0:y=0 [topbar]; \
            [topbar][2:v] overlay=x=0:y=main_h-${TOP_H} [withbars]; \
            [withbars] drawtext=fontfile=${ARIAL}:text='JirehFaith':fontsize=90:fontcolor=white:x=(w-text_w)/2:y=( ${TOP_H}-text_h)/2, \
                      drawtext=fontfile=${ARIAL}:text='jirehfaith.com':fontsize=54:fontcolor=${GOLD}:x=(w-text_w)/2:y=(h-${TOP_H})+(( ${TOP_H}-text_h)/2) \
          " \
          -frames:v 1 "$out"
      fi
    fi
  fi

  echo " - $out"
done

echo "Done."
