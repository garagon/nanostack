#!/usr/bin/env bash
# find-artifact.sh — Find the most recent artifact for a phase and project
# Usage: find-artifact.sh <phase> [max-age-days]
# Example: find-artifact.sh plan 2
# Returns: path to most recent artifact, or empty + exit 1 if none found
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
[ -f "$SCRIPT_DIR/lib/cache.sh" ] && source "$SCRIPT_DIR/lib/cache.sh"
[ -f "$SCRIPT_DIR/lib/portable.sh" ] && source "$SCRIPT_DIR/lib/portable.sh"

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

# ─── Session sync: register phase if session is active ──────
# When a downstream skill reads an artifact, ensure the producing
# phase is registered in the session. Covers cases where the model
# saved the artifact but didn't call session.sh directly.
# NOTE: Only calls phase-start, NOT phase-complete (which would
# recurse back to find-artifact.sh and hang). The phase stays
# "in_progress" until save-artifact.sh completes it.
SESSION_FILE="$NANOSTACK_STORE/session.json"
if [ -f "$SESSION_FILE" ]; then
  # Cache the phase list extracted from session.json. Multiple find-artifact.sh
  # calls in one resolve.sh run reuse the same list; session.sh writes bump
  # session.json's mtime which invalidates the cache automatically.
  PHASE_LIST_CACHE=""
  if declare -F nano_cache_dir >/dev/null 2>&1; then
    PHASE_LIST_CACHE="$(nano_cache_dir)/session-phases"
  fi

  if [ -n "$PHASE_LIST_CACHE" ] && nano_cache_fresh "$PHASE_LIST_CACHE" 60 "$SESSION_FILE" 2>/dev/null; then
    PHASE_LIST=$(cat "$PHASE_LIST_CACHE")
  else
    PHASE_LIST=$(jq -r '.phase_log[].phase' "$SESSION_FILE" 2>/dev/null || echo "")
    [ -n "$PHASE_LIST_CACHE" ] && printf '%s\n' "$PHASE_LIST" > "$PHASE_LIST_CACHE" 2>/dev/null || true
  fi

  if ! printf '%s\n' "$PHASE_LIST" | grep -qx "$PHASE" 2>/dev/null; then
    SESSION_SH="$SCRIPT_DIR/session.sh"
    if [ -x "$SESSION_SH" ]; then
      "$SESSION_SH" phase-start "$PHASE" >/dev/null 2>&1 || true
    fi
  fi
fi

# Verify artifact integrity if requested
if [ "$VERIFY" = true ]; then
  STORED_HASH=$(jq -r '.integrity // ""' "$RESULT" 2>/dev/null)
  if [ -n "$STORED_HASH" ]; then
    if declare -F nano_sha256 >/dev/null 2>&1; then
      COMPUTED_HASH=$(jq -Sc 'del(.integrity)' "$RESULT" | nano_sha256 | cut -d' ' -f1)
    else
      COMPUTED_HASH=$(jq -Sc 'del(.integrity)' "$RESULT" | shasum -a 256 | cut -d' ' -f1)
    fi
    if [ "$STORED_HASH" != "$COMPUTED_HASH" ]; then
      echo "INTEGRITY FAILED: $RESULT" >&2
      exit 1
    fi
  fi
fi

echo "$RESULT"
