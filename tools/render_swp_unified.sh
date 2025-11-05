#!/usr/bin/env bash
# Unified renderer for SWP videos (H & V) with enforced CenterBox style.
# Accepts SRT or ASS. For SRT: autosync -> ASS. For both: normalize -> repair -> optional gate -> burn with ass filter.
# Adds Open-Title overlay (TOP_BANNER env) shown only at t=0–BANNER_SECONDS without touching captions unless gating is needed.
set -euo pipefail

# --- Args --------------------------------------------------------------------
SIZE=""; if [[ "${1:-}" == --size=* ]]; then SIZE="${1#--size=}"; shift; fi
BG="${1:?need BG image}"
WAV="${2:?need WAV file}"
CAP_IN="${3:?need SRT or ASS captions}"
OUT="${4:?need output MP4}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tools"
BUILD="$ROOT/voice/build"
mkdir -p "$BUILD" "$(dirname "$OUT")"

# --- Hooks runtime -----------------------------------------------------------
if [[ -f "$ROOT/tools/hooks/lib/hooks.sh" ]]; then
  # shellcheck source=/dev/null
  . "$ROOT/tools/hooks/lib/hooks.sh"
else
  run_hooks() { return 0; }
fi
LOG_FILE="$BUILD/render.log"; : >"$LOG_FILE" 2>/dev/null || true
WORKDIR="$BUILD"
OUT_MP4="$OUT"
HOOK_OUT_MP4="$OUT"

: "${TMPDIR:=$WORKDIR}"
export LOG_FILE WORKDIR OUT_MP4 HOOK_OUT_MP4 TMPDIR
export SIZE BG WAV OUT

run_hooks pre_render || true

# --- Defaults (env) ----------------------------------------------------------
FONT_NAME="${FONT_NAME:-Arial}"
FONT_SIZE="${FONT_SIZE:-96}"
MARGIN_L="${MARGIN_L:-140}"
MARGIN_R="${MARGIN_R:-140}"
MARGIN_V="${MARGIN_V:-0}"
BOX_OPA="${BOX_OPA:-96}"
LEAD_MS="${LEAD_MS:-200}"
AUTOSYNC="${AUTOSYNC:-1}"
BG_FIT="${BG_FIT:-cover}"

TOP_BANNER="${TOP_BANNER:-}"
BANNER_SECONDS="${BANNER_SECONDS:-1.50}"
TITLE_GAP="${TITLE_GAP:-0.20}"                   # extra gap after title
TOP_FONT_SIZE="${TOP_FONT_SIZE:-$(( ${FONT_SIZE:-96} + 8 ))}"

# --- PlayRes -----------------------------------------------------------------
PRX=1920; PRY=1080
if [[ "$SIZE" == "1080x1920" ]]; then PRX=1080; PRY=1920; fi
if [[ -z "$SIZE" ]]; then SIZE="${PRX}x${PRY}"; fi

# --- Helpers -----------------------------------------------------------------
to_lf_file() { local in="$1" out="$2"; awk '{sub(/\r$/,""); print}' "$in" > "$out"; }

normalize_ass() {
  local ass="$1"
  if ! grep -q '^PlayResX:' "$ass"; then
    awk -v x="$PRX" -v y="$PRY" 'BEGIN{added=0}{ print; if(!added && $0=="[Script Info]"){ print "PlayResX: " x; print "PlayResY: " y; added=1 } }' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
  fi
  awk -v x="$PRX" -v y="$PRY" '{sub(/^PlayResX: .*/,"PlayResX: " x); sub(/^PlayResY: .*/,"PlayResY: " y);} {print}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
  local STYLE_LINE="Style: CenterBox,${FONT_NAME},${FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,&H${BOX_OPA}000000,0,0,0,0,100,100,0,0,3,0,0,5,${MARGIN_L},${MARGIN_R},${MARGIN_V},1"
  if grep -q '^Style: CenterBox,' "$ass"; then
    sed -i -E "s|^Style: CenterBox,.*$|${STYLE_LINE}|" "$ass"
  else
    awk -v ins="$STYLE_LINE" '/^\[V4\+ Styles\]/{print; getline; print; print ins; next}{print}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
  fi
  awk -F',' 'BEGIN{OFS=","} /^Dialogue:/{ $4="CenterBox" } {print}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
}

repair_bad_ts() {
  local ass_in="$1" ass_out="$2"
  if [[ -x "$TOOLS/ass_repair_bad_timestamps.sh" ]]; then
    bash "$TOOLS/ass_repair_bad_timestamps.sh" "$ass_in" "$ass_out"; return
  fi
  awk -F',' '
    function hms_to_ms(t,  a){return match(t,/^([0-9]+):([0-9]{2}):([0-9]{2})\.([0-9]{2})$/,a)?(a[1]*3600000+a[2]*60000+a[3]*1000+a[4]*10):-1}
    function ms_to_hms(MS,cs,s,m,h){if(MS<0) MS=0; cs=int((MS%1000)/10); s=int((MS/1000)%60); m=int((MS/60000)%60); h=int(MS/3600000);return sprintf("%d:%02d:%02d.%02d",h,m,s,cs)}
    BEGIN{OFS=","}
    /^\[Script Info\]|^\[V4\+ Styles\]|^\[Events\]|^Format:|^Comment:/{print;next}
    /^Dialogue:/{
      s=hms_to_ms($2); e=hms_to_ms($3);
      if (s<0 || e<0) next;
      if (e<=s) e=s+100;
      $2=ms_to_hms(s); $3=ms_to_hms(e); print; next
    }
    {print}
  ' "$ass_in" > "$ass_out"
}

count_dialogue() { grep -c '^Dialogue:' "$1" || true; }

min_start_ms() {
  awk -F',' '
    function hms_to_ms(t, a){return match(t,/^([0-9]+):([0-9]{2}):([0-9]{2})\.([0-9]{2})$/,a)?(a[1]*3600000+a[2]*60000+a[3]*1000+a[4]*10):-1}
    BEGIN{min=999999999}
    /^Dialogue:/{ m=hms_to_ms($2); if(m>=0 && m<min) min=m }
    END{ print min }
  ' "$1"
}

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

log_i(){ echo "[i] $*"; }
log_w(){ echo "[warn] $*"; }
log_e(){ echo "[err] $*" >&2; }

# --- Get ASS (convert from SRT if needed) ------------------------------------
ext="$(echo "${CAP_IN##*.}" | tr '[:upper:]' '[:lower:]')"
ASS_RAW=""; SRT_IN=""

if [[ "$ext" == "ass" ]]; then
  ASS_RAW="$CAP_IN"; log_i "Input captions detected as ASS: $(cygpath -w "$ASS_RAW")"
else
  SRT_IN="$CAP_IN"; export SRT_IN; log_i "Input captions detected as SRT: $(cygpath -w "$SRT_IN")"
  tmp_srt="$BUILD/.$(basename "$SRT_IN").lf.srt"; to_lf_file "$SRT_IN" "$tmp_srt"
  SRT_SYNC="$BUILD/$(basename "${SRT_IN%.*}").autosync.srt"
  run_hooks pre_autosync || true
  if [[ "$AUTOSYNC" == "0" ]]; then cp -f "$tmp_srt" "$SRT_SYNC"; log_i "Autosync disabled — copied SRT to $(cygpath -w "$SRT_SYNC")"
  else log_i "Autosync SRT → $(cygpath -w "$SRT_SYNC") (lead=${LEAD_MS}ms)"; bash "$TOOLS/srt_autosync.sh" "$tmp_srt" "$WAV" "$SRT_SYNC" "$LEAD_MS"; fi
  run_hooks post_autosync || true
  ASS_RAW="$BUILD/$(basename "${SRT_IN%.*}").autosync.ass"
  ffmpeg -hide_banner -y -i "$SRT_SYNC" -c:s ass "$ASS_RAW" >/dev/null 2>&1
  log_i "Converted SRT→ASS: $(cygpath -w "$ASS_RAW")"
fi

# --- Normalize + repair (always) --------------------------------------------
ASS_NORM="$BUILD/$(basename "${ASS_RAW%.*}").norm.ass"; to_lf_file "$ASS_RAW" "$ASS_NORM"
run_hooks pre_ass_normalize || true; normalize_ass "$ASS_NORM" || true
ASS_REPAIRED="$BUILD/$(basename "${ASS_RAW%.*}").repaired.ass"; repair_bad_ts "$ASS_NORM" "$ASS_REPAIRED"
DCOUNT="$(count_dialogue "$ASS_REPAIRED")"

if [[ "${DCOUNT:-0}" -le 0 ]]; then
  log_e "After repair, no Dialogue events remain in: $(cygpath -w "$ASS_REPAIRED")"
  exit 7
fi

# --- Gate first caption to be after title ------------------------------------
if [[ -n "$TOP_BANNER" ]]; then
  need_ms=$(awk -v a="$BANNER_SECONDS" -v g="$TITLE_GAP" 'BEGIN{printf "%.0f",(a+g)*1000}')
  first_ms="$(min_start_ms "$ASS_REPAIRED")"
  if [[ "$first_ms" -lt "$need_ms" ]]; then
    delta_ms=$(( need_ms - first_ms ))
    ASS_SHIFTED="$BUILD/$(basename "${ASS_RAW%.*}").shifted.ass"
    shift_ass_times "$ASS_REPAIRED" "$ASS_SHIFTED" "$delta_ms"
    mv -f "$ASS_SHIFTED" "$ASS_REPAIRED"
    log_i "Gated first caption: +${delta_ms}ms (first=${first_ms}ms < need=${need_ms}ms)"
  fi
fi

# --- Paths for ass= filter ---------------------------------------------------
ASS_MIXED="$(cygpath -m "$ASS_REPAIRED")"; ASS_ESC="${ASS_MIXED/:/\\:}"

echo "[i] SIZE=${SIZE}  PlayRes=${PRX}x${PRY}  FONT=${FONT_NAME}/${FONT_SIZE}  MARGINS L/R/V=${MARGIN_L}/${MARGIN_R}/${MARGIN_V}  BOX_OPA=${BOX_OPA}"
echo "[i] BG=$(cygpath -w "$BG")"
echo "[i] WAV=$(cygpath -w "$WAV")"
echo "[i] ASS=$(cygpath -w "$ASS_REPAIRED")  (events=${DCOUNT})"

# --- Optional Open-Title (0–BANNER_SECONDS, CenterBox) -----------------------
BASS_ESC=""
if [[ -n "$TOP_BANNER" ]]; then
  BASS="$BUILD/.open_title.${PRX}x${PRY}.ass"; : > "$BASS"
  printf '%s\n' "[Script Info]" "ScriptType: v4.00+" "PlayResX: ${PRX}" "PlayResY: ${PRY}" >> "$BASS"
  printf '%s\n' "[V4+ Styles]" >> "$BASS"
  printf '%s\n' "Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding" >> "$BASS"
  printf '%s\n' "Style: OpenTitle,${FONT_NAME},${TOP_FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,&H${BOX_OPA}000000,0,0,0,0,100,100,0,0,3,0,0,5,${MARGIN_L},${MARGIN_R},${MARGIN_V},1" >> "$BASS"
  printf '%s\n' "[Events]" >> "$BASS"
  printf '%s\n' "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text" >> "$BASS"
  esc_title="${TOP_BANNER//\\/\\\\}"; esc_title="${esc_title//\{/\{}"; esc_title="${esc_title//\}/\}}"; esc_title="${esc_title//$'\r'/}"; esc_title="${esc_title//$'\n'/\\N}"
  printf '%s\n' "Dialogue: 0,0:00:00.00,0:00:${BANNER_SECONDS},OpenTitle,,0,0,0,,${esc_title}" >> "$BASS"
  BASS_MIXED="$(cygpath -m "$BASS")"; BASS_ESC="${BASS_MIXED/:/\\:}"
  echo "[i] Open-Title enabled (0–${BANNER_SECONDS}s): ${TOP_BANNER}"
fi

# --- Background fit ----------------------------------------------------------
BGVF=""
case "$BG_FIT" in
  contain) BGVF="scale=${PRX}:${PRY}:force_original_aspect_ratio=decrease,pad=${PRX}:${PRY}:(ow-iw)/2:(oh-ih)/2" ;;
  none)    BGVF="scale=${PRX}:${PRY}:flags=fast_bilinear" ;;
  *)       BGVF="scale=${PRX}:${PRY}:force_original_aspect_ratio=increase,crop=${PRX}:${PRY}" ;;
esac

# --- Build VF chain ----------------------------------------------------------
VF="${BGVF}"
if [[ -n "$BASS_ESC" ]]; then VF="${VF},ass=filename='${BASS_ESC}':original_size=${PRX}x${PRY}"; fi
VF="${VF},ass=filename='${ASS_ESC}':original_size=${PRX}x${PRY}"
if [[ -n "${EXTRA_ASS_FILTER:-}" ]]; then VF="${VF}${EXTRA_ASS_FILTER}"; fi

export INPUT_WAV="$WAV" INPUT_SRT="${SRT_IN:-}" INPUT_ASS="$ASS_REPAIRED"
run_hooks pre_burn || true

# --- Render ------------------------------------------------------------------
ffmpeg -hide_banner -y -loop 1 -framerate 30 -i "$BG" -i "$WAV" \
  -vf "$VF" \
  -force_key_frames 0 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT"

run_hooks post_render || true
echo; echo "[OK] Rendered:"; cygpath -w "$OUT"
