#!/usr/bin/env bash
# Usage: srt_autosync.sh INPUT.srt INPUT.wav OUTPUT.srt [lead_ms]
# - lead_ms: captions appear this many ms AFTER speech onset (default 150)
set -euo pipefail

SRT_IN="${1:?need SRT input}"
WAV_IN="${2:?need WAV input}"
SRT_OUT="${3:?need SRT output}"
LEAD_MS="${4:-150}"
EXTRA_SHIFT_MS="${5:-0}"

# --- functions ---
to_ms(){ awk -v t="$1" 'BEGIN{printf "%.0f", t*1000}' ; }
from_ms(){ # ms->SRT ts
  awk -v T="$1" 'BEGIN{
    if (T<0) T=0
    ms = T % 1000; T = int(T/1000)
    s  = T % 60;   T = int(T/60)
    m  = T % 60;   h = int(T/60)
    printf "%02d:%02d:%02d,%03d", h,m,s,ms
  }'
}

# --- durations ---
D_WAV="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$WAV_IN")"
D_SRT="$(awk '/-->/{t=$3} END{split(t,a,":|,"); print (((a[1]*60+a[2])*60+a[3])*1000+a[4])/1000 }' "$SRT_IN")"

# Avoid div by zero
if awk -v x="$D_SRT" 'BEGIN{exit !(x>0)}'; then :; else
  echo "SRT appears empty or has no timing lines." >&2
  exit 1
fi

# --- first cue start (seconds) ---
SRT_FIRST="$(awk '/-->/{split($1,a,":|,"); print (((a[1]*60+a[2])*60+a[3])*1000+a[4])/1000; exit}' "$SRT_IN")"

# --- detect leading silence in WAV (seconds) ---
# We look for a silence that starts at 0 and take its first silence_end as the audio start
AUDIO_START="$(ffmpeg -hide_banner -nostats -i "$WAV_IN" -af silencedetect=noise=-35dB:d=0.1 -f null - 2>&1 \
  | awk '
     /silence_start:/{
       if ($0 ~ /silence_start: 0(\.0+)?([[:space:]]|$)/) start0=1
     }
     /silence_end:/ && start0 && !printed{
       if (match($0,/silence_end: ([0-9.]+)/,m)){ print m[1]; printed=1; exit }
     }
     END{ if (!printed) print 0 }'
)"

# --- compute scale (stretch SRT to WAV) ---
SCALE="$(awk -v a="$D_WAV" -v b="$D_SRT" 'BEGIN{printf "%.8f", (b>0?a/b:1)}')"

# --- compute shift (ms) so first cue aligns to audio_start + lead ---
SRT_FIRST_SCALED="$(awk -v s="$SRT_FIRST" -v f="$SCALE" 'BEGIN{printf "%.3f", s*f}')"
SHIFT_MS="$(awk -v a="$AUDIO_START" -v l="$LEAD_MS" -v ss="$SRT_FIRST_SCALED" \
  'BEGIN{ printf "%.0f", (a + l/1000.0 - ss)*1000.0 }')"

# --- build new SRT ---
awk -v F="$SCALE" -v SHIFT="$SHIFT_MS" '
function to_ms(h,m,s,ms){ return (((h*60)+m)*60 + s)*1000 + ms }
function from_ms(T,ms,s,m,h){
  if(T<0)T=0; ms=T%1000; T=int(T/1000); s=T%60; T=int(T/60); m=T%60; h=int(T/60);
  return sprintf("%02d:%02d:%02d,%03d",h,m,s,ms)
}
# renumber cues sequentially as we go
/^[[:space:]]*$/ { print; next }                 # blank lines passthrough
/^[0-9]+$/ { next }                              # drop old cue numbers
/-->/ {
  split($1,a,":|,"); split($3,b,":|,");
  s=int(to_ms(a[1],a[2],a[3],a[4])*F)+SHIFT
  e=int(to_ms(b[1],b[2],b[3],b[4])*F)+SHIFT
  print ++n
  print from_ms(s) " --> " from_ms(e)
  next
}
{ print }                                        # text lines
' "$SRT_IN" > "$SRT_OUT"

echo "[autosync] WAV:  $D_WAV s"
echo "[autosync] SRT:  $D_SRT s"
echo "[autosync] FstAudioStart: $AUDIO_START s"
echo "[autosync] Scale: $SCALE  Shift(ms): $SHIFT_MS"
echo "[autosync] Wrote: $SRT_OUT"
