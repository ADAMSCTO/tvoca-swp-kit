#!/usr/bin/env bash
# Make a Bryce (male) short with centered, safe-frame captions.

# ---- Settings you can tweak ----
MODEL="C:/Users/acade/Downloads/piper male voices/en_US-bryce-medium.onnx"
TXT="/c/jf/jirehfaith_swp_kit/voice/build/anxiety_en.txt"
SRT_IN="/c/jf/jirehfaith_swp_kit/voice/build/anxiety_en.srt"
SHIFT_MS="-300"               # try -400/-500 if captions still lag Bryce
FONT_SIZE=28
MARGIN_V=140                  # push a bit lower
MARGIN_L=140                  # safe left/right so first words don’t clip
MARGIN_R=140

# ---- Fixed paths ----
WAV_DIR="/c/jf/jirehfaith_swp_kit/voice/wavs"
WAV="${WAV_DIR}/anxiety_en_bryce.wav"
SRT_OUT="/c/jf/jirehfaith_swp_kit/voice/build/anxiety_en.male.shift.srt"
BG="/c/jf/jirehfaith_swp_kit/assets/bg/solid_1080x1920.png"
OUT="/c/jf/jirehfaith_swp_kit/out/anxiety_en_bryce_CAPFIX_shift${SHIFT_MS}ms_fs${FONT_SIZE}_mv${MARGIN_V}_mlr${MARGIN_L}.mp4"
RENDER="/c/jf/jirehfaith_swp_kit/scripts/render_short_ffmpeg.sh"

mkdir -p "$WAV_DIR"

# ---- Find piper (PATH first, then repo-local) ----
if command -v piper >/dev/null 2>&1; then
  PIPER="piper"
elif [ -f "/c/jf/jirehfaith_swp_kit/piper/piper.exe" ]; then
  PIPER="/c/jf/jirehfaith_swp_kit/piper/piper.exe"
else
  echo "❌ Could not find 'piper' or repo 'piper.exe'." ; exit 1
fi

# ---- Synthesize Bryce WAV ----
echo "[bryce] synthesizing → $WAV"
"$PIPER" -m "$MODEL" --length_scale 0.95 --noise_scale 0.60 --noise_w 0.90 -f "$WAV" < "$TXT" || {
  echo "❌ Piper synthesis failed." ; exit 2; }

# ---- Build a shifted SRT for Bryce timing ----
echo "[bryce] shifting SRT by ${SHIFT_MS} ms → $SRT_OUT"
awk -v SHIFT_MS="$SHIFT_MS" '
function to_ms(h,m,s,ms){ return (((h*60)+m)*60 + s)*1000 + ms }
function from_ms(T,ms,s,m,h){ if(T<0)T=0; ms=T%1000; T=int(T/1000); s=T%60; T=int(T/60); m=T%60; h=int(T/60);
  return sprintf("%02d:%02d:%02d,%03d",h,m,s,ms) }
# shift only timing lines, pass others through
/^[0-9]+:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]+:[0-9]{2}:[0-9]{2},[0-9]{3}$/ {
  split($1,a,":|,"); split($3,b,":|,");
  s=to_ms(a[1],a[2],a[3],a[4]) + SHIFT_MS
  e=to_ms(b[1],b[2],b[3],b[4]) + SHIFT_MS
  print from_ms(s) " --> " from_ms(e); next
}{ print }' "$SRT_IN" > "$SRT_OUT" || { echo "❌ SRT shift failed." ; exit 3; }

# ---- Render with safe-frame margins & centered captions ----
echo "[bryce] rendering → $OUT"
FONT_SIZE="$FONT_SIZE" MARGIN_V="$MARGIN_V" MARGIN_L="$MARGIN_L" MARGIN_R="$MARGIN_R" \
bash "$RENDER" "$BG" "$WAV" "$SRT_OUT" "$OUT" || { echo "❌ Render failed." ; exit 4; }

echo
echo "✅ Done."
echo "Open manually:"
echo "  $(cygpath -w "$OUT")"
