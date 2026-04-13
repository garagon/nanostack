#!/usr/bin/env bash
# sprint-metrics.sh — Deterministic git + session metrics for /think --retro
# Outputs JSON with lines changed, commits, files touched, cycle time, phase durations.
# No model judgment. Just data.
#
# Usage: sprint-metrics.sh [--days N]
#   --days N: look back N days (default: 7)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

DAYS=7
for arg in "$@"; do
  case "$arg" in
    --days) shift; DAYS="${1:-7}"; shift ;;
  esac
done

# ─── Git metrics ────────────────────────────────────────────

COMMITS=0
LINES_ADDED=0
LINES_REMOVED=0
FILES_CHANGED=0

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  COMMITS=$(git log --oneline --since="${DAYS} days ago" 2>/dev/null | wc -l | tr -d ' ')

  DIFFSTAT=$(git log --since="${DAYS} days ago" --format= --numstat 2>/dev/null | awk '
    { added += $1; removed += $2; files++ }
    END { printf "%d %d %d", added, removed, files }
  ' 2>/dev/null) || DIFFSTAT="0 0 0"

  LINES_ADDED=$(echo "$DIFFSTAT" | awk '{print $1}')
  LINES_REMOVED=$(echo "$DIFFSTAT" | awk '{print $2}')
  FILES_CHANGED=$(echo "$DIFFSTAT" | awk '{print $3}')
fi

# ─── Session cycle time ────────────────────────────────────

TOTAL_DURATION=0
SLOWEST_PHASE=""
SLOWEST_DURATION=0
PHASE_DURATIONS="{}"

# Read from most recent archived session + current session
SESSIONS=""
[ -f "$NANOSTACK_STORE/session.json" ] && SESSIONS="$NANOSTACK_STORE/session.json"
if [ -d "$NANOSTACK_STORE/sessions" ]; then
  LATEST_ARCHIVED=$(ls -t "$NANOSTACK_STORE/sessions"/*.json 2>/dev/null | head -1)
  [ -n "$LATEST_ARCHIVED" ] && SESSIONS="$LATEST_ARCHIVED $SESSIONS"
fi

if [ -n "$SESSIONS" ]; then
  # Read the most recent session with completed phases
  for sf in $SESSIONS; do
    [ -f "$sf" ] || continue
    HAS_COMPLETED=$(jq -r '[.phase_log[]? | select(.status=="completed")] | length' "$sf" 2>/dev/null)
    [ "${HAS_COMPLETED:-0}" -gt 0 ] || continue

    PHASE_DURATIONS=$(jq -c '[.phase_log[]? | select(.status=="completed" and .duration_seconds > 0) | {(.phase): .duration_seconds}] | add // {}' "$sf" 2>/dev/null) || PHASE_DURATIONS="{}"

    TOTAL_DURATION=$(jq -r '[.phase_log[]? | select(.status=="completed") | .duration_seconds // 0] | add // 0' "$sf" 2>/dev/null) || TOTAL_DURATION=0

    SLOWEST=$(jq -r '.phase_log[] | select(.status=="completed" and .duration_seconds > 0) | "\(.duration_seconds) \(.phase)"' "$sf" 2>/dev/null | sort -rn | head -1)
    if [ -n "$SLOWEST" ]; then
      SLOWEST_DURATION=$(echo "$SLOWEST" | awk '{print $1}')
      SLOWEST_PHASE=$(echo "$SLOWEST" | awk '{print $2}')
    fi

    break  # Use the most recent session with data
  done
fi

# ─── Output ─────────────────────────────────────────────────

jq -n \
  --argjson days "$DAYS" \
  --argjson commits "$COMMITS" \
  --argjson lines_added "$LINES_ADDED" \
  --argjson lines_removed "$LINES_REMOVED" \
  --argjson files_changed "$FILES_CHANGED" \
  --argjson total_duration "$TOTAL_DURATION" \
  --arg slowest_phase "$SLOWEST_PHASE" \
  --argjson slowest_duration "$SLOWEST_DURATION" \
  --argjson phase_durations "$PHASE_DURATIONS" \
  '{
    period_days: $days,
    git: {
      commits: $commits,
      lines_added: $lines_added,
      lines_removed: $lines_removed,
      files_changed: $files_changed
    },
    cycle_time: {
      total_seconds: $total_duration,
      slowest_phase: $slowest_phase,
      slowest_seconds: $slowest_duration,
      per_phase: $phase_durations
    }
  }'
