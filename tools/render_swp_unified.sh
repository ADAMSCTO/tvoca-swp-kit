#!/usr/bin/env bash
# Unified renderer for SWP videos (H & V) with enforced CenterBox style.
# Accepts SRT or ASS. For SRT: autosync -> ASS. For both: normalize -> repair -> burn with ass filter.
# Parity with vertical pipeline; adds robust BG fit and hook exports.
# Adds Open-Title overlay (TOP_BANNER env) shown only at t=0–1.50s without touching captions.
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
    function ms_to_hms(MS,cs,s,m,h){cs=int((MS%1000)/10);s=int((MS/1000)%60);m=int((MS/60000)%60);h=int(MS/3600000);return sprintf("%d:%02d:%02d.%02d",h,m,s,cs)}
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

derive_srt_sibling() {
  local asspath="$1" dir base s1 s2
  dir="$(dirname "$1")"
  base="$(basename "$1")"
  base="${base%.ass}"; base="${base%.autosync}"; base="${base%.norm}"; base="${base%.repaired}"
  s1="$dir/${base}.srt"; s2="$BUILD/${base}.srt"
  [[ -f "$s1" ]] && { echo "$s1"; return; }
  [[ -f "$s2" ]] && { echo "$s2"; return; }
  echo ""
}

log_i(){ echo "[i] $*"; }
log_w(){ echo "[warn] $*" >&2; }
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

# --- Auto-fallback: if 0 events, rebuild from sibling SRT -------------------
if [[ "${DCOUNT:-0}" -le 0 ]]; then
  log_w "0 Dialogue events after repair — attempting ASS→SRT recovery…"
  SIB_SRT="$(derive_srt_sibling "$ASS_RAW")"
  if [[ -n "$SIB_SRT" && -f "$SIB_SRT" ]]; then
    log_i "Found SRT sibling: $(cygpath -w "$SIB_SRT")"
    tmp_srt2="$BUILD/.$(basename "$SIB_SRT").lf.srt"; to_lf_file "$SIB_SRT" "$tmp_srt2"
    SRT_SYNC2="$BUILD/$(basename "${SIB_SRT%.*}").autosync.srt"
    export SRT_IN="$SIB_SRT"; run_hooks pre_autosync || true
    if [[ "$AUTOSYNC" == "0" ]]; then cp -f "$tmp_srt2" "$SRT_SYNC2"; log_i "Autosync disabled — copied sibling SRT to $(cygpath -w "$SRT_SYNC2")"
    else log_i "Autosync sibling SRT → $(cygpath -w "$SRT_SYNC2") (lead=${LEAD_MS}ms)"; bash "$TOOLS/srt_autosync.sh" "$tmp_srt2" "$WAV" "$SRT_SYNC2" "$LEAD_MS"; fi
    run_hooks post_autosync || true
    ASS_RAW2="$BUILD/$(basename "${SIB_SRT%.*}").autosync.ass"
    ffmpeg -hide_banner -y -i "$SRT_SYNC2" -c:s ass "$ASS_RAW2" >/dev/null 2>&1
    log_i "Rebuilt ASS from sibling SRT: $(cygpath -w "$ASS_RAW2")"
    ASS_NORM="$BUILD/$(basename "${ASS_RAW2%.*}").norm.ass"; to_lf_file "$ASS_RAW2" "$ASS_NORM"
    run_hooks pre_ass_normalize || true; normalize_ass "$ASS_NORM" || true
    ASS_REPAIRED="$BUILD/$(basename "${ASS_RAW2%.*}").repaired.ass"; repair_bad_ts "$ASS_NORM" "$ASS_REPAIRED"
    DCOUNT="$(count_dialogue "$ASS_REPAIRED")"
  else
    log_w "No SRT sibling found for recovery."
  fi
fi

if [[ "${DCOUNT:-0}" -le 0 ]]; then
  log_e "After repair, no Dialogue events remain in: $(cygpath -w "$ASS_REPAIRED")"
  log_e "libass would load 0 events — captions would be invisible. Investigate timestamps."
  exit 7
fi

# --- Paths for ass= filter ---------------------------------------------------
ASS_MIXED="$(cygpath -m "$ASS_REPAIRED")"; ASS_ESC="${ASS_MIXED/:/\\:}"

echo "[i] SIZE=${SIZE}  PlayRes=${PRX}x${PRY}  FONT=${FONT_NAME}/${FONT_SIZE}  MARGINS L/R/V=${MARGIN_L}/${MARGIN_R}/${MARGIN_V}  BOX_OPA=${BOX_OPA}"
echo "[i] BG=$(cygpath -w "$BG")"
echo "[i] WAV=$(cygpath -w "$WAV")"
echo "[i] ASS=$(cygpath -w "$ASS_REPAIRED")  (events=${DCOUNT})"

# --- Optional Open-Title (0–1.50s, CenterBox look, NO fade-in) ---------------
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
  printf '%s\n' "Dialogue: 0,0:00:00.00,0:00:01.50,OpenTitle,,0,0,0,,{\an5\b1}${esc_title}" >> "$BASS"
  BASS_MIXED="$(cygpath -m "$BASS")"; BASS_ESC="${BASS_MIXED/:/\\:}"
  echo "[i] Open-Title enabled (0–1.50s): ${TOP_BANNER}"
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
