#!/usr/bin/env bash
# sprint.sh — Multi-agent sprint coordinator
# Usage: sprint.sh <command> [args]
# Commands: start, claim, complete, abort, status, clean
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/bin/lib/store-path.sh"
source "$SCRIPT_DIR/bin/lib/audit.sh"

CONDUCTOR_DIR="$NANOSTACK_STORE/conductor"
PROJECT="$(pwd)"

# Use the centralized nano_sha256 from bin/lib/portable.sh (V4). Falls back
# to a local copy if that file is missing (older install) so sprint.sh stays
# standalone-runnable.
if [ -f "$SCRIPT_DIR/bin/lib/portable.sh" ]; then
  source "$SCRIPT_DIR/bin/lib/portable.sh"
else
  nano_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256
    else
      echo "ERROR: need sha256sum or shasum to compute project hash" >&2
      return 1
    fi
  }
fi
PROJECT_HASH=$(printf '%s' "$PROJECT" | nano_sha256 | cut -c1-12)

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

# Detect agent name. Identity must be stable within one process and unique
# across processes — two terminals running the same agent (e.g., two Claude
# Code sessions on the same machine) used to both resolve to "claude" and
# collide on the same lock.
#
# Strategy: <agent-family>-<short-id>, where short-id is the agent's session
# id when exposed, otherwise the parent shell PID. NANOSTACK_AGENT overrides
# everything for tests and explicit naming.
detect_agent() {
  if [ -n "${NANOSTACK_AGENT:-}" ]; then
    echo "$NANOSTACK_AGENT"
    return
  fi

  local family="" short_id=""
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    family="claude"
    short_id="${CLAUDE_SESSION_ID:0:8}"
  elif [ -n "${CLAUDE_CODE:-}" ]; then
    family="claude"
    short_id="$PPID"
  elif [ -n "${CODEX_SESSION_ID:-}" ]; then
    family="codex"
    short_id="${CODEX_SESSION_ID:0:8}"
  elif [ -n "${OPENCODE_SESSION_ID:-}" ]; then
    family="opencode"
    short_id="${OPENCODE_SESSION_ID:0:8}"
  else
    family="agent-$(whoami)"
    short_id="$PPID"
  fi

  echo "${family}-${short_id}"
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
  local explicit_phases=""

  # Parse args. Today only --phases is supported; future flags can hook in here.
  while [ $# -gt 0 ]; do
    case "$1" in
      --phases)
        if [ -z "${2:-}" ]; then
          echo "ERROR: --phases requires a JSON array or a path to a JSON file" >&2
          exit 2
        fi
        # If $2 is an existing file, read it; otherwise treat as inline JSON.
        if [ -f "$2" ]; then
          explicit_phases=$(cat "$2")
        else
          explicit_phases="$2"
        fi
        shift 2
        ;;
      *) shift ;;
    esac
  done

  # Phase source resolution:
  #   1. --phases <json|path>           (explicit user input — highest priority)
  #   2. .nanostack/config.json:phase_graph   (project-level customization)
  #   3. DEFAULT_PHASES                  (canonical core sprint)
  local nanostack_root
  nanostack_root="$(cd "$(dirname "$0")/../.." && pwd)"
  if [ -n "$explicit_phases" ]; then
    phases="$explicit_phases"
  elif [ -f "$nanostack_root/bin/lib/phases.sh" ]; then
    # nano_phase_graph_json returns the config graph if present and
    # valid, otherwise the canonical default. Either way conductor
    # gets a graph it can trust.
    . "$nanostack_root/bin/lib/phases.sh"
    phases=$(nano_phase_graph_json)
  fi

  # Validate the chosen graph. Rejects malformed structure, unknown
  # phase names, dangling depends_on, duplicate names, and cycles.
  # Falls back to the default graph rather than starting a sprint that
  # could deadlock or accept stray names.
  if [ -f "$nanostack_root/bin/lib/phases.sh" ]; then
    . "$nanostack_root/bin/lib/phases.sh"
    if ! _nano_phase_graph_is_valid "$phases"; then
      echo "ERROR: invalid phase graph (cycle, duplicate name, dangling depends_on, or unknown name)" >&2
      echo "       Falling back to the default graph or fix --phases / .nanostack/config.json:phase_graph." >&2
      exit 2
    fi
  fi

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

  audit_log "sprint_claim" "$phase" "$agent"
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

  audit_log "sprint_complete" "$phase" "$agent"
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
# Build the JSON entirely with jq so an agent name with quotes or backslashes
# cannot break the output. Previous version assembled it with printf and was
# brittle for any value with shell-special characters.
cmd_status() {
  local sprint_dir
  sprint_dir=$(find_sprint) || { echo '{"status":"no_sprint"}'; exit 0; }

  local sprint_id
  sprint_id=$(jq -r '.sprint_id' "$sprint_dir/sprint.json")

  # Walk each phase and emit one JSON object per line; jq -s wraps them in an
  # array which we then convert into the {phase: {state, agent, at}} map.
  local phases_json
  phases_json=$(jq -r '.phases[].name' "$sprint_dir/sprint.json" | while read -r phase; do
    local state="pending" agent="" ts=""
    if [ -f "$sprint_dir/$phase/done" ]; then
      state="done"
      agent=$(jq -r '.agent // ""' "$sprint_dir/$phase/done" 2>/dev/null)
      ts=$(jq -r '.completed_at // ""' "$sprint_dir/$phase/done" 2>/dev/null)
    elif [ -d "$sprint_dir/$phase/lock" ]; then
      state="running"
      agent=$(jq -r '.agent // ""' "$sprint_dir/$phase/lock/meta.json" 2>/dev/null)
      ts=$(jq -r '.claimed_at // ""' "$sprint_dir/$phase/lock/meta.json" 2>/dev/null)
    fi
    jq -n \
      --arg name "$phase" --arg state "$state" --arg agent "$agent" --arg at "$ts" \
      '{name: $name, state: $state, agent: $agent, at: $at}'
  done | jq -s 'map({(.name): {state: .state, agent: .agent, at: .at}}) | add // {}')

  jq -n \
    --arg sid "$sprint_id" \
    --arg project "$PROJECT" \
    --argjson phases "$phases_json" \
    '{sprint_id: $sid, project: $project, phases: $phases}'
}

# ─── next ────────────────────────────────────────────────────
# Print the first phase that is not done, has all dependencies met, and is
# not currently locked by anyone. Empty output means nothing is claimable
# right now (sprint complete, or all available phases held by other agents).
cmd_next() {
  local sprint_dir
  sprint_dir=$(find_sprint) || { echo "ERROR: no active sprint" >&2; exit 1; }

  jq -r '.phases[].name' "$sprint_dir/sprint.json" | while read -r phase; do
    # Skip done and locked phases
    [ -f "$sprint_dir/$phase/done" ] && continue
    [ -d "$sprint_dir/$phase/lock" ] && continue

    # Check deps
    local deps_met=true
    local deps
    deps=$(jq -r --arg p "$phase" '.phases[] | select(.name == $p) | .depends_on[]' "$sprint_dir/sprint.json" 2>/dev/null)
    for dep in $deps; do
      if [ ! -f "$sprint_dir/$dep/done" ]; then
        deps_met=false
        break
      fi
    done

    if [ "$deps_met" = true ]; then
      echo "$phase"
      return
    fi
  done
}

# ─── unstuck ─────────────────────────────────────────────────
# Force-release a lock when its owner PID is dead, without waiting the 1h
# grace period that claim's auto-recovery uses. Refuses if the PID is alive
# (you must let the owner finish or call abort yourself). Pass --force to
# release a lock with a live PID; required when stdin is not a TTY.
cmd_unstuck() {
  local phase="${1:?Usage: sprint.sh unstuck <phase> [--force]}"
  local force=false
  [ "${2:-}" = "--force" ] && force=true

  local sprint_dir
  sprint_dir=$(find_sprint) || { echo "ERROR: no active sprint" >&2; exit 1; }

  local lock_dir="$sprint_dir/$phase/lock"
  if [ ! -d "$lock_dir" ]; then
    echo "OK: '$phase' has no lock"
    return 0
  fi

  local lock_pid lock_agent
  lock_pid=$(jq -r '.pid // 0' "$lock_dir/meta.json" 2>/dev/null)
  lock_agent=$(jq -r '.agent // "unknown"' "$lock_dir/meta.json" 2>/dev/null)

  if [ "$lock_pid" -gt 0 ] && kill -0 "$lock_pid" 2>/dev/null; then
    if [ "$force" != true ]; then
      echo "REFUSED: '$phase' is held by '$lock_agent' (PID $lock_pid is alive)" >&2
      echo "Pass --force only if you are sure that process is no longer doing useful work." >&2
      exit 1
    fi
    echo "WARNING: forcing release of lock held by alive PID $lock_pid ($lock_agent)" >&2
  fi

  rm -rf "$lock_dir"
  audit_log "sprint_unstuck" "$phase" "$lock_agent"
  echo "OK: released '$phase' (was held by '$lock_agent')"
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

# ─── batch ──────────────────────────────────────────────────
# Read concurrency metadata from SKILL.md files and output execution batches.
# Phases with concurrency=read and all deps met run in parallel.
# Phases with concurrency=write run serial, one at a time.
# Phases with concurrency=exclusive run serial, no other phases.
cmd_batch() {
  local sprint_dir
  sprint_dir=$(find_sprint) || { echo "ERROR: no active sprint" >&2; exit 1; }

  local nanostack_root
  nanostack_root="$(cd "$(dirname "$0")/../.." && pwd)"
  # Source the registry so get_concurrency can locate custom skills
  # via nano_phase_skill_path. Unavailable in test sandboxes that
  # delete bin/lib/; in that case the helper still falls back to
  # built-in core paths and the safe "write" default.
  if [ -f "$nanostack_root/bin/lib/phases.sh" ]; then
    . "$nanostack_root/bin/lib/phases.sh"
  fi

  # Get concurrency for a phase from its SKILL.md frontmatter. Order:
  #   1. Built-in core skill at <nanostack_root>/<phase>/SKILL.md
  #   2. Custom skill resolved by the registry
  #   3. Conductor-only stage (build) returns "write"
  #   4. Unknown phase falls back to "write" with a warning so the
  #      sprint never schedules a custom phase as parallel-read by
  #      mistake.
  get_concurrency() {
    local phase="$1"
    local skill_md=""
    case "$phase" in
      build) echo "write"; return ;;
    esac
    # Built-in core skill path.
    if [ -f "$nanostack_root/$phase/SKILL.md" ]; then
      skill_md="$nanostack_root/$phase/SKILL.md"
    elif command -v nano_phase_skill_path >/dev/null 2>&1; then
      # Custom skill: registry walks .nanostack/skills, ~/.claude/skills,
      # and any configured skill_roots.
      local custom_dir
      custom_dir=$(nano_phase_skill_path "$phase" 2>/dev/null) || custom_dir=""
      if [ -n "$custom_dir" ] && [ -f "$custom_dir/SKILL.md" ]; then
        skill_md="$custom_dir/SKILL.md"
      fi
    fi
    if [ -n "$skill_md" ] && [ -f "$skill_md" ]; then
      local conc
      conc=$(sed -n '/^---$/,/^---$/p' "$skill_md" | grep '^concurrency:' | head -1 | sed 's/^concurrency: *//')
      echo "${conc:-write}"
    else
      # Honest about not finding metadata. Default to "write" so
      # conductor schedules conservatively (no accidental parallel
      # write/exclusive overlap) and emit a warning to stderr.
      echo "conductor: no SKILL.md found for phase '$phase'; defaulting concurrency=write" >&2
      echo "write"
    fi
  }

  local phases
  phases=$(jq -r '.phases[].name' "$sprint_dir/sprint.json")

  # Partition into execution batches
  # Track all phases scheduled in prior batches (considered "will be done")
  local batch_num=0
  local current_batch=""
  local current_type=""
  local scheduled=""

  for phase in $phases; do
    # Skip completed phases (but track them as available)
    if [ -f "$sprint_dir/$phase/done" ]; then
      scheduled="$scheduled $phase"
      continue
    fi

    # Check if deps are met (done on disk OR scheduled in a prior batch)
    local deps_met=true
    local deps
    deps=$(jq -r --arg p "$phase" '.phases[] | select(.name == $p) | .depends_on[]' "$sprint_dir/sprint.json" 2>/dev/null)
    for dep in $deps; do
      if [ ! -f "$sprint_dir/$dep/done" ]; then
        # Check if dep is scheduled in a prior batch (not current — current runs in parallel)
        if ! echo "$scheduled" | grep -qw "$dep" 2>/dev/null; then
          deps_met=false
          break
        fi
      fi
    done

    local conc
    conc=$(get_concurrency "$phase")

    if [ "$conc" = "read" ] && [ "$current_type" = "read" ] && [ "$deps_met" = true ]; then
      # Extend current read batch
      current_batch="$current_batch $phase"
    else
      # Flush previous batch
      if [ -n "$current_batch" ]; then
        batch_num=$((batch_num + 1))
        local phase_json
        phase_json=$(echo "$current_batch" | tr ' ' '\n' | grep -v '^$' | jq -R . | paste -sd, -)
        echo "{\"batch\":$batch_num,\"type\":\"$current_type\",\"phases\":[$phase_json]}"
        # Mark flushed phases as scheduled
        scheduled="$scheduled $current_batch"
      fi
      current_batch="$phase"
      current_type="$conc"
    fi
  done

  # Flush last batch
  if [ -n "$current_batch" ]; then
    batch_num=$((batch_num + 1))
    local phase_json
    phase_json=$(echo "$current_batch" | tr ' ' '\n' | grep -v '^$' | jq -R . | paste -sd, -)
    echo "{\"batch\":$batch_num,\"type\":\"$current_type\",\"phases\":[$phase_json]}"
  fi
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
  batch)    cmd_batch "$@" ;;
  clean)    cmd_clean "$@" ;;
  next)     cmd_next "$@" ;;
  unstuck)  cmd_unstuck "$@" ;;
  *)
    echo "Usage: sprint.sh <start|claim|complete|abort|status|batch|clean|next|unstuck>" >&2
    exit 1
    ;;
esac
