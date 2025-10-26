#!/usr/bin/env bash
# Render a 9:16 short (1080x1920) from: BG (image/video) + WAV + SRT (burned)
# Usage:
#   render_short_ffmpeg.sh <bg_path> <wav_path> <srt_path> <out_mp4>
# Notes:
#   - BG can be a still image (jpg/png/webp) or a video; stills are looped to audio duration
#   - Captions are burned with libass from the SRT
#   - Output: H.264 + AAC, 1080x1920, 30 fps

set -euo pipefail

BG="${1:-}"; WAV="${2:-}"; SRT="${3:-}"; OUT="${4:-}"
[ -n "$BG" ] && [ -n "$WAV" ] && [ -n "$SRT" ] && [ -n "$OUT" ] || {
  echo "Usage: $(basename "$0") <bg_path> <wav_path> <srt_path> <out_mp4>"; exit 1; }

[ -f "$BG" ]  || { echo "Missing BG:  $BG";  exit 2; }
[ -f "$WAV" ] || { echo "Missing WAV: $WAV"; exit 3; }
[ -f "$SRT" ] || { echo "Missing SRT: $SRT"; exit 4; }

# Duration of the WAV (seconds)
DUR="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$WAV")"

# Convert MSYS path to Windows path for libass, then escape for ffmpeg subtitles filter
# Example: /c/jf/.. -> C:\jf\..  ->  C\:\\jf\\..  (ffmpeg wants colon + backslashes escaped inside the filter)
SRT_WIN="$(printf '%s\n' "$SRT" | sed -E 's#^/c/#C:/#; s#/#\\#g')"
SRT_FILT_PATH="$(printf '%s' "$SRT_WIN" | sed -E 's#\\#\\\\#g; s#:#\\:#g')"

# Tunables via env
FONT_NAME="${FONT_NAME:-Arial}"
FONT_SIZE="${FONT_SIZE:-36}"
MARGIN_V="${MARGIN_V:-80}"
ALIGN="${ALIGN:-2}"
MARGIN_L="${MARGIN_L:-80}"
MARGIN_R="${MARGIN_R:-80}"
OUTLINE_PX="${OUTLINE_PX:-3}"
SHADOW_PX="${SHADOW_PX:-0}"
PRIMARY_COLOR="${PRIMARY_COLOR:-&H00FFFFFF}"   # white
OUTLINE_COLOR="${OUTLINE_COLOR:-&H00000000}"   # black

# Subtitle style
ASS_STYLE="FontName=${FONT_NAME},FontSize=${FONT_SIZE},PrimaryColour=${PRIMARY_COLOR},OutlineColour=${OUTLINE_COLOR},BorderStyle=1,Outline=${OUTLINE_PX},Shadow=${SHADOW_PX},Alignment=${ALIGN},MarginV=${MARGIN_V},MarginL=${MARGIN_L},MarginR=${MARGIN_R}"

# Build subtitles filter (escaped colons in force_style, and escaped Windows path)
SUB_FILT="subtitles='${SRT_FILT_PATH}':force_style='${ASS_STYLE//:/\\:}'"

# BG processing: emulate "cover" using increase + crop
BG_BASE_FILT='scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,format=yuv420p,setsar=1,vignette=angle=0.3:mode=forward,eq=brightness=-0.05:saturation=1.05'

echo "[render_short] SRT(msys)=$SRT"
echo "[render_short] SRT(win) =$SRT_WIN"
echo "[render_short] SRT(filt)=$SRT_FILT_PATH"
echo "[render_short] OUT      =$OUT"
echo "[render_short] FONT/MV  =${FONT_SIZE}/${MARGIN_V}"

# ---- Robust BG detection: still image vs real video ----
BG_FMT="$(ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$BG" || true)"
BG_DUR_META="$(ffprobe -v error -show_entries format=duration    -of default=nw=1:nk=1 "$BG" || true)"

# If it's an image format (png_pipe/jpeg_pipe/webp_pipe/image2*) OR there is no duration, treat as still
if [[ "$BG_FMT" =~ (image2|image2pipe|png_pipe|jpeg_pipe|mjpeg_pipe|bmp_pipe|webp_pipe) ]] || [ -z "${BG_DUR_META:-}" ]; then
  # ---- BG is a still image ----
  ffmpeg -y \
    -loop 1 -framerate 30 -t "$DUR" -i "$BG" -i "$WAV" \
    -filter_complex "[0:v]${BG_BASE_FILT},fps=30,setpts=N/(30*TB)[bg];[bg]${SUB_FILT}[v]" \
    -map "[v]" -map 1:a:0 \
    -c:v libx264 -profile:v high -crf 18 -pix_fmt yuv420p -preset veryfast -r 30 \
    -c:a aac -b:a 128k -ar 48000 -movflags +faststart \
    "$OUT"
else
  # ---- BG is a video ----
  ffmpeg -y \
    -i "$BG" -i "$WAV" \
    -filter_complex "[0:v]${BG_BASE_FILT},fps=30,setpts=PTS-STARTPTS[bg];[bg]${SUB_FILT}[v]" \
    -map "[v]" -map 1:a:0 \
    -t "$DUR" \
    -c:v libx264 -profile:v high -crf 18 -pix_fmt yuv420p -preset veryfast -r 30 \
    -c:a aac -b:a 128k -ar 48000 -movflags +faststart \
    "$OUT"
fi

echo "OK → $OUT"
