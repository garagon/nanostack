#!/usr/bin/env bash
# sprint.sh — Multi-agent sprint coordinator
# Usage: sprint.sh <command> [args]
# Commands: start, claim, complete, abort, status, clean
set -e

CONDUCTOR_DIR="$HOME/.nanostack/conductor"
PROJECT="$(pwd)"
PROJECT_HASH=$(echo -n "$PROJECT" | shasum -a 256 | cut -c1-12)

# Default phases and dependency graph
DEFAULT_PHASES='[
  {"name":"think","depends_on":[]},
  {"name":"plan","depends_on":["think"]},
  {"name":"build","depends_on":["plan"]},
  {"name":"review","depends_on":["build"]},
  {"name":"qa","depends_on":["build"]},
  {"name":"security","depends_on":["build"]},
  {"name":"ship","depends_on":["review","qa","security"]}
]'

# Detect agent name (must be stable across invocations)
detect_agent() {
  if [ -n "${NANOSTACK_AGENT:-}" ]; then
    echo "$NANOSTACK_AGENT"
  elif [ -n "${CLAUDE_SESSION_ID:-}" ] || [ -n "${CLAUDE_CODE:-}" ]; then
    echo "claude"
  elif [ -n "${CODEX_SESSION_ID:-}" ]; then
    echo "codex"
  elif [ -n "${KIRO_SESSION_ID:-}" ]; then
    echo "kiro"
  else
    echo "agent-$(whoami)"
  fi
}

# Find active sprint for this project
find_sprint() {
  local latest
  latest=$(find "$CONDUCTOR_DIR" -name "sprint.json" -path "*${PROJECT_HASH}*" 2>/dev/null | while read -r f; do
    if jq -e --arg p "$PROJECT" '.project == $p and .status != "archived"' "$f" >/dev/null 2>&1; then
      echo "$f"
    fi
  done | sort -r | head -1)
  [ -n "$latest" ] && dirname "$latest" || return 1
}

# ─── start ───────────────────────────────────────────────────
cmd_start() {
  local phases="$DEFAULT_PHASES"
  local sprint_id="${PROJECT_HASH}-$(date -u +%Y%m%d-%H%M%S)"
  local sprint_dir="$CONDUCTOR_DIR/$sprint_id"

  # Archive any existing sprint for this project
  local existing
  existing=$(find_sprint 2>/dev/null) && {
    jq '.status = "archived"' "$existing/sprint.json" > "$existing/sprint.json.tmp"
    mv "$existing/sprint.json.tmp" "$existing/sprint.json"
  }

  mkdir -p "$sprint_dir"

  # Create phase directories
  echo "$phases" | jq -r '.[].name' | while read -r phase; do
    mkdir -p "$sprint_dir/$phase"
  done

  # Write sprint definition
  jq -n \
    --arg id "$sprint_id" \
    --arg project "$PROJECT" \
    --arg agent "$(detect_agent)" \
    --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson phases "$phases" \
    '{
      sprint_id: $id,
      project: $project,
      started_by: $agent,
      started_at: $date,
      status: "active",
      phases: $phases
    }' > "$sprint_dir/sprint.json"

  echo "$sprint_dir"
}

# ─── claim ───────────────────────────────────────────────────
cmd_claim() {
  local phase="${1:?Usage: sprint.sh claim <phase> [--agent <name>]}"
  local agent="${3:-$(detect_agent)}"
  local sprint_dir
  sprint_dir=$(find_sprint) || { echo "ERROR: no active sprint" >&2; exit 1; }

  local phase_dir="$sprint_dir/$phase"
  [ -d "$phase_dir" ] || { echo "ERROR: unknown phase '$phase'" >&2; exit 1; }

  # Check if already done
  if [ -f "$phase_dir/done" ]; then
    echo "DONE: '$phase' is already completed" >&2
    exit 1
  fi

  # Check dependencies
  local deps
  deps=$(jq -r --arg p "$phase" '.phases[] | select(.name == $p) | .depends_on[]' "$sprint_dir/sprint.json" 2>/dev/null)
  for dep in $deps; do
    if [ ! -f "$sprint_dir/$dep/done" ]; then
      echo "BLOCKED: '$phase' requires '$dep' to complete first" >&2
      exit 1
    fi
  done

  # Atomic claim via mkdir
  if ! mkdir "$phase_dir/lock.d" 2>/dev/null; then
    # Lock exists. Check who owns it.
    if [ -d "$phase_dir/lock" ]; then
      local lock_agent lock_age
      lock_agent=$(jq -r '.agent // ""' "$phase_dir/lock/meta.json" 2>/dev/null)

      # Same agent re-claiming: already yours
      if [ "$lock_agent" = "$agent" ]; then
        echo "OK"
        exit 0
      fi

      # Different agent: check for stale lock (>1h)
      lock_age=$(( $(date +%s) - $(stat -f %m "$phase_dir/lock/meta.json" 2>/dev/null || stat -c %Y "$phase_dir/lock/meta.json" 2>/dev/null || echo 0) ))
      local lock_pid
      lock_pid=$(jq -r '.pid // 0' "$phase_dir/lock/meta.json" 2>/dev/null)
      if [ "$lock_age" -gt 3600 ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -rf "$phase_dir/lock.d" "$phase_dir/lock"
        mkdir "$phase_dir/lock.d" 2>/dev/null || { echo "CLAIMED: '$phase' is locked by another agent" >&2; exit 1; }
      else
        echo "CLAIMED: '$phase' is locked by '$lock_agent'" >&2
        exit 1
      fi
    else
      echo "CLAIMED: '$phase' is being claimed by another agent" >&2
      exit 1
    fi
  fi

  # Write lock metadata
  jq -n \
    --arg agent "$agent" \
    --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson pid "$$" \
    '{agent: $agent, claimed_at: $date, pid: $pid}' > "$phase_dir/lock.d/meta.json"

  mv "$phase_dir/lock.d" "$phase_dir/lock" 2>/dev/null || {
    # Race condition — another agent got it
    rm -rf "$phase_dir/lock.d"
    echo "CLAIMED: lost race for '$phase'" >&2
    exit 1
  }

  echo "OK"
}

# ─── complete ────────────────────────────────────────────────
cmd_complete() {
  local phase="${1:?Usage: sprint.sh complete <phase> [--artifact <path>]}"
  local artifact="${3:-}"
  local agent="$(detect_agent)"
  local sprint_dir
  sprint_dir=$(find_sprint) || { echo "ERROR: no active sprint" >&2; exit 1; }

  local phase_dir="$sprint_dir/$phase"

  # Verify we hold the lock
  if [ ! -d "$phase_dir/lock" ]; then
    echo "ERROR: '$phase' is not claimed" >&2
    exit 1
  fi

  local lock_agent
  lock_agent=$(jq -r '.agent' "$phase_dir/lock/meta.json" 2>/dev/null)
  if [ "$lock_agent" != "$agent" ]; then
    echo "ERROR: '$phase' is claimed by '$lock_agent', not '$agent'" >&2
    exit 1
  fi

  # Write done marker
  local done_data
  done_data=$(jq -n \
    --arg agent "$agent" \
    --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg artifact "$artifact" \
    '{agent: $agent, completed_at: $date, artifact: $artifact}')

  echo "$done_data" > "$phase_dir/done"

  # Symlink artifact if provided
  [ -n "$artifact" ] && [ -f "$artifact" ] && ln -snf "$artifact" "$phase_dir/artifact.json"

  # Release lock
  rm -rf "$phase_dir/lock"

  # Check if sprint is complete
  local all_done=true
  jq -r '.phases[].name' "$sprint_dir/sprint.json" | while read -r p; do
    [ -f "$sprint_dir/$p/done" ] || { all_done=false; break; }
  done

  echo "OK"
}

# ─── abort ───────────────────────────────────────────────────
cmd_abort() {
  local phase="${1:?Usage: sprint.sh abort <phase>}"
  local sprint_dir
  sprint_dir=$(find_sprint) || { echo "ERROR: no active sprint" >&2; exit 1; }

  rm -rf "$sprint_dir/$phase/lock"
  echo "OK: '$phase' released"
}

# ─── status ──────────────────────────────────────────────────
cmd_status() {
  local sprint_dir
  sprint_dir=$(find_sprint) || { echo '{"status":"no_sprint"}'; exit 0; }

  local sprint_id
  sprint_id=$(jq -r '.sprint_id' "$sprint_dir/sprint.json")

  echo "{"
  echo "  \"sprint_id\": \"$sprint_id\","
  echo "  \"project\": \"$PROJECT\","
  echo "  \"phases\": {"

  local first=true
  jq -r '.phases[].name' "$sprint_dir/sprint.json" | while read -r phase; do
    local state="pending" agent="" ts=""
    if [ -f "$sprint_dir/$phase/done" ]; then
      state="done"
      agent=$(jq -r '.agent' "$sprint_dir/$phase/done" 2>/dev/null)
      ts=$(jq -r '.completed_at' "$sprint_dir/$phase/done" 2>/dev/null)
    elif [ -d "$sprint_dir/$phase/lock" ]; then
      state="running"
      agent=$(jq -r '.agent' "$sprint_dir/$phase/lock/meta.json" 2>/dev/null)
      ts=$(jq -r '.claimed_at' "$sprint_dir/$phase/lock/meta.json" 2>/dev/null)
    fi

    $first || echo ","
    first=false
    printf '    "%s": {"state":"%s","agent":"%s","at":"%s"}' "$phase" "$state" "$agent" "$ts"
  done

  echo ""
  echo "  }"
  echo "}"
}

# ─── clean ───────────────────────────────────────────────────
cmd_clean() {
  # Remove archived sprints older than 7 days
  find "$CONDUCTOR_DIR" -name "sprint.json" -mtime +7 2>/dev/null | while read -r f; do
    if jq -e '.status == "archived"' "$f" >/dev/null 2>&1; then
      rm -rf "$(dirname "$f")"
    fi
  done
  echo "OK: cleaned archived sprints older than 7 days"
}

# ─── dispatch ────────────────────────────────────────────────
CMD="${1:-status}"
shift || true

case "$CMD" in
  start)    cmd_start "$@" ;;
  claim)    cmd_claim "$@" ;;
  complete) cmd_complete "$@" ;;
  abort)    cmd_abort "$@" ;;
  status)   cmd_status "$@" ;;
  clean)    cmd_clean "$@" ;;
  *)
    echo "Usage: sprint.sh <start|claim|complete|abort|status|clean>" >&2
    exit 1
    ;;
esac
