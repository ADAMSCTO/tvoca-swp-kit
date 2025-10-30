#!/usr/bin/env bash
# Unified renderer for SWP videos (H & V) with enforced CenterBox style.
# Accepts SRT or ASS. For SRT: autosync -> ASS. For both: normalize -> repair -> burn with ass filter.
# No subtitles=/force_style filters — parity with the vertical pipeline.

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

# --- Defaults (env) ----------------------------------------------------------
FONT_NAME="${FONT_NAME:-Arial}"
FONT_SIZE="${FONT_SIZE:-96}"
MARGIN_L="${MARGIN_L:-140}"
MARGIN_R="${MARGIN_R:-140}"
MARGIN_V="${MARGIN_V:-0}"
BOX_OPA="${BOX_OPA:-96}"      # AA for BackColour (&HAABBGGRR)
LEAD_MS="${LEAD_MS:-200}"
AUTOSYNC="${AUTOSYNC:-1}"

# --- PlayRes from --size (horizontal default) --------------------------------
PRX=1920; PRY=1080
if [[ "$SIZE" == "1080x1920" ]]; then PRX=1080; PRY=1920; fi

# --- Helpers -----------------------------------------------------------------
# Normalize line endings to LF (handles CRLF coming from Windows tools)
to_lf_file() { # in -> out
  local in="$1" out="$2"
  # use awk to avoid in-place sed inconsistencies on MSYS
  awk '{sub(/\r$/,""); print}' "$in" > "$out"
}

normalize_ass() {
  local ass="$1"
  # Ensure PlayRes
  if ! grep -q '^PlayResX:' "$ass"; then
    # Insert PlayRes lines right after [Script Info]
    awk -v x="$PRX" -v y="$PRY" '
      BEGIN{added=0}
      {
        print
        if(!added && $0=="[Script Info]"){ print "PlayResX: " x; print "PlayResY: " y; added=1 }
      }' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
  fi
  # Override any existing PlayRes to desired values
  awk -v x="$PRX" -v y="$PRY" '
    BEGIN{FS=OFS=""}
    {gsub(/^PlayResX: .*/,"PlayResX: " x)}
    {gsub(/^PlayResY: .*/,"PlayResY: " y)}
    {print}
  ' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"

  # Insert/replace CenterBox style (AABBGGRR; black box with alpha = BOX_OPA)
  local STYLE_LINE="Style: CenterBox,${FONT_NAME},${FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,&H${BOX_OPA}000000,0,0,0,0,100,100,0,0,3,0,0,5,${MARGIN_L},${MARGIN_R},${MARGIN_V},1"
  if grep -q '^Style: CenterBox,' "$ass"; then
    sed -i -E "s|^Style: CenterBox,.*$|${STYLE_LINE}|" "$ass"
  else
    awk -v ins="$STYLE_LINE" '
      /^\[V4\+ Styles\]/{print; getline; print; print ins; next}
      {print}
    ' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
  fi

  # Force Dialogue style column to CenterBox (field 4)
  awk -F',' 'BEGIN{OFS=","} /^Dialogue:/{ $4="CenterBox" } {print}' "$ass" > "$ass.tmp" && mv -f "$ass.tmp" "$ass"
}

# If the external repair helper exists, use it; otherwise apply a safe inline repair:
#  - drop dialogue lines with malformed timestamps
#  - if End < Start, bump End to Start+100ms
repair_bad_ts() {
  local ass_in="$1"
  local ass_out="$2"
  if [[ -x "$TOOLS/ass_repair_bad_timestamps.sh" ]]; then
    bash "$TOOLS/ass_repair_bad_timestamps.sh" "$ass_in" "$ass_out"
    return
  fi

  awk -F',' '
    function hms_to_ms(t,  a,ms) {
      if (match(t, /^([0-9]+):([0-9]{2}):([0-9]{2})\.([0-9]{2})$/, a)) {
        return (a[1]*3600000) + (a[2]*60000) + (a[3]*1000) + (a[4]*10);
      }
      return -1;
    }
    function ms_to_hms(MS,  cs, s, m, h) {
      cs = int((MS % 1000)/10)
      s  = int((MS/1000) % 60)
      m  = int((MS/60000) % 60)
      h  = int(MS/3600000)
      return sprintf("%d:%02d:%02d.%02d", h,m,s,cs)
    }
    BEGIN{ OFS="," }
    /^\[Script Info\]/  { print; next }
    /^\[V4\+ Styles\]/  { print; next }
    /^\[Events\]/       { print; next }
    /^Format:/          { print; next }
    /^Comment:/         { print; next }
    /^Dialogue:/ {
      start_ms = hms_to_ms($2); end_ms = hms_to_ms($3);
      if (start_ms < 0 || end_ms < 0) next;               # drop malformed
      if (end_ms <= start_ms) end_ms = start_ms + 100;    # +100ms minimal
      $2 = ms_to_hms(start_ms)
      $3 = ms_to_hms(end_ms)
      print; next
    }
    { print }
  ' "$ass_in" > "$ass_out"
}

count_dialogue() {
  grep -c '^Dialogue:' "$1" || true
}

derive_srt_sibling() {
  # Find a plain .srt sibling for any input ASS (handles .autosync.ass and .norm.* variants)
  local asspath="$1"
  local dir="$(dirname "$asspath")"
  local base="$(basename "$asspath")"
  base="${base%.ass}"
  base="${base%.autosync}"
  base="${base%.norm}"
  base="${base%.repaired}"
  # Try: same dir, then voice/build with and without .autosync
  local s1="$dir/${base}.srt"
  local s2="$BUILD/${base}.srt"
  if [[ -f "$s1" ]]; then echo "$s1"; return; fi
  if [[ -f "$s2" ]]; then echo "$s2"; return; fi
  echo ""  # not found
}

log_i(){ echo "[i] $*"; }
log_w(){ echo "[warn] $*" >&2; }
log_e(){ echo "[err] $*" >&2; }

# --- Get ASS (convert from SRT if needed) ------------------------------------
ext="$(echo "${CAP_IN##*.}" | tr '[:upper:]' '[:lower:]')"
ASS_RAW=""
if [[ "$ext" == "ass" ]]; then
  ASS_RAW="$CAP_IN"
  log_i "Input captions detected as ASS: $(cygpath -w "$ASS_RAW")"
else
  SRT_IN="$CAP_IN"
  log_i "Input captions detected as SRT: $(cygpath -w "$SRT_IN")"
  tmp_srt="$BUILD/.$(basename "$SRT_IN").lf.srt"
  to_lf_file "$SRT_IN" "$tmp_srt"

  SRT_SYNC="$BUILD/$(basename "${SRT_IN%.*}").autosync.srt"
  if [[ "$AUTOSYNC" == "0" ]]; then
    cp -f "$tmp_srt" "$SRT_SYNC"
    log_i "Autosync disabled — copied SRT to $(cygpath -w "$SRT_SYNC")"
  else
    log_i "Autosync SRT → $(cygpath -w "$SRT_SYNC") (lead=${LEAD_MS}ms)"
    bash "$TOOLS/srt_autosync.sh" "$tmp_srt" "$WAV" "$SRT_SYNC" "$LEAD_MS"
  fi

  ASS_RAW="$BUILD/$(basename "${SRT_IN%.*}").autosync.ass"
  ffmpeg -hide_banner -y -i "$SRT_SYNC" -c:s ass "$ASS_RAW" >/dev/null 2>&1
  log_i "Converted SRT→ASS: $(cygpath -w "$ASS_RAW")"
fi

# --- Normalize + repair (always) --------------------------------------------
ASS_NORM="$BUILD/$(basename "${ASS_RAW%.*}").norm.ass"
to_lf_file "$ASS_RAW" "$ASS_NORM"
normalize_ass "$ASS_NORM" || true

ASS_REPAIRED="$BUILD/$(basename "${ASS_RAW%.*}").repaired.ass"
repair_bad_ts "$ASS_NORM" "$ASS_REPAIRED"
DCOUNT="$(count_dialogue "$ASS_REPAIRED")"

# --- Auto-fallback: if 0 events (e.g., “Bad timestamp”), rebuild from SRT ----
if [[ "${DCOUNT:-0}" -le 0 ]]; then
  log_w "0 Dialogue events after repair — attempting ASS→SRT recovery…"
  SIB_SRT="$(derive_srt_sibling "$ASS_RAW")"
  if [[ -n "$SIB_SRT" && -f "$SIB_SRT" ]]; then
    log_i "Found SRT sibling: $(cygpath -w "$SIB_SRT")"
    tmp_srt2="$BUILD/.$(basename "$SIB_SRT").lf.srt"
    to_lf_file "$SIB_SRT" "$tmp_srt2"
    SRT_SYNC2="$BUILD/$(basename "${SIB_SRT%.*}").autosync.srt"
    if [[ "$AUTOSYNC" == "0" ]]; then
      cp -f "$tmp_srt2" "$SRT_SYNC2"
      log_i "Autosync disabled — copied sibling SRT to $(cygpath -w "$SRT_SYNC2")"
    else
      log_i "Autosync sibling SRT → $(cygpath -w "$SRT_SYNC2") (lead=${LEAD_MS}ms)"
      bash "$TOOLS/srt_autosync.sh" "$tmp_srt2" "$WAV" "$SRT_SYNC2" "$LEAD_MS"
    fi
    ASS_RAW2="$BUILD/$(basename "${SIB_SRT%.*}").autosync.ass"
    ffmpeg -hide_banner -y -i "$SRT_SYNC2" -c:s ass "$ASS_RAW2" >/dev/null 2>&1
    log_i "Rebuilt ASS from sibling SRT: $(cygpath -w "$ASS_RAW2")"

    ASS_NORM="$BUILD/$(basename "${ASS_RAW2%.*}").norm.ass"
    to_lf_file "$ASS_RAW2" "$ASS_NORM"
    normalize_ass "$ASS_NORM" || true
    ASS_REPAIRED="$BUILD/$(basename "${ASS_RAW2%.*}").repaired.ass"
    repair_bad_ts "$ASS_NORM" "$ASS_REPAIRED"
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

# --- Windows-friendly path for ass= filter -----------------------------------
ASS_MIXED="$(cygpath -m "$ASS_REPAIRED")"   # C:/path/...
ASS_ESC="${ASS_MIXED/:/\\:}"                # C\:/path/...

echo "[i] SIZE=${SIZE:-auto}  PlayRes=${PRX}x${PRY}  FONT=${FONT_NAME}/${FONT_SIZE}  MARGINS L/R/V=${MARGIN_L}/${MARGIN_R}/${MARGIN_V}  BOX_OPA=${BOX_OPA}"
echo "[i] BG=$(cygpath -w "$BG")"
echo "[i] WAV=$(cygpath -w "$WAV")"
echo "[i] ASS=$(cygpath -w "$ASS_REPAIRED")  (events=${DCOUNT})"

# --- Burn with ass filter ----------------------------------------------------
ffmpeg -hide_banner -y -loop 1 -framerate 30 -i "$BG" -i "$WAV" \
  -vf "ass=filename='${ASS_ESC}':original_size=${PRX}x${PRY}" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT"

echo
echo "[OK] Rendered:"
cygpath -w "$OUT"
