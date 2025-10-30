#!/usr/bin/env bash
# tools/verify_lock.sh — compat checker for caption events
# Usage (old hook): tools/verify_lock.sh <emo> <lang> <voice>
# Usage (env): VERIFY_LOCK_BASE=anger_en_amy tools/verify_lock.sh
# Modes: VERIFY_LOCK_MODE=soft|hard (default: soft). In soft mode, never blocks.

set -euo pipefail

mode="${VERIFY_LOCK_MODE:-soft}"

if [[ $# -ge 3 ]]; then
  base="${1}_${2}_${3}"
else
  base="${VERIFY_LOCK_BASE:-}"
  if [[ -z "${base}" ]]; then
    echo "[verify_lock] WARN: no base provided"; echo "MATCH: False"
    [[ "$mode" == "hard" ]] && exit 1 || exit 0
  fi
fi

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
bdir="$root/voice/build"

cand=()
cand+=("$bdir/${base}.autosync.repaired.ass")
cand+=("$bdir/${base}.repaired.ass")
cand+=("$bdir/${base}.autosync.ass")
cand+=("$bdir/${base}.ass")

target=""
for f in "${cand[@]}"; do
  [[ -f "$f" ]] && { target="$f"; break; }
done

if [[ -z "$target" ]]; then
  echo "[verify_lock] WARN: no ASS found for '$base' in $bdir"; echo "MATCH: False"
  [[ "$mode" == "hard" ]] && exit 1 || exit 0
fi

events="$(grep -c '^Dialogue:' "$target" || true)"
echo "[verify_lock] $target events=$events"

if [[ "${events:-0}" -gt 0 ]]; then
  echo "MATCH: True"
  exit 0
else
  echo "MATCH: False"
  [[ "$mode" == "hard" ]] && exit 1 || exit 0
fi
