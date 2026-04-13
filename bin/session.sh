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
source "$SCRIPT_DIR/lib/audit.sh"

SESSION_FILE="$NANOSTACK_STORE/session.json"
PROJECT="$(pwd)"
PROJECT_NAME=$(basename "$PROJECT")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ─── init ───────────────────────────────────────────────────
cmd_init() {
  local type="${1:-development}"
  local issue_url=""
  local autopilot="false"
  local goal=""

  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) issue_url="$2"; shift 2 ;;
      --autopilot) autopilot="true"; shift ;;
      --goal) goal="$2"; shift 2 ;;
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
    --arg goal "$goal" \
    --arg repo "$repo" \
    --arg workspace "$PROJECT" \
    --arg date "$NOW" \
    --argjson autopilot "$autopilot" \
    '{
      session_id: $id,
      type: $type,
      issue_url: (if $issue != "" then $issue else null end),
      goal: (if $goal != "" then $goal else null end),
      repo: (if $repo != "" then $repo else null end),
      workspace: $workspace,
      current_phase: null,
      next_phase: null,
      autopilot: $autopilot,
      stop_conditions_met: [],
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

  audit_log "session_init" "$session_id" "$type"
  echo "$SESSION_FILE"
}

# ─── phase-start ────────────────────────────────────────────
cmd_phase_start() {
  local phase="${1:?Usage: session.sh phase-start <phase>}"

  if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: no active session. Run 'session.sh init' first." >&2
    exit 1
  fi

  # Idempotent: skip if phase already completed or in progress
  local existing
  existing=$(jq -r --arg p "$phase" \
    '[.phase_log[] | select(.phase == $p and (.status == "completed" or .status == "in_progress"))] | length' \
    "$SESSION_FILE" 2>/dev/null || echo "0")
  if [ "$existing" -gt 0 ]; then
    echo "OK: $phase already in log"
    return 0
  fi

  local epoch
  epoch=$(date +%s)

  jq \
    --arg phase "$phase" \
    --arg date "$NOW" \
    --argjson epoch "$epoch" \
    '.current_phase = $phase |
     .phase_log += [{
       phase: $phase,
       status: "in_progress",
       started_at: $date,
       started_epoch: $epoch,
       completed_at: null,
       artifact: null
     }] |
     .last_updated = $date' "$SESSION_FILE" > "${SESSION_FILE}.tmp"
  mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

  audit_log "phase_start" "$phase"
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

  # Calculate next phase from default sequence
  local next=""
  case "$phase" in
    think) next="plan" ;;
    plan)  next="build" ;;
    build) next="review" ;;
    review)
      # Check if qa and security are done
      local qa_done sec_done
      qa_done=$(jq -r '[.phase_log[] | select(.phase == "qa" and .status == "completed")] | length' "$SESSION_FILE")
      sec_done=$(jq -r '[.phase_log[] | select(.phase == "security" and .status == "completed")] | length' "$SESSION_FILE")
      if [ "$qa_done" -gt 0 ] && [ "$sec_done" -gt 0 ]; then next="ship"
      elif [ "$qa_done" -gt 0 ]; then next="security"
      else next="qa"
      fi
      ;;
    qa)
      local rev_done sec_done
      rev_done=$(jq -r '[.phase_log[] | select(.phase == "review" and .status == "completed")] | length' "$SESSION_FILE")
      sec_done=$(jq -r '[.phase_log[] | select(.phase == "security" and .status == "completed")] | length' "$SESSION_FILE")
      if [ "$rev_done" -gt 0 ] && [ "$sec_done" -gt 0 ]; then next="ship"
      elif [ "$rev_done" -gt 0 ]; then next="security"
      else next="review"
      fi
      ;;
    security)
      local rev_done qa_done
      rev_done=$(jq -r '[.phase_log[] | select(.phase == "review" and .status == "completed")] | length' "$SESSION_FILE")
      qa_done=$(jq -r '[.phase_log[] | select(.phase == "qa" and .status == "completed")] | length' "$SESSION_FILE")
      if [ "$rev_done" -gt 0 ] && [ "$qa_done" -gt 0 ]; then next="ship"
      elif [ "$rev_done" -gt 0 ]; then next="qa"
      else next="review"
      fi
      ;;
    ship) next="compound" ;;
    compound) next="" ;;
  esac

  # Calculate duration from stored epoch
  local duration=0
  local start_epoch
  start_epoch=$(jq -r --arg phase "$phase" \
    '.phase_log[] | select(.phase == $phase and .status == "in_progress") | .started_epoch // 0' "$SESSION_FILE" 2>/dev/null)
  if [ "$start_epoch" -gt 0 ]; then
    local end_epoch
    end_epoch=$(date +%s)
    duration=$((end_epoch - start_epoch))
  fi

  jq \
    --arg phase "$phase" \
    --arg date "$NOW" \
    --arg artifact "$artifact" \
    --arg next "$next" \
    --argjson duration "$duration" \
    '(.phase_log[] | select(.phase == $phase and .status == "in_progress")) |=
       (.status = "completed" | .completed_at = $date | .duration_seconds = $duration | .artifact = (if $artifact != "" then $artifact else null end)) |
     .next_phase = (if $next != "" then $next else null end) |
     .last_updated = $date' "$SESSION_FILE" > "${SESSION_FILE}.tmp"
  mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

  audit_log "phase_complete" "$phase" "${duration}s"
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

  local session_id current_phase type autopilot next_phase
  session_id=$(jq -r '.session_id' "$SESSION_FILE")
  current_phase=$(jq -r '.current_phase // "none"' "$SESSION_FILE")
  type=$(jq -r '.type' "$SESSION_FILE")
  autopilot=$(jq -r '.autopilot // false' "$SESSION_FILE")
  next_phase=$(jq -r '.next_phase // "none"' "$SESSION_FILE")

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
    --argjson autopilot "$autopilot" \
    --arg next_phase "$next_phase" \
    '{
      resumable: true,
      session_id: $session_id,
      type: $type,
      autopilot: $autopilot,
      current_phase: $current_phase,
      next_phase: $next_phase,
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
