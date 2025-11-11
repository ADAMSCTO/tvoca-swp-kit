#!/usr/bin/env bash
# srt_pace.sh IN.srt OUT.srt
# Enforce human-friendly pacing:
# - MIN_DUR_MS: minimum cue duration (default 1600ms)
# - MAX_CPS:    maximum characters per second (default 12)
# - MIN_GAP_MS: minimum gap between cues (default 180ms)
# - PAD_SENT_MS: extra pad after sentence-ending punctuation (default 120ms)

set -euo pipefail
IN="${1:?need IN.srt}"
OUT="${2:?need OUT.srt}"

MIN_DUR_MS="${MIN_DUR_MS:-1600}"
MAX_CPS="${MAX_CPS:-12}"
MIN_GAP_MS="${MIN_GAP_MS:-180}"
PAD_SENT_MS="${PAD_SENT_MS:-120}"

h2ms() {
  # 00:00:12,345 -> ms
  awk -F'[:,]' '{h=$1+0;m=$2+0;s=$3+0;ms=$4+0; print (h*3600000+m*60000+s*1000+ms)}'
}
ms2h() {
  # ms -> 00:00:12,345
  awk -v MS="$1" 'BEGIN{
    if(MS<0) MS=0;
    h=int(MS/3600000);
    m=int((MS%3600000)/60000);
    s=int((MS%60000)/1000);
    ms=int(MS%1000);
    printf("%02d:%02d:%02d,%03d",h,m,s,ms);
  }'
}

awk -v MIN_DUR="$MIN_DUR_MS" -v MAX_CPS="$MAX_CPS" -v MIN_GAP="$MIN_GAP_MS" -v PAD_SENT="$PAD_SENT_MS" '
function trim(s){ sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s); return s }
function h2ms(t, a){ split(t,a,/:|,/) ; return (a[1]*3600000 + a[2]*60000 + a[3]*1000 + a[4]) }
function ms2h(MS){ if(MS<0) MS=0; h=int(MS/3600000); m=int((MS%3600000)/60000); s=int((MS%60000)/1000); ms=int(MS%1000); return sprintf("%02d:%02d:%02d,%03d",h,m,s,ms) }
function is_end_sentence(txt){ return (txt ~ /[\.!\?][\"\u201D\u00BB\)]?$/) }  # .,!,? plus common trailing quotes/parens
BEGIN{ RS=""; ORS="\n\n" }
/^[0-9]+[ \t\r\n]+\d\d:\d\d:\d\d,\d{3} --> \d\d:\d\d:\d\d,\d{3}/{
  id=$1
  split($0, L, /\r?\n/)
  # header line is first line with arrow
  hdr=""
  idx_hdr=0
  for(i=1;i<=length(L);i++){
    if(L[i] ~ /-->/){ hdr=L[i]; idx_hdr=i; break }
  }
  if(hdr==""){ print $0; next }

  # times
  n=split(hdr, H, /[ \t-]+>/)
  split(hdr, T, /[ ]*-->[ ]*/)
  s=trim(T[1]); e=trim(T[2])

  s_ms=h2ms(s); e_ms=h2ms(e)
  if(e_ms<=s_ms) e_ms=s_ms+100

  # collect text lines
  text=""
  for(i=idx_hdr+1;i<=length(L);i++){
    if(length(text)) text = text "\n" L[i]; else text = L[i]
  }
  ttrim=trim(text)
  # length used for cps: characters excluding newlines
  gsub(/\n/,"",ttrim)
  chars=length(ttrim)
  dur=e_ms - s_ms
  if(dur<1) dur=1
  cps = (chars>0) ? (chars/(dur/1000.0)) : 0

  # extend by MIN_DUR
  if(dur < MIN_DUR){ e_ms = s_ms + MIN_DUR; dur=e_ms - s_ms }

  # extend to respect MAX_CPS
  if(MAX_CPS>0 && cps>MAX_CPS){
    need_ms = int((chars*1000.0)/MAX_CPS + 0.5)
    if(need_ms > dur){ e_ms = s_ms + need_ms; dur=e_ms - s_ms }
  }

  # gentle sentence pad
  if(is_end_sentence(text)){ e_ms += PAD_SENT }

  # store
  IDs[++N]=id
  SS[N]=s_ms; EE[N]=e_ms; TXT[N]=text
}
END{
  # enforce minimum gaps forward by shifting subsequent cues
  for(i=1;i<N;i++){
    gap=SS[i+1]-EE[i]
    if(gap < MIN_GAP){
      shift=MIN_GAP-gap
      # push i+1 start/end forward
      SS[i+1]+=shift; EE[i+1]+=shift
    }
  }
  # emit
  for(i=1;i<=N;i++){
    print IDs[i]
    print ms2h(SS[i]) " --> " ms2h(EE[i])
    print TXT[i]
  }
}
' "$IN" > "$OUT"
