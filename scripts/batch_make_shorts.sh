#!/usr/bin/env bash
# Build a batch of shorts from voice/lines/*.txt
# Usage: batch_make_shorts.sh <male|female> <bg_path> [dur_per_line] [FONT_SIZE] [MARGIN_V]
set -euo pipefail
FAM="${1:-female}"
BG="${2:-/c/jf/jirehfaith_swp_kit/assets/bg/solid_1080x1920.png}"
DUR="${3:-3.5}"
export FONT_SIZE="${4:-36}"
export MARGIN_V="${5:-80}"

BASE="/c/jf/jirehfaith_swp_kit"
LINES_DIR="$BASE/voice/lines"

[ -f "$BG" ] || { echo "Missing BG: $BG"; exit 2; }

shopt -s nullglob
for FILE_PATH in "$LINES_DIR"/*.txt; do
  TAG="$(basename "$FILE_PATH" .txt)"
  echo "==> Building $TAG ($FAM) …"
  "$BASE/scripts/make_short_from_lines.sh" "$FAM" "$BG" "$FILE_PATH" "$TAG" "$DUR"
done
echo "All done. See: $BASE/out"
