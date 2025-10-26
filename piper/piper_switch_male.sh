#!/usr/bin/env bash
set -euo pipefail

BASE="/c/jf/jirehfaith_swp_kit"
PROFILES="$BASE/voice/profiles"

usage() {
  echo "Usage: piper_switch_male.sh {ryan|bryce|status}"
  exit 1
}

ACTION="${1:-status}"

case "$ACTION" in
  ryan)
    cp -f "$PROFILES/male-ryan.env" "$PROFILES/male-default.env"
    echo "Male default set → Ryan"
    ;;
  bryce)
    cp -f "$PROFILES/male-bryce.env" "$PROFILES/male-default.env"
    echo "Male default set → Bryce"
    ;;
  status)
    echo "=== Current male-default.env ==="
    sed -n '1,200p' "$PROFILES/male-default.env"
    ;;
  *)
    usage
    ;;
esac
