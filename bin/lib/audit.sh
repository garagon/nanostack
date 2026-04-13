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

  printf '{"at":"%s","event":"%s","resource":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$event" \
    "$resource" \
    "$detail" >> "$log" 2>/dev/null || true
}
