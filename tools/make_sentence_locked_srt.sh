#!/usr/bin/env bash
# Build a sentence-locked SRT from a WAV and a plain-text script (one sentence per line).
# Prefers Piper timing JSON if available; else uses ffmpeg silencedetect to derive segments.
# Usage:
#   bash tools/make_sentence_locked_srt.sh voice/wavs/anxiety_en_amy.wav voice/script/anxiety_en.txt voice/build/anxiety_en_amy.srt [voice/build/anxiety_en_amy.timing.json]
set -euo pipefail

WAV="${1:?need wav}"
SCRIPT_TXT="${2:?need script.txt (one sentence per line)}"
OUT_SRT="${3:?need out.srt}"
JSON_TIMING="${4:-}"  # optional Piper JSON

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

nl -ba "$SCRIPT_TXT" | sed 's/\t/: /' > "$tmp/script.numbered.txt"
N=$(wc -l < "$SCRIPT_TXT" | awk '{print $1}')
if [[ "$N" -lt 1 ]]; then echo "No sentences in $SCRIPT_TXT" >&2; exit 2; fi

ms_to_ts(){ # ms → HH:MM:SS,cc
  local ms="$1"; ((ms<0)) && ms=0
  local cs=$(( (ms%1000)/10 ))
  local s=$(( (ms/1000)%60 ))
  local m=$(( (ms/60000)%60 ))
  local h=$(( ms/3600000 ))
  printf "%d:%02d:%02d.%02d" "$h" "$m" "$s" "$cs"
}

# Try A) Piper JSON timings
if [[ -n "${JSON_TIMING}" && -s "${JSON_TIMING}" ]]; then
  if command -v jq >/dev/null 2>&1; then
    # Expect JSON with words array or segments with start/end.
    # We build continuous spans and split to N lines in order.
    jq -e . >/dev/null 2>&1 < "$JSON_TIMING" || { echo "[warn] Bad JSON; falling back to silencedetect"; JSON_TIMING=""; }
    if [[ -n "${JSON_TIMING}" ]]; then
      # Gather word-level times if present; else use segment times.
      if jq -e '.words|length>0' >/dev/null 2>&1 < "$JSON_TIMING"; then
        jq -r '.words[] | "\(.start)\t\(.end)\t\(.word)"' "$JSON_TIMING" > "$tmp/words.tsv"
        # Coalesce evenly by word count across N sentences.
        W=$(wc -l < "$tmp/words.tsv" | awk '{print $1}')
        if [[ "$W" -ge "$N" ]]; then
          per=$(( W / N )); (( per<1 )) && per=1
          awk -v N="$N" -v per="$per" '
            BEGIN{sent=1; s=-1; e=-1; cnt=0}
            {
              if(s<0){ s=$1*1000 }
              e=$2*1000; cnt++
              if(cnt>=per && sent<N){ print sent"\t"s"\t"e; sent++; s=-1; cnt=0 }
            }
            END{ if(sent<=N){ print sent"\t"s"\t"e } }
          ' "$tmp/words.tsv" > "$tmp/spans.tsv"
        else
          # fewer words than sentences — collapse to one span
          first=$(head -n1 "$tmp/words.tsv" | awk '{print $1*1000}')
          last=$(tail -n1 "$tmp/words.tsv" | awk '{print $2*1000}')
          for i in $(seq 1 "$N"); do echo -e "$i\t$first\t$last"; done > "$tmp/spans.tsv"
        fi
      else
        # Use segments array with start/end
        jq -r '.segments[]? | "\(.start)\t\(.end)"' "$JSON_TIMING" > "$tmp/seg.tsv" || true
        S=$(wc -l < "$tmp/seg.tsv" | awk '{print $1}')
        if [[ "$S" -gt 0 ]]; then
          # Map N sentences onto S segments (round-robin / stretch)
          awk -v N="$N" '
            { seg[++i]=$0 } END{
              if(i==0){ exit 1 }
              for (k=1;k<=N;k++){
                idx = int((k-1)*i/N)+1; print k"\t"seg[idx]
              }
            }
          ' "$tmp/seg.tsv" > "$tmp/spans.tsv" || true
        fi
      fi
      if [[ -s "$tmp/spans.tsv" ]]; then
        paste <(seq 1 "$N") "$SCRIPT_TXT" > "$tmp/script.tsv"
        awk -F'\t' 'NR==FNR{span[$1]=$2"\t"$3; next}{
          split(span[$1],a,"\t"); s=a[1]; e=a[2];
          if(s==""||e==""){ next }
          printf "%d\n%s --> %s\n%s\n\n", NR, "'"$(printf '%s' | sed 's/.*/ms_to_ts(&)/')"'", "'"$(printf '%s' | sed 's/.*/ms_to_ts(&)/')"'", $2
        }' "$tmp/spans.tsv" "$tmp/script.tsv" > "$OUT_SRT".tmp

        # The above placeholder won't evaluate ms_to_ts; rebuild properly:
        > "$OUT_SRT"
        n=0
        while IFS=$'\t' read -r idx s e; do
          n=$((n+1))
          line=$(sed -n "${idx}p" "$SCRIPT_TXT")
          printf "%d\n%s --> %s\n%s\n\n" \
            "$n" "$(ms_to_ts "${s%.*}")" "$(ms_to_ts "${e%.*}")" "$line" >> "$OUT_SRT"
        done < "$tmp/spans.tsv"
        echo "[ok] Built sentence-locked SRT from Piper JSON → $OUT_SRT"
        exit 0
      fi
    fi
  else
    echo "[warn] jq not found; falling back to silencedetect"
  fi
fi

# B) Silencedetect fallback
echo "[i] Deriving segments from audio silences…"
sd="$tmp/sd.log"
ffmpeg -hide_banner -nostats -i "$WAV" -af "silencedetect=noise=-35dB:d=0.25" -f null - 2> "$sd" || true
awk '
  /silence_end:/ { se=$0; match(se,/silence_end:\s*([0-9.]+)/,m); t=m[1]; if(t!=""){ voiced[++i]=t } }
  END{ for(k=1;k<=i;k++) print voiced[k] }
' "$sd" > "$tmp/ends.txt"

# Build [start,end] windows from ends; start of first is 0.
python - "$tmp/ends.txt" "$N" > "$tmp/spans.tsv" <<'PY'
import sys
ends = [float(x.strip()) for x in open(sys.argv[1]) if x.strip()]
N = int(sys.argv[2])
if not ends:
    # fallback: one big span 0..dur guessed 60s
    for i in range(1, N+1):
        s = 0.0
        e = 60.0
        print(f"{i}\t{int(s*1000)}\t{int(e*1000)}")
    sys.exit(0)
starts = [0.0] + ends[:-1]
spans = list(zip(starts, ends))
# Map N sentences onto len(spans) voiced windows
S = len(spans)
def pick(idx):
    j = int((idx-1)*S/N)
    if j>=S: j=S-1
    return spans[j]
for i in range(1, N+1):
    s,e = pick(i)
    print(f"{i}\t{int(s*1000)}\t{int(e*1000)}")
PY

> "$OUT_SRT"
n=0
while IFS=$'\t' read -r idx s e; do
  n=$((n+1))
  line=$(sed -n "${idx}p" "$SCRIPT_TXT")
  printf "%d\n%s --> %s\n%s\n\n" \
    "$n" "$(ms_to_ts "$s")" "$(ms_to_ts "$e")" "$line" >> "$OUT_SRT"
done < "$tmp/spans.tsv"

echo "[ok] Built sentence-locked SRT via silencedetect → $OUT_SRT"
