#!/usr/bin/env bash
set -euo pipefail
WAV="${1:?need WAV}"; TXT="${2:?need TXT}"; OUT="${3:?need OUT.srt}"
GAP_MS="${GAP_MS:-150}"     # pause between sentences
MIN_MS="${MIN_MS:-900}"     # minimum on-screen time per sentence
# get wav duration (ms)
DUR_MS="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$WAV" | awk '{printf("%.0f",$1*1000)}')"

# read sentences + count words per line
mapfile -t LINES < <(awk 'NF{print}' "$TXT")
N="${#LINES[@]}"
if (( N == 0 )); then echo "No lines in $TXT" >&2; exit 2; fi

# compute word counts
declare -a W
TOTALW=0
for ((i=0;i<N;i++)); do
  wcnt=$(awk '{print NF}' <<<"${LINES[$i]}")
  (( wcnt == 0 )) && wcnt=1
  W[$i]="$wcnt"
  TOTALW=$(( TOTALW + wcnt ))
done

# budget for speech vs gaps
TOTAL_GAPS=$(( (N>1 ? (N-1) : 0) * GAP_MS ))
# ensure we have enough time for minimums
if (( DUR_MS <= TOTAL_GAPS + N*MIN_MS )); then
  MIN_MS=$(( (DUR_MS - TOTAL_GAPS) / (N>0?N:1) ))
  (( MIN_MS < 300 )) && MIN_MS=300
fi
SPEECH_MS=$(( DUR_MS - TOTAL_GAPS ))

# assign durations proportional to word counts with a MIN_MS floor
declare -a DUR
SUM_ASSIGNED=0
for ((i=0;i<N;i++)); do
  di=$(( SPEECH_MS * W[i] / (TOTALW>0?TOTALW:1) ))
  (( di < MIN_MS )) && di=$MIN_MS
  DUR[$i]="$di"
  SUM_ASSIGNED=$(( SUM_ASSIGNED + di ))
done

# normalize down if total exceeds budget
if (( SUM_ASSIGNED > SPEECH_MS )); then
  SF=$(( SPEECH_MS * 1000 / (SUM_ASSIGNED>0?SUM_ASSIGNED:1) ))
  SUM_ASSIGNED=0
  for ((i=0;i<N;i++)); do
    di=$(( DUR[i] * SF / 1000 ))
    (( di < MIN_MS )) && di=$MIN_MS
    DUR[$i]="$di"
    SUM_ASSIGNED=$(( SUM_ASSIGNED + di ))
  done
fi

ms2ts(){ # $1=ms -> SRT timestamp
  ms=$1; (( ms<0 )) && ms=0
  h=$(( ms/3600000 )); m=$(( (ms/60000)%60 )); s=$(( (ms/1000)%60 )); ms=$(( ms%1000 ))
  printf "%02d:%02d:%02d,%03d" "$h" "$m" "$s" "$ms"
}

START=0
: > "$OUT"
for ((i=0;i<N;i++)); do
  END=$(( START + DUR[i] ))
  idx=$(( i+1 ))
  {
    printf "%d\n" "$idx"
    printf "%s --> %s\n" "$(ms2ts "$START")" "$(ms2ts "$END")"
    printf "%s\n\n" "${LINES[$i]}"
  } >> "$OUT"
  START=$(( END + GAP_MS ))
done

echo "[ok] Wrote $(cygpath -w "$OUT") with $N cues"
