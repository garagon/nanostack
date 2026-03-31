#!/usr/bin/env bash
# restore-context.sh — Read all completed phase checkpoints and output a condensed summary
# Usage: restore-context.sh [--phases "preflight onboard investigate"] [--max-age-days N] [--json]
# Default: reads all core phases from the last 30 days for the current project
# Output: human-readable summary (default) or JSON array (--json)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

PROJECT="$(pwd)"
MAX_AGE=30
PHASES="think plan review qa security ship"
JSON_OUTPUT=false

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --phases) PHASES="$2"; shift 2 ;;
    --max-age-days) MAX_AGE="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    *) shift ;;
  esac
done

# Load custom phases from config
CONFIG="$NANOSTACK_STORE/config.json"
if [ -f "$CONFIG" ]; then
  CUSTOM=$(jq -r '.custom_phases // [] | join(" ")' "$CONFIG" 2>/dev/null || echo "")
  [ -n "$CUSTOM" ] && PHASES="$PHASES $CUSTOM"
fi

FOUND=0
JSON_ARRAY="["

for phase in $PHASES; do
  ARTIFACT=$("$SCRIPT_DIR/find-artifact.sh" "$phase" "$MAX_AGE" 2>/dev/null) || continue

  # Check if artifact has a context_checkpoint
  HAS_CHECKPOINT=$(jq -e '.context_checkpoint.summary' "$ARTIFACT" >/dev/null 2>&1 && echo "yes" || echo "no")

  STATUS=$(jq -r '.status // "completed"' "$ARTIFACT" 2>/dev/null)
  TIMESTAMP=$(jq -r '.timestamp // "unknown"' "$ARTIFACT" 2>/dev/null)

  if [ "$HAS_CHECKPOINT" = "yes" ]; then
    SUMMARY=$(jq -r '.context_checkpoint.summary' "$ARTIFACT")
    KEY_FILES=$(jq -r '.context_checkpoint.key_files // [] | join(", ")' "$ARTIFACT")
    DECISIONS=$(jq -r '.context_checkpoint.decisions_made // [] | join("; ")' "$ARTIFACT")
    OPEN_QS=$(jq -r '.context_checkpoint.open_questions // [] | join("; ")' "$ARTIFACT")
  else
    # Fall back to phase summary if no checkpoint
    SUMMARY=$(jq -r '.summary | to_entries | map("\(.key): \(.value)") | join(", ")' "$ARTIFACT" 2>/dev/null || echo "No summary")
    KEY_FILES=""
    DECISIONS=""
    OPEN_QS=""
  fi

  if $JSON_OUTPUT; then
    [ "$FOUND" -gt 0 ] && JSON_ARRAY="$JSON_ARRAY,"
    JSON_ARRAY="$JSON_ARRAY$(jq -n \
      --arg phase "$phase" \
      --arg status "$STATUS" \
      --arg timestamp "$TIMESTAMP" \
      --arg summary "$SUMMARY" \
      --arg key_files "$KEY_FILES" \
      --arg decisions "$DECISIONS" \
      --arg open_questions "$OPEN_QS" \
      --arg has_checkpoint "$HAS_CHECKPOINT" \
      '{phase: $phase, status: $status, timestamp: $timestamp, has_checkpoint: ($has_checkpoint == "yes"), summary: $summary, key_files: $key_files, decisions: $decisions, open_questions: $open_questions}')"
  else
    echo "## $phase ($STATUS)"
    echo "$SUMMARY"
    [ -n "$KEY_FILES" ] && echo "Files: $KEY_FILES"
    [ -n "$DECISIONS" ] && echo "Decisions: $DECISIONS"
    [ -n "$OPEN_QS" ] && echo "Open: $OPEN_QS"
    echo ""
  fi

  FOUND=$((FOUND + 1))
done

if $JSON_OUTPUT; then
  echo "$JSON_ARRAY]"
fi

if [ "$FOUND" -eq 0 ]; then
  if $JSON_OUTPUT; then
    echo "[]"
  else
    echo "No completed phase artifacts found for this project."
  fi
  exit 1
fi
