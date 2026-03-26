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

RESULT=$(find "$STORE" -name "*.json" -mtime -"$MAX_AGE" 2>/dev/null | while read -r f; do
  if jq -e --arg p "$PROJECT" '.project == $p' "$f" >/dev/null 2>&1; then
    echo "$f"
  fi
done | sort -r | head -1)

[ -n "$RESULT" ] && echo "$RESULT" || exit 1
