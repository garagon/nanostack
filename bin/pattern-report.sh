#!/usr/bin/env bash
# pattern-report.sh — Cross-sprint pattern detection
# Reads artifacts to find recurring issues, risk accuracy, phase bottlenecks.
# Usage:
#   pattern-report.sh                    Current month
#   pattern-report.sh --month 2026-04    Specific month
#   pattern-report.sh --all              All time
#   pattern-report.sh --json             Machine-readable output
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

STORE="$NANOSTACK_STORE"
MONTH="$(date +"%Y-%m")"
JSON_OUTPUT=false
ALL_TIME=false

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    --all) ALL_TIME=true ;;
    --month) ;; # value handled below
    *)
      if [ "${prev_arg:-}" = "--month" ]; then
        MONTH="$arg"
      fi
      ;;
  esac
  prev_arg="$arg"
done

if [ ! -d "$STORE" ]; then
  echo "No nanostack data found."
  exit 0
fi

# ─── Helpers ──────────────────────────────────────────────

# Check if artifact matches time filter
in_range() {
  local file="$1"
  $ALL_TIME && return 0
  jq -e --arg m "$MONTH" '(.timestamp // .date) | startswith($m)' "$file" >/dev/null 2>&1
}

# ─── Collect artifacts ────────────────────────────────────

REVIEW_ARTIFACTS=""
SECURITY_ARTIFACTS=""
THINK_ARTIFACTS=""
PLAN_ARTIFACTS=""
SESSION_FILES=""
SPRINT_COUNT=0

# Review artifacts
if [ -d "$STORE/review" ]; then
  for f in "$STORE/review"/*.json; do
    [ -f "$f" ] || continue
    in_range "$f" && REVIEW_ARTIFACTS="$REVIEW_ARTIFACTS $f"
  done
fi

# Security artifacts
if [ -d "$STORE/security" ]; then
  for f in "$STORE/security"/*.json; do
    [ -f "$f" ] || continue
    in_range "$f" && SECURITY_ARTIFACTS="$SECURITY_ARTIFACTS $f"
  done
fi

# Think artifacts
if [ -d "$STORE/think" ]; then
  for f in "$STORE/think"/*.json; do
    [ -f "$f" ] || continue
    in_range "$f" && THINK_ARTIFACTS="$THINK_ARTIFACTS $f"
  done
fi

# Plan artifacts
if [ -d "$STORE/plan" ]; then
  for f in "$STORE/plan"/*.json; do
    [ -f "$f" ] || continue
    in_range "$f" && PLAN_ARTIFACTS="$PLAN_ARTIFACTS $f"
  done
fi

# Session files (archived)
if [ -d "$STORE/sessions" ]; then
  for f in "$STORE/sessions"/*.json; do
    [ -f "$f" ] || continue
    if $ALL_TIME; then
      SESSION_FILES="$SESSION_FILES $f"
      SPRINT_COUNT=$((SPRINT_COUNT + 1))
    elif jq -e --arg m "$MONTH" '.started_at | startswith($m)' "$f" >/dev/null 2>&1; then
      SESSION_FILES="$SESSION_FILES $f"
      SPRINT_COUNT=$((SPRINT_COUNT + 1))
    fi
  done
fi

# Current session counts too
if [ -f "$STORE/session.json" ]; then
  if $ALL_TIME || jq -e --arg m "$MONTH" '.started_at | startswith($m)' "$STORE/session.json" >/dev/null 2>&1; then
    SESSION_FILES="$SESSION_FILES $STORE/session.json"
    SPRINT_COUNT=$((SPRINT_COUNT + 1))
  fi
fi

# ─── 1. Recurring findings (tags from review + security) ─

declare -A TAG_COUNT 2>/dev/null || true
RECURRING_TAGS=""
TEMP_TAGS=$(mktemp)

for f in $REVIEW_ARTIFACTS $SECURITY_ARTIFACTS; do
  # Extract tags from findings
  jq -r '.findings[]?.tags[]? // empty' "$f" 2>/dev/null >> "$TEMP_TAGS"
  # Also extract categories/types
  jq -r '.findings[]?.category // empty' "$f" 2>/dev/null >> "$TEMP_TAGS"
  jq -r '.findings[]?.type // empty' "$f" 2>/dev/null >> "$TEMP_TAGS"
done

if [ -s "$TEMP_TAGS" ]; then
  RECURRING_TAGS=$(sort "$TEMP_TAGS" | uniq -c | sort -rn | head -10)
fi
rm -f "$TEMP_TAGS"

# ─── 2. Risk accuracy ────────────────────────────────────

RISKS_PREDICTED=0
RISKS_MATERIALIZED=0

for f in $THINK_ARTIFACTS; do
  RISK=$(jq -r 'if .summary | type == "object" then .summary.key_risk // empty elif .summary | type == "string" then .summary else empty end // .context_checkpoint.summary // empty' "$f" 2>/dev/null || true)
  [ -z "$RISK" ] && continue
  RISKS_PREDICTED=$((RISKS_PREDICTED + 1))

  # Check if the risk keywords appear in any review/security finding
  for rf in $REVIEW_ARTIFACTS $SECURITY_ARTIFACTS; do
    # Extract first 3 significant words from risk
    RISK_WORDS=$(echo "$RISK" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alpha:]' '\n' | grep -v -E '^(the|a|an|is|are|was|were|be|to|of|in|for|on|at|by|with|that|this|it|not|but|or|and|if|no)$' | head -3)
    MATCH=false
    for word in $RISK_WORDS; do
      [ ${#word} -lt 4 ] && continue
      if jq -e --arg w "$word" 'tostring | test($w; "i")' "$rf" >/dev/null 2>&1; then
        MATCH=true
        break
      fi
    done
    if [ "$MATCH" = true ]; then
      RISKS_MATERIALIZED=$((RISKS_MATERIALIZED + 1))
      break
    fi
  done
done

# ─── 3. Phase durations ──────────────────────────────────

TEMP_DURATIONS=$(mktemp)

for f in $SESSION_FILES; do
  jq -r '.phase_log[]? | select(.status == "completed" and .duration_seconds > 0) | "\(.phase) \(.duration_seconds)"' "$f" 2>/dev/null >> "$TEMP_DURATIONS"
done

PHASE_AVGS=""
if [ -s "$TEMP_DURATIONS" ]; then
  PHASE_AVGS=$(awk '{sum[$1]+=$2; count[$1]++} END {for(p in sum) printf "%s %d\n", p, sum[p]/count[p]}' "$TEMP_DURATIONS" | sort -k2 -rn)
fi
rm -f "$TEMP_DURATIONS"

# ─── 4. Solution reuse ───────────────────────────────────

SOLUTIONS_DIR="$STORE/know-how/solutions"
TOTAL_SOLUTIONS=0
VALIDATED_SOLUTIONS=0
TOTAL_APPLIED=0

if [ -d "$SOLUTIONS_DIR" ]; then
  while IFS= read -r sol; do
    [ -z "$sol" ] && continue
    TOTAL_SOLUTIONS=$((TOTAL_SOLUTIONS + 1))
    VAL=$(sed -n '/^---$/,/^---$/p' "$sol" | grep -i '^validated:' | head -1 | sed 's/^validated: *//i')
    [ "$VAL" = "true" ] && VALIDATED_SOLUTIONS=$((VALIDATED_SOLUTIONS + 1))
    AC=$(sed -n '/^---$/,/^---$/p' "$sol" | grep -i '^applied_count:' | head -1 | sed 's/^applied_count: *//i')
    [ -n "$AC" ] && [ "$AC" != "0" ] && TOTAL_APPLIED=$((TOTAL_APPLIED + AC))
  done < <(find "$SOLUTIONS_DIR" -name "*.md" -type f 2>/dev/null)
fi

# ─── Output ──────────────────────────────────────────────

PERIOD="$MONTH"
$ALL_TIME && PERIOD="all time"

if $JSON_OUTPUT; then
  # Build recurring tags JSON array
  TAGS_JSON="[]"
  if [ -n "$RECURRING_TAGS" ]; then
    TAGS_JSON=$(echo "$RECURRING_TAGS" | awk '{printf "{\"tag\":\"%s\",\"count\":%d},", $2, $1}' | sed 's/,$//' | sed 's/^/[/;s/$/]/')
  fi

  # Build phase durations JSON
  PHASES_JSON="{}"
  if [ -n "$PHASE_AVGS" ]; then
    PHASES_JSON=$(echo "$PHASE_AVGS" | awk '{printf "\"%s\":%d,", $1, $2}' | sed 's/,$//' | sed 's/^/{/;s/$/}/')
  fi

  RISK_PCT=0
  [ "$RISKS_PREDICTED" -gt 0 ] && RISK_PCT=$((RISKS_MATERIALIZED * 100 / RISKS_PREDICTED))

  jq -n \
    --arg period "$PERIOD" \
    --argjson sprints "$SPRINT_COUNT" \
    --argjson recurring "$TAGS_JSON" \
    --argjson risks_predicted "$RISKS_PREDICTED" \
    --argjson risks_materialized "$RISKS_MATERIALIZED" \
    --argjson risk_accuracy_pct "$RISK_PCT" \
    --argjson phase_avg_seconds "$PHASES_JSON" \
    --argjson solutions_total "$TOTAL_SOLUTIONS" \
    --argjson solutions_validated "$VALIDATED_SOLUTIONS" \
    --argjson solutions_applied "$TOTAL_APPLIED" \
    '{
      period: $period,
      sprints: $sprints,
      recurring_findings: $recurring,
      risk_accuracy: {
        predicted: $risks_predicted,
        materialized: $risks_materialized,
        accuracy_pct: $risk_accuracy_pct
      },
      phase_avg_seconds: $phase_avg_seconds,
      solutions: {
        total: $solutions_total,
        validated: $solutions_validated,
        total_applications: $solutions_applied
      }
    }'
  exit 0
fi

# Human-readable output
echo ""
echo "Pattern Report ($PERIOD)"
echo "════════════════════════════"
echo ""
echo "  Sprints analyzed: $SPRINT_COUNT"
echo ""

if [ -n "$RECURRING_TAGS" ]; then
  echo "  Recurring findings:"
  echo "$RECURRING_TAGS" | while read -r count tag; do
    [ -z "$tag" ] && continue
    printf "    %-30s %s occurrences\n" "$tag" "$count"
  done
  echo ""
fi

if [ "$RISKS_PREDICTED" -gt 0 ]; then
  RISK_PCT=$((RISKS_MATERIALIZED * 100 / RISKS_PREDICTED))
  echo "  Risk accuracy:"
  echo "    Predicted: $RISKS_PREDICTED"
  echo "    Materialized: $RISKS_MATERIALIZED ($RISK_PCT%)"
  echo ""
fi

if [ -n "$PHASE_AVGS" ]; then
  echo "  Phase durations (avg seconds):"
  echo "$PHASE_AVGS" | while read -r phase secs; do
    [ -z "$phase" ] && continue
    printf "    %-12s %ds\n" "$phase" "$secs"
  done
  echo ""
fi

if [ "$TOTAL_SOLUTIONS" -gt 0 ]; then
  echo "  Solutions:"
  echo "    Total: $TOTAL_SOLUTIONS"
  echo "    Validated: $VALIDATED_SOLUTIONS"
  echo "    Total applications: $TOTAL_APPLIED"
  echo ""
fi

if [ "$SPRINT_COUNT" -eq 0 ]; then
  echo "  No sprint data found for this period."
  echo ""
fi
