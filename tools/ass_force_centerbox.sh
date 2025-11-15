#!/usr/bin/env bash
# ass_force_centerbox.sh
# Purpose: enforce CenterBox-only captions by stripping any per-line
# alignment/position overrides such as {\an2}, {\pos(...)} or {\move(...)}.
#
# Usage:
#   tools/ass_force_centerbox.sh input.ass output.ass
#
# This DOES NOT change your styles, PlayRes, margins, or box settings.
# It only removes "escape hatch" tags that can move a single line
# away from the centered JF caption box.

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

TMP="${OUT}.tmp.$$"

# Strip per-line overrides:
#  - {\anX}      → alignment overrides (bottom, top, etc.)
#  - {\pos(...)} → absolute position overrides
#  - {\move(...)}→ animated move overrides
#
# We leave everything else (styles, margins, etc.) untouched so the
# default JF CenterBox style and geometry rule them all.

sed -E '
  s/\{\\an[0-9]+\}//g;
  s/\{\\pos\([^}]*\)\}//g;
  s/\{\\move\([^}]*\)\}//g
' "$IN" > "$TMP"

mv "$TMP" "$OUT"
echo "[i] Enforced CenterBox overrides in ASS: $OUT"
