#!/usr/bin/env bash
# Unified renderer for SWP videos (H & V) with enforced CenterBox style.
# SRT path: autosync (pass1) → optional tempo-match voice → autosync (pass2) → ASS → normalize → repair → CenterBox-enforce → optional gate → burn.
# ASS path: normalize → repair → CenterBox-enforce → optional gate → burn.
#
# Core anti “captions-ahead” strategy:
# 1) Keep captions aligned to audio analytically (autosync + onset).
# 2) Apply the *final micro-correction to AUDIO* (trim/delay) instead of shifting captions,
#    so player AAC priming/edit-lists cannot reintroduce a visible offset.
#
# Env toggles (sane defaults):
#   AUTOSYNC=1             Enable SRT↔WAV autosync passes
#   TEMPO_MATCH=1          Time-stretches voice to SRT duration before pass-2 autosync
#   AUTO_ONSET_ALIGN=1     Measure first audio onset and correct residual offset
#   APPLY_SHIFT_TO_AUDIO=1 Apply the residual correction to audio (preferred). Set 0 to shift captions instead.
#
set -euo pipefail

# --- Args --------------------------------------------------------------------
SIZE=""; if [[ "${1:-}" == --size=* ]]; then SIZE="${1#--size=}"; shift; fi
BG="${1:?need BG image}"
WAV_IN="${2:?need WAV file}"
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
export SIZE BG WAV_IN OUT

run_hooks pre_render || true

# --- Defaults (env) ----------------------------------------------------------
FONT_NAME="${FONT_NAME:-Arial}"
FONT_SIZE="${FONT_SIZE:-96}"

# Manual caption shift is opt-in; empty means none.
CAPTION_SHIFT_MS="${CAPTION_SHIFT_MS:-}"

MARGIN_L="${MARGIN_L:-140}"
MARGIN_R="${MARGIN_R:-140}"
MARGIN_V="${MARGIN_V:-0}"
BOX_OPA="${BOX_OPA:-96}"

# IMPORTANT: default lead 0 (no pre-bias into autosync)
LEAD_MS="${LEAD_MS:-0}"

AUTOSYNC="${AUTOSYNC:-1}"
BG_FIT="${BG_FIT:-cover}"

# Tempo matching (voice to captions)
TEMPO_MATCH="${TEMPO_MATCH:-1}"

TOP_BANNER="${TOP_BANNER:-}"
BANNER_SECONDS="${BANNER_SECONDS:-1.50}"
TITLE_GAP="${TITLE_GAP:-0.20}"
TOP_FONT_SIZE="${TOP_FONT_SIZE:-$(( ${FONT_SIZE:-96} + 8 ))}"

# Anti-lead controls
AUTO_ONSET_ALIGN="${AUTO_ONSET_ALIGN:-1}"
APPLY_SHIFT_TO_AUDIO="${APPLY_SHIFT_TO_AUDIO:-1}" # << preferred
ONSET_NOISE_DB="${ONSET_NOISE_DB:-35}"            # dB threshold (positive here; negated in filter)
ONSET_MIN_DUR="${ONSET_MIN_DUR:-0.18}"            # seconds
MAX_ONSET_SHIFT_MS="${MAX_ONSET_SHIFT_MS:-2500}"  # bound for residual correction
AAC_PRIMING_MS="${AAC_PRIMING_MS:-0}"             # 0: rely on measured onset

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
  awk -F',' -v OFS="," -v SH="$shift_ms" '
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

first_audio_onset_ms() {
  # Uses ffmpeg silencedetect to find the first end of initial silence.
  # Returns 0 if none found.
  local wav="$1" noise_db="$2" mindur="$3"
  local out; out="$(ffmpeg -hide_banner -nostats -i "$wav" -af "silencedetect=noise=-${noise_db}dB:d=${mindur}" -f null - 2>&1 || true)"
  awk '
    /silence_end:/ { split($0,a,"silence_end:"); sub(/^[ \t]*/,"",a[2]); split(a[2],b," "); t=b[1]; if(t!="" && t>=0){ ms=int(t*1000+0.5); print ms; exit } }
  ' <<<"$out"
}

log_i(){ echo "[i] $*"; }
log_w(){ echo "[warn] $*"; }
log_e(){ echo "[err] $*" >&2; }

# --- Get ASS (convert from SRT if needed) ------------------------------------
ext="$(echo "${CAP_IN##*.}" | tr '[:upper:]' '[:lower:]')"
ASS_RAW=""; SRT_IN=""; SRT_SYNC=""; SRT_SYNC2=""
AUTOSYNC_LOG="$BUILD/.autosync_pass1.log"
AUTOSYNC2_LOG="$BUILD/.autosync_pass2.log"

WAV="$WAV_IN"

if [[ "$ext" == "ass" ]]; then
  ASS_RAW="$CAP_IN"; log_i "Input captions detected as ASS: $(cygpath -w "$ASS_RAW")"
else
  SRT_IN="$CAP_IN"; export SRT_IN; log_i "Input captions detected as SRT: $(cygpath -w "$SRT_IN")"
  tmp_srt="$BUILD/.$(basename "$SRT_IN").lf.srt"; to_lf_file "$SRT_IN" "$tmp_srt"

  # --- Autosync (Pass 1) : original WAV vs original SRT ----------------------
  SRT_SYNC="$BUILD/$(basename "${SRT_IN%.*}").autosync.srt"
  run_hooks pre_autosync || true
  if [[ "$AUTOSYNC" == "0" ]]; then
    cp -f "$tmp_srt" "$SRT_SYNC"; log_i "Autosync disabled — copied SRT to $(cygpath -w "$SRT_SYNC")"
  else
    log_i "Autosync (pass 1) → $(cygpath -w "$SRT_SYNC") (lead=${LEAD_MS}ms)"
    bash "$TOOLS/srt_autosync.sh" "$tmp_srt" "$WAV" "$SRT_SYNC" "$LEAD_MS" "0" | tee "$AUTOSYNC_LOG"
  fi
  run_hooks post_autosync || true

  # --- Optional: tempo-match voice to pass-1 SRT (duration) ------------------
  if [[ "${TEMPO_MATCH}" == "1" ]]; then
    WAV_MATCH="$BUILD/.tmp.voice.match.wav"
    log_i "Matching voice tempo to (pass 1) SRT duration…"
    bash "$TOOLS/auto_voice_tempo.sh" "$WAV" "$SRT_SYNC" "$WAV_MATCH" >/dev/null 2>&1
    WAV="$WAV_MATCH"
    log_i "Matched voice tempo via auto_voice_tempo.sh: $(cygpath -w "$WAV")"

    # --- Autosync (Pass 2) : matched WAV vs pass-1 SRT -----------------------
    SRT_SYNC2="$BUILD/$(basename "${SRT_IN%.*}").autosync.pass2.srt"
    log_i "Autosync (pass 2) → $(cygpath -w "$SRT_SYNC2") (lead=${LEAD_MS}ms)"
    bash "$TOOLS/srt_autosync.sh" "$SRT_SYNC" "$WAV" "$SRT_SYNC2" "$LEAD_MS" "0" | tee "$AUTOSYNC2_LOG"
    USE_SRT="$SRT_SYNC2"
  else
    USE_SRT="$SRT_SYNC"
  fi

  # Convert the final SRT to ASS
  ASS_RAW="$BUILD/$(basename "${SRT_IN%.*}").autosync.ass"
  ffmpeg -hide_banner -y -i "$USE_SRT" -c:s ass "$ASS_RAW" >/dev/null 2>&1
  log_i "Converted SRT→ASS: $(cygpath -w "$ASS_RAW")"
fi

# --- Normalize + repair (always) --------------------------------------------
ASS_NORM="$BUILD/$(basename "${ASS_RAW%.*}").norm.ass"; to_lf_file "$ASS_RAW" "$ASS_NORM"
run_hooks pre_ass_normalize || true; normalize_ass "$ASS_NORM" || true
ASS_REPAIRED="$BUILD/$(basename "${ASS_RAW%.*}").repaired.ass"; repair_bad_ts "$ASS_NORM" "$ASS_REPAIRED"

# --- Enforce CenterBox-only overrides (strip {\anX}, {\pos()}, {\move()}) ----
ASS_CENTERBOX="$BUILD/$(basename "${ASS_RAW%.*}").centerbox.ass"
bash "$TOOLS/ass_force_centerbox.sh" "$ASS_REPAIRED" "$ASS_CENTERBOX"
ASS_REPAIRED="$ASS_CENTERBOX"
log_i "Enforced CenterBox ASS: $(cygpath -w "$ASS_REPAIRED")"

# --- Apply manual shift only if explicitly set -------------------------------
if [[ -n "${CAPTION_SHIFT_MS:-}" && "${CAPTION_SHIFT_MS}" != "0" ]]; then
  ASS_SHIFTED="$BUILD/$(basename "${ASS_RAW%.*}").shifted.ass"
  shift_ass_times "$ASS_REPAIRED" "$ASS_SHIFTED" "$CAPTION_SHIFT_MS"
  mv -f "$ASS_SHIFTED" "$ASS_REPAIRED"
  log_i "Applied CAPTION_SHIFT_MS=${CAPTION_SHIFT_MS}ms to ASS"
fi

DCOUNT="$(count_dialogue "$ASS_REPAIRED")"
if [[ "${DCOUNT:-0}" -le 0 ]]; then
  log_e "After repair/CenterBox, no Dialogue events remain in: $(cygpath -w "$ASS_REPAIRED")"
  exit 7
fi

# --- Optional gate to keep title visible before first caption ----------------
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

# --- Final micro-alignment (onset) -------------------------------------------
# We compute a residual delta and by default apply it to AUDIO.
AF="anull"              # audio filter chain
AUDIO_PRE_OPTS=()       # e.g., -itsoffset sec before -i "$WAV"
if [[ "${AUTO_ONSET_ALIGN}" == "1" ]]; then
  onset_ms="$(first_audio_onset_ms "$WAV" "$ONSET_NOISE_DB" "$ONSET_MIN_DUR")"; [[ -z "${onset_ms:-}" ]] && onset_ms=0
  cap0_ms="$(min_start_ms "$ASS_REPAIRED")"
  # Positive delta: audio starts later than captions → we must advance audio (trim head).
  delta_ms=$(( onset_ms - cap0_ms + AAC_PRIMING_MS ))

  (( delta_ms >  MAX_ONSET_SHIFT_MS )) && delta_ms="$MAX_ONSET_SHIFT_MS"
  (( delta_ms < -MAX_ONSET_SHIFT_MS )) && delta_ms="-$MAX_ONSET_SHIFT_MS"

  if (( delta_ms != 0 )); then
    if [[ "${APPLY_SHIFT_TO_AUDIO}" == "1" ]]; then
      if (( delta_ms > 0 )); then
        # Advance audio by trimming the head inside the filter graph
        adv_s="$(awk -v ms="$delta_ms" 'BEGIN{printf "%.6f", ms/1000.0}')"
        AF="atrim=start=${adv_s},asetpts=PTS-STARTPTS"
        log_i "Final onset align (AUDIO advance): onset=${onset_ms}ms cap0=${cap0_ms}ms → advance audio ${delta_ms}ms"
      else
        # Delay audio by shifting its input timestamps using -itsoffset (robust for mono/stereo)
        d_ms=$(( -delta_ms ))
        d_s="$(awk -v ms="$d_ms" 'BEGIN{printf "%.6f", ms/1000.0}')"
        AUDIO_PRE_OPTS=( -itsoffset "$d_s" )
        AF="anull"
        log_i "Final onset align (AUDIO delay): onset=${onset_ms}ms cap0=${cap0_ms}ms → delay audio ${d_ms}ms"
      fi
    else
      ASS_SHIFTED="$BUILD/$(basename "${ASS_RAW%.*}").finalshift.ass"
      shift_ass_times "$ASS_REPAIRED" "$ASS_SHIFTED" "$delta_ms"
      mv -f "$ASS_SHIFTED" "$ASS_REPAIRED"
      log_i "Final onset align (CAPTIONS shift): onset=${onset_ms}ms cap0=${cap0_ms}ms → shift captions ${delta_ms}ms"
    fi
  else
    log_i "Final onset align: no correction needed (onset=${onset_ms}ms, cap0=${cap0_ms}ms)"
  fi
fi

# --- Paths for ass= filter ---------------------------------------------------
ASS_MIXED="$(cygpath -m "$ASS_REPAIRED")"; ASS_ESC="${ASS_MIXED/:/\\:}"

echo "[i] SIZE=${SIZE}  PlayRes=${PRX}x${PRY}  FONT=${FONT_NAME}/${FONT_SIZE}  MARGINS L/R/V=${MARGIN_L}/${MARGIN_R}/${MARGIN_V}  BOX_OPA=${BOX_OPA}"
echo "[i] BG=$(cygpath -w "$BG")"
echo "[i] WAV=$(cygpath -w "$WAV")"
echo "[i] ASS=$(cygpath -w "$ASS_REPAIRED")  (events=${DCOUNT})"

# --- Optional Open-Title (0–BANNER_SECONDS) ---------------------------------
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
if [[ -n "$BASS_ESC" ]]; then
  VF="${VF},ass=filename='${BASS_ESC}':original_size=${PRX}x${PRY}"
fi
VF="${VF},ass=filename='${ASS_ESC}':original_size=${PRX}x${PRY}"
if [[ -n "${EXTRA_ASS_FILTER:-}" ]]; then
  VF="${VF}${EXTRA_ASS_FILTER}"
fi

export INPUT_WAV="$WAV" INPUT_SRT="${SRT_IN:-}" INPUT_ASS="$ASS_REPAIRED"
run_hooks pre_burn || true

# --- Render ------------------------------------------------------------------
# Use -use_editlist 0 to avoid player timeline shenanigans; standardize audio at 48kHz.
# If AUDIO_PRE_OPTS is set (delay case), it must be placed immediately before the audio input.
if (( ${#AUDIO_PRE_OPTS[@]} )); then
  ffmpeg -hide_banner -y -loop 1 -framerate 30 -i "$BG" "${AUDIO_PRE_OPTS[@]}" -i "$WAV" \
    -vf "$VF" -af "$AF" \
    -movflags +faststart \
    -use_editlist 0 \
    -force_key_frames 0 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -shortest \
    ${FFMPEG_EXTRA_OUT_FLAGS:-} \
    "$OUT"
else
  ffmpeg -hide_banner -y -loop 1 -framerate 30 -i "$BG" -i "$WAV" \
    -vf "$VF" -af "$AF" \
    -movflags +faststart \
    -use_editlist 0 \
    -force_key_frames 0 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 48000 -shortest \
    ${FFMPEG_EXTRA_OUT_FLAGS:-} \
    "$OUT"
fi

run_hooks post_render || true
echo; echo "[OK] Rendered:"; cygpath -w "$OUT"
