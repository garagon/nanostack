#!/usr/bin/env bash
# session.sh — Session lifecycle management for crash recovery and resume
# Usage:
#   session.sh init <type> [--issue <url>]   Create session.json for current project
#   session.sh phase-start <phase>           Mark phase as in_progress
#   session.sh phase-complete <phase>        Mark phase as completed
#   session.sh resume                        Check for existing session, output resume info
#   session.sh status                        Output current session state
#   session.sh archive                       Archive current session
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

SESSION_FILE="$NANOSTACK_STORE/session.json"
PROJECT="$(pwd)"
PROJECT_NAME=$(basename "$PROJECT")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ─── init ───────────────────────────────────────────────────
cmd_init() {
  local type="${1:-development}"
  local issue_url=""

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) issue_url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Archive existing session if present
  if [ -f "$SESSION_FILE" ]; then
    local old_id
    old_id=$(jq -r '.session_id // "unknown"' "$SESSION_FILE")
    local archive_dir="$NANOSTACK_STORE/sessions"
    mkdir -p "$archive_dir"
    mv "$SESSION_FILE" "$archive_dir/${old_id}.json"
  fi

  local session_id="${PROJECT_NAME}-$(date -u +%Y%m%d-%H%M%S)"
  local repo=""
  repo=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||') || true

  jq -n \
    --arg id "$session_id" \
    --arg type "$type" \
    --arg issue "$issue_url" \
    --arg repo "$repo" \
    --arg workspace "$PROJECT" \
    --arg date "$NOW" \
    '{
      session_id: $id,
      type: $type,
      issue_url: (if $issue != "" then $issue else null end),
      repo: (if $repo != "" then $repo else null end),
      workspace: $workspace,
      current_phase: null,
      phase_log: [],
      budget: {
        max_usd: null,
        spent_usd: 0,
        tokens_input: 0,
        tokens_output: 0
      },
      started_at: $date,
      last_updated: $date
    }' > "$SESSION_FILE"

  echo "$SESSION_FILE"
}

# ─── phase-start ────────────────────────────────────────────
cmd_phase_start() {
  local phase="${1:?Usage: session.sh phase-start <phase>}"

  if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: no active session. Run 'session.sh init' first." >&2
    exit 1
  fi

  jq \
    --arg phase "$phase" \
    --arg date "$NOW" \
    '.current_phase = $phase |
     .phase_log += [{
       phase: $phase,
       status: "in_progress",
       started_at: $date,
       completed_at: null,
       artifact: null
     }] |
     .last_updated = $date' "$SESSION_FILE" > "${SESSION_FILE}.tmp"
  mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

  echo "OK: $phase started"
}

# ─── phase-complete ─────────────────────────────────────────
cmd_phase_complete() {
  local phase="${1:?Usage: session.sh phase-complete <phase>}"
  local artifact=""

  # Find the artifact for this phase
  artifact=$("$SCRIPT_DIR/find-artifact.sh" "$phase" 1 2>/dev/null) || true

  if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: no active session." >&2
    exit 1
  fi

  jq \
    --arg phase "$phase" \
    --arg date "$NOW" \
    --arg artifact "$artifact" \
    '(.phase_log[] | select(.phase == $phase and .status == "in_progress")) |=
       (.status = "completed" | .completed_at = $date | .artifact = (if $artifact != "" then $artifact else null end)) |
     .last_updated = $date' "$SESSION_FILE" > "${SESSION_FILE}.tmp"
  mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

  echo "OK: $phase completed"
}

# ─── resume ─────────────────────────────────────────────────
cmd_resume() {
  if [ ! -f "$SESSION_FILE" ]; then
    echo '{"resumable":false,"reason":"no_session"}'
    exit 0
  fi

  # Check if session belongs to this project
  local workspace
  workspace=$(jq -r '.workspace' "$SESSION_FILE")
  if [ "$workspace" != "$PROJECT" ]; then
    echo '{"resumable":false,"reason":"different_project"}'
    exit 0
  fi

  local session_id current_phase type
  session_id=$(jq -r '.session_id' "$SESSION_FILE")
  current_phase=$(jq -r '.current_phase // "none"' "$SESSION_FILE")
  type=$(jq -r '.type' "$SESSION_FILE")

  local completed_phases
  completed_phases=$(jq -r '[.phase_log[] | select(.status == "completed") | .phase] | join(", ")' "$SESSION_FILE")

  local last_status
  last_status=$(jq -r '.phase_log[-1].status // "none"' "$SESSION_FILE")

  local last_phase
  last_phase=$(jq -r '.phase_log[-1].phase // "none"' "$SESSION_FILE")

  jq -n \
    --arg resumable "true" \
    --arg session_id "$session_id" \
    --arg type "$type" \
    --arg current_phase "$current_phase" \
    --arg last_phase "$last_phase" \
    --arg last_status "$last_status" \
    --arg completed "$completed_phases" \
    '{
      resumable: true,
      session_id: $session_id,
      type: $type,
      current_phase: $current_phase,
      last_phase: $last_phase,
      last_status: $last_status,
      completed_phases: $completed,
      action: (if $last_status == "in_progress" then "restart_phase" else "next_phase" end)
    }'
}

# ─── status ─────────────────────────────────────────────────
cmd_status() {
  if [ ! -f "$SESSION_FILE" ]; then
    echo '{"active":false}'
    exit 0
  fi

  jq '{
    active: true,
    session_id: .session_id,
    type: .type,
    current_phase: .current_phase,
    phases_completed: [.phase_log[] | select(.status == "completed") | .phase],
    phases_in_progress: [.phase_log[] | select(.status == "in_progress") | .phase],
    started_at: .started_at,
    last_updated: .last_updated,
    budget: .budget
  }' "$SESSION_FILE"
}

# ─── archive ────────────────────────────────────────────────
cmd_archive() {
  if [ ! -f "$SESSION_FILE" ]; then
    echo "No active session to archive."
    exit 0
  fi

  local session_id
  session_id=$(jq -r '.session_id' "$SESSION_FILE")
  local archive_dir="$NANOSTACK_STORE/sessions"
  mkdir -p "$archive_dir"

  jq --arg date "$NOW" '.status = "archived" | .archived_at = $date' "$SESSION_FILE" > "$archive_dir/${session_id}.json"
  rm "$SESSION_FILE"

  echo "OK: archived $session_id"
}

# ─── dispatch ───────────────────────────────────────────────
CMD="${1:-status}"
shift || true

case "$CMD" in
  init)           cmd_init "$@" ;;
  phase-start)    cmd_phase_start "$@" ;;
  phase-complete) cmd_phase_complete "$@" ;;
  resume)         cmd_resume "$@" ;;
  status)         cmd_status "$@" ;;
  archive)        cmd_archive "$@" ;;
  *)
    echo "Usage: session.sh <init|phase-start|phase-complete|resume|status|archive>" >&2
    exit 1
    ;;
esac
