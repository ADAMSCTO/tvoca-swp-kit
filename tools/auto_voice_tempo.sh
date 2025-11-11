#!/usr/bin/env bash
# JirehFaith SWP Kit — Auto Voice Tempo Sync
# Usage: tools/auto_voice_tempo.sh <in.wav> <in.srt> <out.wav>
# Goal: Adjust WAV tempo to match SRT total duration (voice↔caption sync).
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }

if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ] || [ $# -lt 3 ]; then
  echo "Usage: $0 <in.wav> <in.srt> <out.wav>"
  exit 2
fi

IN_WAV="$1"
IN_SRT="$2"
OUT_WAV="$3"

command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found in PATH"
command -v ffmpeg  >/dev/null 2>&1 || die "ffmpeg not found in PATH"

[ -f "$IN_WAV" ] || die "Input WAV not found: $IN_WAV"
[ -f "$IN_SRT" ] || die "Input SRT not found: $IN_SRT"

# Ensure output directory exists (e.g., C:\jf\jirehfaith_swp_kit\out)
OUT_DIR="$(dirname "$OUT_WAV")"
mkdir -p "$OUT_DIR"

# --- Duration (seconds, float) ---
WAV_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN_WAV" | sed 's/,/./g')"
[ -n "${WAV_DUR:-}" ] || die "Could not read WAV duration"

# Robust SRT duration parser (handles CRLF/BOM/extra spaces)
SRT_DUR="$(awk '
function ts(s,   a,b){
  gsub(/\xef\xbb\xbf/,"",s)         # strip UTF-8 BOM if present
  gsub(/\r/,"",s)                    # strip CR
  split(s,a,/:/)                     # a[1]=HH a[2]=MM a[3]=SS,mmm
  split(a[3],b,/,/)                  # b[1]=SS b[2]=mmm
  return a[1]*3600 + a[2]*60 + b[1] + b[2]/1000.0
}
BEGIN{ first=""; last="" }
/-->/{
  line=$0
  gsub(/\r/,"",line)
  if (match(line,/([0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}).*-->. *([0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3})/,m)) {
    if (first=="") first=m[1]
    last=m[2]
  }
}
END{
  if (first=="" || last==""){ exit 1 }
  sd=ts(first); ed=ts(last)
  d=ed-sd; if (d<=0) d=ed             # fallback if first cue starts at 00:00
  printf("%.6f\n", d)
}
' "$IN_SRT")" || die "Could not compute SRT duration"

# --- Compute factor: SRT/WAV, but atempo needs TEMPO = 1/factor ---
FACTOR="$(awk -v a="$SRT_DUR" -v b="$WAV_DUR" 'BEGIN{ if(b<=0){print "0"} else printf("%.6f", a/b) }')"
awk -v f="$FACTOR" 'BEGIN{ if(f<=0){ exit 1 } }' || die "Invalid factor computed (<=0). WAV_DUR='"$WAV_DUR"' SRT_DUR='"$SRT_DUR"'"

# Target tempo multiplier: TEMPO = WAV should be stretched/compressed by this
TEMPO="$(awk -v f="$FACTOR" 'BEGIN{ printf("%.8f", 1.0/f) }')"

# --- Build atempo chain within [0.5, 2.0] per element to approximate TEMPO ---
build_chain() {
  t="$1"  # desired overall tempo multiplier
  chain=""
  # If t > 2: repeatedly apply 2.0 until t <= 2
  while awk -v x="$t" 'BEGIN{ exit (x>2.0)?0:1 }'; do
    chain="${chain}${chain:+,}atempo=2.0"
    t="$(awk -v x="$t" 'BEGIN{ printf("%.8f", x/2.0) }')"
  done
  # If t < 0.5: repeatedly apply 0.5 until t >= 0.5
  while awk -v x="$t" 'BEGIN{ exit (x<0.5)?0:1 }'; do
    chain="${chain}${chain:+,}atempo=0.5"
    t="$(awk -v x="$t" 'BEGIN{ printf("%.8f", x/0.5) }')"
  done
  # Append the remainder if meaningfully different from 1.0
  if awk -v x="$t" 'BEGIN{ dx=(x-1.0); if(dx<0) dx=-dx; exit (dx>=0.001)?0:1 }'; then
    chain="${chain}${chain:+,}atempo=$(awk -v x="$t" "BEGIN{ printf(\"%.6f\", x) }")"
  fi
  [ -n "$chain" ] || chain="atempo=1.0"
  printf "%s" "$chain"
}

CHAIN="$(build_chain "$TEMPO")"

echo "=== Auto Voice Tempo Sync ==="
echo "WAV:           $IN_WAV"
echo "SRT:           $IN_SRT"
echo "WAV_DUR_SEC:   $WAV_DUR"
echo "SRT_DUR_SEC:   $SRT_DUR"
echo "FACTOR(SRT/WAV): $FACTOR"
echo "TEMPO(1/FACTOR): $TEMPO"
echo "ATEMPO CHAIN:  $CHAIN"
echo "Output:        $OUT_WAV"
echo "--------------------------------"

# Process audio
ffmpeg -hide_banner -y -i "$IN_WAV" -filter:a "$CHAIN" -ar 48000 -ac 2 "$OUT_WAV"

# Post-check
NEW_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT_WAV" | sed 's/,/./g' || true)"
echo "NEW_WAV_DUR_SEC: ${NEW_DUR:-unknown}"
echo "Done."
