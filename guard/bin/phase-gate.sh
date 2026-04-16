#!/usr/bin/env bash
# phase-gate.sh — Universal sprint phase enforcement
# Blocks git commit/push when a sprint is active and required phases are incomplete.
# Called from check-dangerous.sh as Tier 2.75.
#
# Sprint detection (two methods, hard then soft):
#   1. session.json exists for this project with phases started → BLOCK on missing
#   2. Recent plan artifact exists but no session → WARN (advisory)
#
# Exit 0 = allow, Exit 1 = blocked
set -euo pipefail

CMD="${1:-}"

# Only intercept git commit and git push
case "$CMD" in
  *git\ commit*|*git\ push*) ;;
  *) exit 0 ;;
esac

# Explicit bypass
if [ "${NANOSTACK_SKIP_GATE:-}" = "1" ]; then
  exit 0
fi

# ─── Resolve paths ──────────────────────────────────────────
GUARD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NANOSTACK_ROOT="$(cd "$GUARD_DIR/.." && pwd)"
STORE_PATH_SH="$NANOSTACK_ROOT/bin/lib/store-path.sh"

[ -f "$STORE_PATH_SH" ] || exit 0
source "$STORE_PATH_SH"

FIND_ARTIFACT="$NANOSTACK_ROOT/bin/find-artifact.sh"
SESSION_SH="$NANOSTACK_ROOT/bin/session.sh"
SESSION_FILE="$NANOSTACK_STORE/session.json"
PROJECT="$(pwd)"
REQUIRED_PHASES="review security qa"

# ─── Reference timestamp: latest code change ────────────────
last_code_timestamp() {
  local ts
  ts=$(git log -1 --format=%ct 2>/dev/null || echo 0)
  if [ "$ts" -eq 0 ]; then
    # No commits yet — use newest source file
    ts=$(find . -maxdepth 3 \( -name '*.js' -o -name '*.ts' -o -name '*.py' -o -name '*.go' -o -name '*.html' -o -name '*.css' -o -name '*.sh' \) 2>/dev/null \
      | head -20 | xargs stat -f %m 2>/dev/null | sort -rn | head -1 || echo 0)
  fi
  echo "$ts"
}

# ─── Check if required phase artifacts are fresh ────────────
# Returns space-separated list of missing phases
check_phases() {
  local last_change="$1"
  local missing=""

  for phase in $REQUIRED_PHASES; do
    local artifact
    artifact=$("$FIND_ARTIFACT" "$phase" 1 2>/dev/null) || {
      missing="${missing:+$missing }$phase"
      continue
    }
    # Verify artifact belongs to this project
    if ! jq -e --arg p "$PROJECT" '.project == $p' "$artifact" >/dev/null 2>&1; then
      missing="${missing:+$missing }$phase"
      continue
    fi
    # Verify artifact is newer than last code change
    local artifact_time
    artifact_time=$(stat -f %m "$artifact" 2>/dev/null || stat -c %Y "$artifact" 2>/dev/null || echo 0)
    if [ "$artifact_time" -lt "$last_change" ]; then
      missing="${missing:+$missing }$phase"
    fi
  done

  echo "$missing"
}

# ─── Print block message ───────────────────────────────────
print_block() {
  local missing="$1"
  echo "BLOCKED [PHASE-GATE] Sprint phases incomplete: $(echo "$missing" | tr ' ' ', ')"
  echo "Category: sprint-pipeline"
  echo ""
  echo "Action: complete these phases before committing:"
  for phase in $missing; do
    case "$phase" in
      review)   echo "  /review   — Code review" ;;
      security) echo "  /security — Security audit" ;;
      qa)       echo "  /qa       — Testing" ;;
    esac
  done
  echo ""
  echo "Bypass: NANOSTACK_SKIP_GATE=1 git commit ...   (non-sprint commits only)"
}

print_warning() {
  local missing="$1"
  echo "WARNING [PHASE-GATE] Sprint detected but phases incomplete: $(echo "$missing" | tr ' ' ', ')"
  echo ""
  echo "A plan artifact exists for this project. Consider running:"
  for phase in $missing; do
    case "$phase" in
      review)   echo "  /review   — Code review" ;;
      security) echo "  /security — Security audit" ;;
      qa)       echo "  /qa       — Testing" ;;
    esac
  done
  echo ""
  echo "Proceeding anyway (no active session). Use /feature or /think --autopilot for enforced sprints."
}

# ─── Method 1: Session-based detection (hard enforcement) ───
if [ -f "$SESSION_FILE" ]; then
  SESSION_PROJECT=$(jq -r '.workspace // ""' "$SESSION_FILE" 2>/dev/null)

  if [ "$SESSION_PROJECT" = "$PROJECT" ]; then
    # Skip if sprint is already shipped (completed)
    SHIP_DONE=$(jq -r '[.phase_log[] | select(.phase == "ship" and .status == "completed")] | length' "$SESSION_FILE" 2>/dev/null || echo "0")
    if [ "$SHIP_DONE" -gt 0 ]; then
      exit 0
    fi

    # Skip if no phases have started (session just initialized)
    PHASES_STARTED=$(jq -r '.phase_log | length' "$SESSION_FILE" 2>/dev/null || echo "0")
    if [ "$PHASES_STARTED" -eq 0 ]; then
      exit 0
    fi

    # Active sprint — enforce
    LAST_CHANGE=$(last_code_timestamp)
    MISSING=$(check_phases "$LAST_CHANGE")

    if [ -n "$MISSING" ]; then
      print_block "$MISSING"

      # Audit
      if [ -d "$(dirname "$NANOSTACK_STORE/audit.log")" ]; then
        echo "{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"phase-gate-block\",\"missing\":\"$MISSING\",\"cmd\":$(echo "$CMD" | jq -Rs .)}" >> "$NANOSTACK_STORE/audit.log" 2>/dev/null || true
      fi

      exit 1
    fi

    # All phases complete
    exit 0
  fi
fi

# ─── Method 2: Artifact-based detection (soft enforcement) ──
if [ -x "$FIND_ARTIFACT" ]; then
  PLAN_ARTIFACT=$("$FIND_ARTIFACT" plan 1 2>/dev/null) || true

  if [ -n "$PLAN_ARTIFACT" ]; then
    PLAN_PROJECT=$(jq -r '.project // ""' "$PLAN_ARTIFACT" 2>/dev/null)

    if [ "$PLAN_PROJECT" = "$PROJECT" ]; then
      LAST_CHANGE=$(last_code_timestamp)
      MISSING=$(check_phases "$LAST_CHANGE")

      if [ -n "$MISSING" ]; then
        # Soft enforcement: warn but allow
        print_warning "$MISSING"
        exit 0
      fi
    fi
  fi
fi

# No sprint detected
exit 0
