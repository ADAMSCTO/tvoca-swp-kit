#!/usr/bin/env bash
# ass_force_centerbox.sh
# Purpose: enforce CenterBox-only captions by stripping any per-line
# alignment/position overrides such as {\an2}, {\pos(...)} or {\move(...)}.
#
# Additionally, we normalize Dialogue text so there are no stray leading
# or trailing "\N" lines that would visually push a single caption block
# lower or higher than the others. Internal "\N" are preserved.
#
# Usage:
#   tools/ass_force_centerbox.sh input.ass output.ass
#
# This DOES NOT change your styles, PlayRes, margins, or box settings.
# It only removes "escape hatch" tags and empty first/last lines in the
# Text field, so the JF CenterBox geometry rules them all.

set -euo pipefail

IN="${1:-}"
OUT="${2:-}"

if [ -z "$IN" ] || [ -z "$OUT" ]; then
  echo "Usage: $(basename "$0") input.ass output.ass" >&2
  exit 1
fi

if [ ! -f "$IN" ]; then
  echo "Missing input ASS: $IN" >&2
  exit 1
fi

TMP1="${OUT}.tmp1.$$"
TMP2="${OUT}.tmp2.$$"

# 1) Strip per-line overrides globally:
#    - {\anX}      → alignment overrides (bottom, top, etc.)
#    - {\pos(...)} → absolute position overrides
#    - {\move(...)}→ animated move overrides
sed -E '
  s/\{\\an[0-9]+\}//g;
  s/\{\\pos\([^}]*\)\}//g;
  s/\{\\move\([^}]*\)\}//g
' "$IN" > "$TMP1"

# 2) For Dialogue lines only, normalize the Text field:
#    - reconstruct Text from fields 10..NF so commas are preserved
#    - strip leading \N (possibly repeated, with spaces)
#    - strip trailing \N (possibly repeated, with spaces)
#      (internal \N are preserved)
awk -F',' '
BEGIN { OFS="," }

# Non-Dialogue lines: pass through unchanged
!/^Dialogue:/ { print; next }

{
  # Rebuild text from field 10..NF because Text may contain commas
  text = $10
  for (i = 11; i <= NF; i++) {
    text = text OFS $i
  }

  # Strip leading \N (possibly repeated) plus surrounding spaces
  gsub(/^[[:space:]]*\\N+/, "", text)

  # Strip trailing \N (possibly repeated) plus trailing spaces
  # Use a loop in case there are multiple stacked \N
  while (text ~ /(\\N[[:space:]]*)+$/) {
    sub(/(\\N[[:space:]]*)+$/, "", text)
  }

  # Push normalized text back into field 10, truncate NF to 10
  $10 = text
  NF = 10

  print
}
' "$TMP1" > "$TMP2"

mv "$TMP2" "$OUT"
echo "[i] Enforced CenterBox overrides + normalized Dialogue \\N in ASS: $OUT"
