#!/usr/bin/env bash
# Make a "sentence-based" SRT:
# - Input: WAV + TXT (one sentence/line)
# - Output: SRT where each sentence duration is proportional to its word count
# - Goal: reading captions that follow the VOICE pacing, NOT forcing total length to match exactly
#
# Strategy:
#   1. Measure WAV duration in ms.
#   2. Count total words across all sentences.
#   3. Estimate ms-per-word from WAV duration, then add a small "reading cushion".
#   4. For each sentence: duration ≈ words * ms_per_word, with a MIN_MS floor.
#   5. Insert fixed GAP_MS between sentences.
#
# This means the total SRT timeline may be slightly LONGER than the WAV,
# which is acceptable (and preferred) for reading captions so that
# subtitles do not disappear before the voice finishes.

set -euo pipefail

WAV="${1:?need WAV}"   # e.g. hope_en_joe.wav
TXT="${2:?need TXT}"   # e.g. hope_en_joe.txt (one sentence per line)
OUT="${3:?need OUT.srt}"

# Tunable from UI / env
GAP_MS="${GAP_MS:-180}"    # pause between sentences
MIN_MS="${MIN_MS:-900}"    # minimum on-screen time per sentence

# 1) Get WAV duration (ms)
DUR_MS="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$WAV" | awk '{printf("%.0f",$1*1000)}')"

# 2) Read non-empty sentences
mapfile -t LINES < <(awk 'NF{print}' "$TXT")
N="${#LINES[@]}"

if (( N == 0 )); then
  echo "No lines in $TXT" >&2
  exit 2
fi

# 3) Compute word counts and total words
declare -a WORDS
TOTALW=0

for (( i=0; i<N; i++ )); do
  # Count "words" in the sentence; ensure at least 1
  wcnt=$(awk '{print NF}' <<<"${LINES[$i]}")
  (( wcnt == 0 )) && wcnt=1
  WORDS[$i]="$wcnt"
  TOTALW=$(( TOTALW + wcnt ))
done

# Safety: if somehow TOTALW is zero, treat each sentence as 1 word
if (( TOTALW <= 0 )); then
  TOTALW=$N
  for (( i=0; i<N; i++ )); do
    WORDS[$i]=1
  done
fi

# 4) Derive ms-per-word from the WAV duration, then add a reading cushion
# Base estimate: DUR_MS / TOTALW (how long, on average, Joe takes per word)
BASE_MSPW=$(( DUR_MS / (TOTALW > 0 ? TOTALW : 1) ))

# Reading cushion: +12% so captions tend to stay a bit LONGER than the voice
MSPW=$(( BASE_MSPW * 112 / 100 ))
(( MSPW < 80 )) && MSPW=80   # sanity floor for very short clips

# Helper: ms -> SRT timestamp
ms2ts(){ # $1=ms -> SRT timestamp
  ms=$1
  (( ms < 0 )) && ms=0
  h=$(( ms / 3600000 ))
  m=$(( (ms / 60000) % 60 ))
  s=$(( (ms / 1000) % 60 ))
  ms=$(( ms % 1000 ))
  printf "%02d:%02d:%02d,%03d" "$h" "$m" "$s" "$ms"
}

# 5) Write SRT with sentence durations based on word counts
START=0
: > "$OUT"

TOTAL_SRT_END=0

for (( i=0; i<N; i++ )); do
  wcnt=${WORDS[$i]}

  # Duration proportional to word count
  dur=$(( wcnt * MSPW ))

  # Enforce minimum per-sentence on-screen time
  (( dur < MIN_MS )) && dur=$MIN_MS

  END=$(( START + dur ))
  idx=$(( i + 1 ))

  {
    printf "%d\n" "$idx"
    printf "%s --> %s\n" "$(ms2ts "$START")" "$(ms2ts "$END")"
    printf "%s\n\n" "${LINES[$i]}"
  } >> "$OUT"

  TOTAL_SRT_END=$END
  START=$(( END + GAP_MS ))
done

# Informational log: how long the final SRT runs vs WAV
echo "[ok] Wrote $(cygpath -w "$OUT") with $N cues  (ms_per_word=${MSPW}ms, GAP_MS=${GAP_MS}ms, WAV_MS=${DUR_MS}, SRT_END_MS=${TOTAL_SRT_END})"
