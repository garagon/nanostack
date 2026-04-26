#!/usr/bin/env bash
# restore-context.sh — Read all completed phase checkpoints and output a condensed summary
# Usage: restore-context.sh [--phases "preflight onboard investigate"] [--max-age-days N] [--json]
# Default: reads all core phases from the last 30 days for the current project
# Output: human-readable summary (default) or JSON array (--json)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
. "$SCRIPT_DIR/lib/phases.sh"

PROJECT="$(pwd)"
MAX_AGE=30
PHASES_OVERRIDE=""
JSON_OUTPUT=false
TOKEN_BUDGET=0  # 0 = no budget, load full artifacts

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --phases) PHASES_OVERRIDE="$2"; shift 2 ;;
    --max-age-days) MAX_AGE="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    --budget) TOKEN_BUDGET="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Phases come from the registry (core + registered custom). An explicit
# --phases flag overrides the registry for advanced callers.
if [ -n "$PHASES_OVERRIDE" ]; then
  PHASES="$PHASES_OVERRIDE"
else
  PHASES=$(nano_all_phases)
fi

# If budget is set, estimate total upstream size and decide mode
CHECKPOINT_ONLY=false
if [ "$TOKEN_BUDGET" -gt 0 ]; then
  TOTAL_ESTIMATED=0
  for phase in $PHASES; do
    ARTIFACT=$("$SCRIPT_DIR/find-artifact.sh" "$phase" "$MAX_AGE" 2>/dev/null) || continue
    # Read estimated_tokens from the skill's SKILL.md, fall back to artifact size estimate
    NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    SKILL_MD=""
    case "$phase" in
      plan) SKILL_MD="$NANOSTACK_ROOT/plan/SKILL.md" ;;
      build) ;;
      *) SKILL_MD="$NANOSTACK_ROOT/$phase/SKILL.md" ;;
    esac
    EST=0
    if [ -n "$SKILL_MD" ] && [ -f "$SKILL_MD" ]; then
      EST=$(sed -n '/^---$/,/^---$/p' "$SKILL_MD" | grep '^estimated_tokens:' | head -1 | sed 's/^estimated_tokens: *//')
    fi
    [ -z "$EST" ] || [ "$EST" = "0" ] && EST=300
    TOTAL_ESTIMATED=$((TOTAL_ESTIMATED + EST))
  done

  if [ "$TOTAL_ESTIMATED" -gt "$TOKEN_BUDGET" ]; then
    CHECKPOINT_ONLY=true
  fi
fi

FOUND=0
JSON_ARRAY="["

for phase in $PHASES; do
  ARTIFACT=$("$SCRIPT_DIR/find-artifact.sh" "$phase" "$MAX_AGE" 2>/dev/null) || continue

  # Check if artifact has a context_checkpoint
  HAS_CHECKPOINT=$(jq -e '.context_checkpoint.summary' "$ARTIFACT" >/dev/null 2>&1 && echo "yes" || echo "no")

  STATUS=$(jq -r '.status // "completed"' "$ARTIFACT" 2>/dev/null)
  TIMESTAMP=$(jq -r '.timestamp // "unknown"' "$ARTIFACT" 2>/dev/null)

  if [ "$CHECKPOINT_ONLY" = true ] && [ "$HAS_CHECKPOINT" = "yes" ]; then
    # Budget exceeded: checkpoint only
    SUMMARY=$(jq -r '.context_checkpoint.summary' "$ARTIFACT")
    KEY_FILES=$(jq -r '.context_checkpoint.key_files // [] | join(", ")' "$ARTIFACT")
    DECISIONS=$(jq -r '.context_checkpoint.decisions_made // [] | join("; ")' "$ARTIFACT")
    OPEN_QS=$(jq -r '.context_checkpoint.open_questions // [] | join("; ")' "$ARTIFACT")
  elif [ "$HAS_CHECKPOINT" = "yes" ] && [ "$CHECKPOINT_ONLY" != true ]; then
    SUMMARY=$(jq -r '.context_checkpoint.summary' "$ARTIFACT")
    KEY_FILES=$(jq -r '.context_checkpoint.key_files // [] | join(", ")' "$ARTIFACT")
    DECISIONS=$(jq -r '.context_checkpoint.decisions_made // [] | join("; ")' "$ARTIFACT")
    OPEN_QS=$(jq -r '.context_checkpoint.open_questions // [] | join("; ")' "$ARTIFACT")
  else
    # No checkpoint: fall back to phase summary
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
