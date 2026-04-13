#!/usr/bin/env bash
# capture-failure.sh — Log a failure for future sprints to learn from
# Unlike /compound (which captures successes after ship), this captures
# what went wrong — CLI errors, wrong approaches, project quirks.
#
# Usage: capture-failure.sh <skill> <error> [approach] [resolution]
#   skill:      which skill was running (review, security, qa, etc.)
#   error:      what went wrong (one line)
#   approach:   what was tried (optional)
#   resolution: what fixed it or what to try next (optional)
#
# Appends to .nanostack/know-how/learnings/failures.jsonl (append-only).
# No compound needed. No success needed. Just log and move on.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
source "$SCRIPT_DIR/lib/audit.sh"

SKILL="${1:?Usage: capture-failure.sh <skill> <error> [approach] [resolution]}"
ERROR="${2:?Missing error description}"
APPROACH="${3:-}"
RESOLUTION="${4:-}"

DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROJECT=$(basename "$(pwd)")

FAILURES_DIR="$NANOSTACK_STORE/know-how/learnings"
FAILURES_FILE="$FAILURES_DIR/failures.jsonl"

mkdir -p "$FAILURES_DIR"

jq -nc \
  --arg date "$DATE" \
  --arg skill "$SKILL" \
  --arg error "$ERROR" \
  --arg approach "$APPROACH" \
  --arg resolution "$RESOLUTION" \
  --arg project "$PROJECT" \
  '{
    date: $date,
    skill: $skill,
    error: $error,
    approach: (if $approach != "" then $approach else null end),
    resolution: (if $resolution != "" then $resolution else null end),
    project: $project
  }' >> "$FAILURES_FILE"

audit_log "failure_captured" "$SKILL" "$ERROR"
echo "Captured in $FAILURES_FILE"
