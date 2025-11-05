#!/usr/bin/env bash
# Usage: make_vertical_boxed.sh BG.png INPUT.wav INPUT.srt OUT.mp4
# Defaults (override via env):
#   FONT_NAME=Arial FONT_SIZE=150  MARGIN_L=160  MARGIN_R=160  MARGIN_V=0  BOX_OPA=96  LEAD_MS=200
#   TOP_BANNER=""  BANNER_SECONDS=1.50  TITLE_GAP=0.20
# Behavior:
# - Strict 9:16 render (PlayRes 1080x1920)
# - CenterBox captions (Alignment=5, BorderStyle=3)
# - Open-Title shows 0–BANNER_SECONDS (CenterBox). If the first caption would start before
#   BANNER_SECONDS + TITLE_GAP, we shift ALL captions forward by the minimal delta.
set -euo pipefail

BG="${1:?need BG image (png/jpg)}"
WAV="${2:?need WAV file}"
SRT_IN="${3:?need SRT file}"
OUT="${4:?need output MP4}"

# Caption appearance
FONT_NAME="${FONT_NAME:-Arial}"
FONT_SIZE="${FONT_SIZE:-150}"
MARGIN_L="${MARGIN_L:-160}"
MARGIN_R="${MARGIN_R:-160}"
MARGIN_V="${MARGIN_V:-0}"
BOX_OPA="${BOX_OPA:-96}"      # BackColour alpha AABBGGRR
LEAD_MS="${LEAD_MS:-200}"

# Title + gap control
TOP_BANNER="${TOP_BANNER:-}"
BANNER_SECONDS="${BANNER_SECONDS:-1.50}"
TITLE_GAP="${TITLE_GAP:-0.20}"            # extra space after title ends
TOP_FONT_SIZE="${TOP_FONT_SIZE:-$(( ${FONT_SIZE:-150} + 8 ))}"

# Fixed vertical PlayRes
PRX=1080; PRY=1920

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
BUILD="$ROOT/voice/build"
OUTDIR="$(dirname "$OUT")"
mkdir -p "$BUILD" "$OUTDIR"

# --- helpers -----------------------------------------------------------------
to_lf() { awk '{sub(/\r$/,""); print}' "$1" > "$2"; }
count_dialogue(){ grep -c '^Dialogue:' "$1" || true; }

normalize_ass() {
  local ass="$1"
  if ! grep -q '^PlayResX:' "$ass"; then
    awk -v x="$PRX" -v y="$PRY" 'BEGIN{a=0} {print; if(!a && $0=="[Script Info]"){print "PlayResX: "x; print "PlayResY: "y; a=1}}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
  fi
  awk -v x="$PRX" -v y="$PRY" '{sub(/^PlayResX:.*/,"PlayResX: "x); sub(/^PlayResY:.*/,"PlayResY: "y);} {print}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"

  local STYLE_LINE="Style: CenterBox,${FONT_NAME},${FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,&H${BOX_OPA}000000,0,0,0,0,100,100,0,0,3,0,0,5,${MARGIN_L},${MARGIN_R},${MARGIN_V},1"
  if grep -q '^Style: CenterBox,' "$ass"; then
    sed -i -E "s|^Style: CenterBox,.*$|${STYLE_LINE}|" "$ass"
  else
    awk -v ins="$STYLE_LINE" '/^\[V4\+ Styles\]/{print; getline; print; print ins; next} {print}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
  fi

  # Switch all dialogue to CenterBox (field 4)
  awk -F',' 'BEGIN{OFS=","} /^Dialogue:/{ $4="CenterBox" } {print}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
}

# Shift all Dialogue timestamps by SHIFT_MS (can be fractional, e.g., 120 = 0.12s)
shift_ass_times() {
  local ass_in="$1" ass_out="$2" shift_ms="$3"
  awk -F',' -v OFS="," -v SH=shift_ms '
    function hms_to_ms(t, a){return match(t,/^([0-9]+):([0-9]{2}):([0-9]{2})\.([0-9]{2})$/,a)?(a[1]*3600000+a[2]*60000+a[3]*1000+a[4]*10):-1}
    function ms_to_hms(MS,cs,s,m,h){if(MS<0) MS=0; cs=int((MS%1000)/10); s=int((MS/1000)%60); m=int((MS/60000)%60); h=int(MS/3600000); return sprintf("%d:%02d:%02d.%02d",h,m,s,cs)}
    /^\[Script Info\]|^\[V4\+ Styles\]|^\[Events\]|^Format:/ {print; next}
    /^Dialogue:/{
      s=hms_to_ms($2); e=hms_to_ms($3);
      if(s>=0 && e>=0){ s=s+SH; e=e+SH; $2=ms_to_hms(s); $3=ms_to_hms(e) }
      print; next
    }
    {print}
  ' "$ass_in" > "$ass_out"
}

# Compute the minimum Dialogue start (ms); return 999999999 if none
min_start_ms() {
  awk -F',' '
    function hms_to_ms(t, a){return match(t,/^([0-9]+):([0-9]{2}):([0-9]{2})\.([0-9]{2})$/,a)?(a[1]*3600000+a[2]*60000+a[3]*1000+a[4]*10):-1}
    BEGIN{min=999999999}
    /^Dialogue:/{ m=hms_to_ms($2); if(m>=0 && m<min) min=m }
    END{ print min }
  ' "$1"
}

# --- 1) autosync SRT to WAV --------------------------------------------------
tmp_srt="$BUILD/.$(basename "$SRT_IN").lf.srt"; to_lf "$SRT_IN" "$tmp_srt"
SRT_SYNC="$BUILD/$(basename "${SRT_IN%.*}").autosync.srt"
bash "$TOOLS/srt_autosync.sh" "$tmp_srt" "$WAV" "$SRT_SYNC" "$LEAD_MS"

# --- 2) SRT->ASS -------------------------------------------------------------
ASS_RAW="$BUILD/$(basename "${SRT_IN%.*}").autosync.ass"
ffmpeg -hide_banner -y -i "$SRT_SYNC" -c:s ass "$ASS_RAW" >/dev/null 2>&1

# --- 3) normalize + (light) timestamp repair --------------------------------
ASS_NORM="$BUILD/$(basename "${ASS_RAW%.*}").norm.ass"; to_lf "$ASS_RAW" "$ASS_NORM"
normalize_ass "$ASS_NORM"
ASS_REPAIRED="$BUILD/$(basename "${ASS_RAW%.*}").repaired.ass"
if [[ -x "$TOOLS/ass_repair_bad_timestamps.sh" ]]; then
  bash "$TOOLS/ass_repair_bad_timestamps.sh" "$ASS_NORM" "$ASS_REPAIRED"
else
  cp -f "$ASS_NORM" "$ASS_REPAIRED"
fi

DCOUNT="$(count_dialogue "$ASS_REPAIRED")"
if [[ "${DCOUNT:-0}" -le 0 ]]; then
  echo "[err] No Dialogue events after normalization. Check SRT/ASS." >&2
  exit 7
fi

# --- 4) Gate the first caption to appear after the title ---------------------
if [[ -n "$TOP_BANNER" ]]; then
  need_ms=$(awk -v a="$BANNER_SECONDS" -v g="$TITLE_GAP" 'BEGIN{printf "%.0f",(a+g)*1000}')
  first_ms="$(min_start_ms "$ASS_REPAIRED")"
  if [[ "$first_ms" -lt "$need_ms" ]]; then
    delta_ms=$(( need_ms - first_ms ))
    ASS_SHIFTED="$BUILD/$(basename "${ASS_RAW%.*}").shifted.ass"
    shift_ass_times "$ASS_REPAIRED" "$ASS_SHIFTED" "$delta_ms"
    mv -f "$ASS_SHIFTED" "$ASS_REPAIRED"
    echo "[i] Gated first caption: +$((delta_ms))ms (first=${first_ms}ms < need=${need_ms}ms)"
  fi
fi

# --- 5) Optional Open-Title (CenterBox, 0–BANNER_SECONDS) --------------------
BASS_ESC=""
if [[ -n "$TOP_BANNER" ]]; then
  BASS="$BUILD/.open_title.${PRX}x${PRY}.ass"
  {
    echo "[Script Info]"
    echo "ScriptType: v4.00+"
    echo "PlayResX: ${PRX}"
    echo "PlayResY: ${PRY}"
    echo
    echo "[V4+ Styles]"
    echo "Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding"
    echo "Style: OpenTitle,${FONT_NAME},${TOP_FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,&H${BOX_OPA}000000,0,0,0,0,100,100,0,0,3,0,0,5,${MARGIN_L},${MARGIN_R},${MARGIN_V},1"
    echo
    echo "[Events]"
    echo "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
  } > "$BASS"

  esc_title="${TOP_BANNER//\\/\\\\}"; esc_title="${esc_title//\{/\{}"; esc_title="${esc_title//\}/\}}"; esc_title="${esc_title//$'\r'/}"; esc_title="${esc_title//$'\n'/\\N}"
  printf 'Dialogue: 0,0:00:00.00,0:00:%05.2f,OpenTitle,,0,0,0,,%s\n' "$BANNER_SECONDS" "$esc_title" >> "$BASS"

  BASS_MIXED="$(cygpath -m "$BASS")"; BASS_ESC="${BASS_MIXED/:/\\:}"
  echo "[i] Open-Title enabled (0–${BANNER_SECONDS}s): ${TOP_BANNER}"
fi

# --- 6) Build VF chain -------------------------------------------------------
ASS_MIXED="$(cygpath -m "$ASS_REPAIRED")"; ASS_ESC="${ASS_MIXED/:/\\:}"
BGVF="scale=${PRX}:${PRY}:force_original_aspect_ratio=increase,crop=${PRX}:${PRY}"

VF="${BGVF}"
if [[ -n "$BASS_ESC" ]]; then
  VF="${VF},ass=filename='${BASS_ESC}':original_size=${PRX}x${PRY}"
fi
VF="${VF},ass=filename='${ASS_ESC}':original_size=${PRX}x${PRY}"

# --- 7) Encode ---------------------------------------------------------------
ffmpeg -hide_banner -y -loop 1 -framerate 30 -i "$BG" -i "$WAV" \
  -vf "$VF" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT"

echo; echo "[OK] Rendered:"; cygpath -w "$OUT"
