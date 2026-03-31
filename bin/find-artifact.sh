#!/usr/bin/env bash
# find-artifact.sh — Find the most recent artifact for a phase and project
# Usage: find-artifact.sh <phase> [max-age-days]
# Example: find-artifact.sh plan 2
# Returns: path to most recent artifact, or empty + exit 1 if none found
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

PHASE="${1:?Usage: find-artifact.sh <phase> [max-age-days]}"
MAX_AGE="${2:-30}"
STORE="$NANOSTACK_STORE/$PHASE"
PROJECT="$(pwd)"

[ -d "$STORE" ] || exit 1

VERIFY=false
[ "${3:-}" = "--verify" ] && VERIFY=true

RESULT=$(find "$STORE" -name "*.json" -mtime -"$MAX_AGE" 2>/dev/null | while read -r f; do
  # Pre-filter with grep before full jq parse (80% fewer jq calls on multi-project setups)
  if grep -q "$PROJECT" "$f" 2>/dev/null; then
    if jq -e --arg p "$PROJECT" '.project == $p' "$f" >/dev/null 2>&1; then
      echo "$f"
    fi
  fi
done | sort -r | head -1)

[ -n "$RESULT" ] || exit 1

# Verify artifact integrity if requested
if [ "$VERIFY" = true ]; then
  STORED_HASH=$(jq -r '.integrity // ""' "$RESULT" 2>/dev/null)
  if [ -n "$STORED_HASH" ]; then
    COMPUTED_HASH=$(jq -Sc 'del(.integrity)' "$RESULT" | shasum -a 256 | cut -d' ' -f1)
    if [ "$STORED_HASH" != "$COMPUTED_HASH" ]; then
      echo "INTEGRITY FAILED: $RESULT" >&2
      exit 1
    fi
  fi
fi

echo "$RESULT"
