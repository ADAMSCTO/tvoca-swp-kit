#!/usr/bin/env bash
set -euo pipefail
BASE="/c/jf/jirehfaith_swp_kit"
PROFILES="$BASE/voice/profiles"

echo "== Voice Profiles Folder =="
echo "$PROFILES"
echo

echo "-- Active male-default.env --"
if [ -f "$PROFILES/male-default.env" ]; then
  sed -n '1,200p' "$PROFILES/male-default.env"
else
  echo "Missing: $PROFILES/male-default.env"
fi
echo

echo "-- Available male profiles --"
for f in "$PROFILES"/male-*.env; do
  [ -f "$f" ] || continue
  printf "\n## %s ##\n" "$(basename "$f")"
  sed -n '1,200p' "$f"
done
echo
