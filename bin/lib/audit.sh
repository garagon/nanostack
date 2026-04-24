#!/usr/bin/env bash
# audit.sh — Append structured lifecycle events to the audit log
# Source this file, then call: audit_log <event> <resource> [detail]
#
# Events: session_init, phase_start, phase_complete, artifact_saved,
#         solution_created, solution_graduated, budget_exceeded,
#         sprint_claim, sprint_complete

audit_log() {
  local event="$1" resource="${2:-}" detail="${3:-}"
  local store="${NANOSTACK_STORE:-}"

  # Resolve store path if not set
  if [ -z "$store" ]; then
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$git_root" ]; then
      store="$git_root/.nanostack"
    else
      store="$HOME/.nanostack"
    fi
  fi

  local log="$store/audit.log"
  [ -d "$store" ] || return 0

  # Build the line with jq so quotes, backslashes, and newlines in any
  # field are escaped and cannot corrupt the log or inject extra keys.
  # Falls back silently (|| true) if jq is unavailable; the audit log
  # is advisory, not a compliance artifact, so logging failures never
  # block the caller.
  jq -cn \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" \
    --arg resource "$resource" \
    --arg detail "$detail" \
    '{at:$at, event:$event, resource:$resource, detail:$detail}' \
    >> "$log" 2>/dev/null || true
}
