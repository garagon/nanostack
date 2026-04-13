#!/usr/bin/env bash
# loop-guard.sh — Detect stalled autopilot (no git diff between phases)
# Tracks git state fingerprint. If two consecutive checks show no change,
# the agent is stuck. Returns a warning block for the model to read.
#
# Usage: loop-guard.sh check     Check if stuck, return warning if yes
#        loop-guard.sh snapshot   Save current git fingerprint
#        loop-guard.sh reset      Clear tracked state
#
# Exit 0 always. Output is empty (no stall) or a warning block (stalled).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
source "$SCRIPT_DIR/lib/audit.sh"

STATE_FILE="$NANOSTACK_STORE/loop-guard.json"
CMD="${1:-check}"

# Git fingerprint: HEAD hash + working tree hash
git_fingerprint() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local head diff_hash
    head=$(git rev-parse HEAD 2>/dev/null || echo "none")
    diff_hash=$(git diff HEAD 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    echo "${head}:${diff_hash}"
  else
    echo "no-git"
  fi
}

case "$CMD" in
  snapshot)
    FP=$(git_fingerprint)
    jq -n --arg fp "$FP" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{fingerprint: $fp, captured_at: $at, no_change_count: 0}' > "$STATE_FILE"
    ;;

  reset)
    rm -f "$STATE_FILE"
    ;;

  check)
    [ -f "$STATE_FILE" ] || exit 0

    PREV_FP=$(jq -r '.fingerprint // ""' "$STATE_FILE" 2>/dev/null)
    NO_CHANGE=$(jq -r '.no_change_count // 0' "$STATE_FILE" 2>/dev/null)
    CURRENT_FP=$(git_fingerprint)

    if [ "$CURRENT_FP" = "$PREV_FP" ]; then
      NO_CHANGE=$((NO_CHANGE + 1))

      # Update state
      jq --arg fp "$CURRENT_FP" --argjson nc "$NO_CHANGE" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.fingerprint = $fp | .no_change_count = $nc | .last_check = $at' \
        "$STATE_FILE" > "${STATE_FILE}.tmp"
      mv "${STATE_FILE}.tmp" "$STATE_FILE"

      if [ "$NO_CHANGE" -ge 2 ]; then
        audit_log "loop_guard_triggered" "no_change_count=$NO_CHANGE"
        cat <<'WARN'
<LOOP_GUARD>
The last 2+ phases produced no changes to the repository.
You may be stuck. Before continuing:

1. Check if the build actually ran (look for new/modified files)
2. If blocked on something, stop and ask the user
3. If the task is already done, mark it complete and move on

Do NOT retry the same approach. Either fix the root cause or pause.
</LOOP_GUARD>
WARN
      fi
    else
      # Progress detected — reset counter, update fingerprint
      jq --arg fp "$CURRENT_FP" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.fingerprint = $fp | .no_change_count = 0 | .last_check = $at' \
        "$STATE_FILE" > "${STATE_FILE}.tmp"
      mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    ;;

  *)
    echo "Usage: loop-guard.sh <check|snapshot|reset>" >&2
    exit 1
    ;;
esac
