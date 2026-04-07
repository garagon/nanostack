#!/usr/bin/env bash
# Guard: check-dangerous.sh
# Three-tier permission check inspired by Claude Code auto mode.
# Tier 1: Allowlist (always safe, skip checks)
# Tier 2: In-project operations (safe, reviewable via git)
# Tier 3: Pattern matching against block/warn rules
#
# On block: suggests a safer alternative (deny-and-continue).
# On warn: allows but flags the risk.
#
# Called by Claude Code's PreToolUse hook on Bash commands.
# Exit 0 = safe/warn, Exit 1 = blocked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RULES_FILE="$SCRIPT_DIR/rules.json"
CMD="${1:-$(cat)}"

# Fallback if rules.json missing
if [ ! -f "$RULES_FILE" ]; then
  echo "⚠️  GUARD: rules.json not found, allowing command"
  exit 0
fi

# ─── Tier 1: Allowlist ──────────────────────────────────────
# Extract first token of the command (the binary/builtin)
CMD_BASE=$(echo "$CMD" | awk '{print $1}' | sed 's|.*/||')

# Check if the command starts with an allowlisted command
ALLOWED=$(jq -r '.tiers.allowlist.commands[]' "$RULES_FILE" 2>/dev/null)
# Read allowlist into array
while IFS= read -r allowed; do
  [ -z "$allowed" ] && continue
  allowed_base=$(echo "$allowed" | awk '{print $1}' | sed 's|.*/||')
  if [ "$CMD_BASE" = "$allowed_base" ]; then
    # Multi-word entry: command must start with the full allowlist string
    if [ "$allowed_base" != "$allowed" ]; then
      if echo "$CMD" | grep -qF "$allowed" 2>/dev/null; then
        exit 0
      fi
    else
      # Single-word entry (e.g. "ls", "cat", "jq"): base match is enough
      exit 0
    fi
  fi
done <<< "$ALLOWED"

# ─── Tier 2: In-project operations ──────────────────────────
# If the command only touches files inside the current git repo,
# it's reviewable via version control. Let it through.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

if [ -n "$PROJECT_ROOT" ]; then
  # Commands that write files but stay in-project are Tier 2
  # We only check simple file-targeting commands, not pipes or chains
  case "$CMD" in
    # Skip tier 2 for chained/piped commands (too hard to analyze)
    *\|*|*\;*|*\&\&*) ;;
    *)
      # If command references files, check they're all in-project
      # Extract paths that look like file references
      ALL_IN_PROJECT=true
      for token in $CMD; do
        # Skip flags and the command itself
        case "$token" in
          -*|"$CMD_BASE") continue ;;
        esac
        # If it looks like a path and exists or starts with project root
        if [ -e "$token" ] || [[ "$token" == /* ]]; then
          REAL_PATH=$(realpath "$token" 2>/dev/null) || REAL_PATH="$token"
          case "$REAL_PATH" in
            "$PROJECT_ROOT"*) ;; # in project
            *) ALL_IN_PROJECT=false ;;
          esac
        fi
      done
      # Don't auto-pass if command has no file args (could be anything)
      if [ "$ALL_IN_PROJECT" = true ] && echo "$CMD" | grep -qE '/|\./' ; then
        exit 0
      fi
      ;;
  esac
fi

# ─── Tier 2.5: Phase-aware concurrency enforcement ─────────
# If a session is active and the current phase is read-only,
# block write operations to prevent race conditions in parallel execution.
GUARD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NANOSTACK_ROOT="$(cd "$GUARD_DIR/.." && pwd)"
STORE_PATH_SH="$NANOSTACK_ROOT/bin/lib/store-path.sh"

if [ -f "$STORE_PATH_SH" ]; then
  source "$STORE_PATH_SH"
  SESSION_CHECK="$NANOSTACK_STORE/session.json"

  if [ -f "$SESSION_CHECK" ]; then
    CURRENT_PHASE=$(jq -r '.current_phase // ""' "$SESSION_CHECK" 2>/dev/null)

    if [ -n "$CURRENT_PHASE" ]; then
      # Get concurrency from skill frontmatter
      SKILL_CONC=""
      case "$CURRENT_PHASE" in
        plan) SKILL_MD="$NANOSTACK_ROOT/plan/SKILL.md" ;;
        build) SKILL_MD="" ;;
        *) SKILL_MD="$NANOSTACK_ROOT/$CURRENT_PHASE/SKILL.md" ;;
      esac

      if [ -n "${SKILL_MD:-}" ] && [ -f "$SKILL_MD" ]; then
        SKILL_CONC=$(sed -n '/^---$/,/^---$/p' "$SKILL_MD" | grep '^concurrency:' | head -1 | sed 's/^concurrency: *//')
      fi

      # Block writes during read-only phases
      if [ "$SKILL_CONC" = "read" ]; then
        case "$CMD" in
          *rm\ *|*mv\ *|*cp\ *|*mkdir\ *|*touch\ *|*chmod\ *|*git\ add*|*git\ commit*|*git\ push*|*git\ reset*)
            echo "BLOCKED [PHASE] Write operation during read-only phase '$CURRENT_PHASE'"
            echo "Category: concurrency-safety"
            echo "Command: $CMD"
            echo ""
            echo "Phase '$CURRENT_PHASE' has concurrency=read. Write operations are blocked to prevent race conditions in parallel execution. Report as a finding instead of auto-fixing."
            exit 1
            ;;
        esac
      fi
    fi
  fi
fi

# ─── Tier 2.75: Sprint phase gate ──────────────────────────
# If a sprint is active, block git commit/push until review, security, qa are done.
PHASE_GATE="$(dirname "$0")/phase-gate.sh"
if [ -x "$PHASE_GATE" ]; then
  GATE_OUTPUT=$("$PHASE_GATE" "$CMD" 2>&1) || {
    echo "$GATE_OUTPUT"
    exit 1
  }
  # Print warnings (exit 0 with output = advisory)
  [ -n "$GATE_OUTPUT" ] && echo "$GATE_OUTPUT"
fi

# ─── Tier 3: Pattern matching ───────────────────────────────

# Check block rules first
BLOCK_COUNT=$(jq '.tiers.block.rules | length' "$RULES_FILE")
i=0
while [ "$i" -lt "$BLOCK_COUNT" ]; do
  PATTERN=$(jq -r ".tiers.block.rules[$i].pattern" "$RULES_FILE")
  if echo "$CMD" | grep -qiE -- "$PATTERN"; then
    ID=$(jq -r ".tiers.block.rules[$i].id" "$RULES_FILE")
    DESC=$(jq -r ".tiers.block.rules[$i].description" "$RULES_FILE")
    CATEGORY=$(jq -r ".tiers.block.rules[$i].category" "$RULES_FILE")
    ALT=$(jq -r ".tiers.block.rules[$i].alternative" "$RULES_FILE")

    echo "BLOCKED [$ID] $DESC"
    echo "Category: $CATEGORY"
    echo "Command: $CMD"
    echo ""
    echo "Safer alternative: $ALT"
    # Audit blocked command
    if [ -n "${NANOSTACK_STORE:-}" ] || [ -f "${STORE_PATH_SH:-}" ]; then
      [ -z "${NANOSTACK_STORE:-}" ] && source "$STORE_PATH_SH" 2>/dev/null || true
      AUDIT_LOG="${NANOSTACK_STORE:-}/audit.log"
      [ -n "$AUDIT_LOG" ] && [ -d "$(dirname "$AUDIT_LOG")" ] && \
        echo "{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cmd\":$(echo "$CMD" | jq -Rs .),\"result\":\"blocked\",\"rule\":\"$ID\"}" >> "$AUDIT_LOG" 2>/dev/null || true
    fi
    exit 1
  fi
  i=$((i + 1))
done

# Check warn rules
WARN_COUNT=$(jq '.tiers.warn.rules | length' "$RULES_FILE")
i=0
while [ "$i" -lt "$WARN_COUNT" ]; do
  PATTERN=$(jq -r ".tiers.warn.rules[$i].pattern" "$RULES_FILE")
  if echo "$CMD" | grep -qiE -- "$PATTERN"; then
    ID=$(jq -r ".tiers.warn.rules[$i].id" "$RULES_FILE")
    DESC=$(jq -r ".tiers.warn.rules[$i].description" "$RULES_FILE")
    CATEGORY=$(jq -r ".tiers.warn.rules[$i].category" "$RULES_FILE")

    echo "WARNING [$ID] $DESC"
    echo "Category: $CATEGORY"
    echo "Command: $CMD"
    echo ""
    echo "Proceeding. Consider the impact."
    exit 0
  fi
  i=$((i + 1))
done

# ─── Audit trail ────────────────────────────────────────────
# Append every evaluated command to .nanostack/audit.log (non-blocking)
if [ -n "${NANOSTACK_STORE:-}" ] || [ -f "$STORE_PATH_SH" ]; then
  [ -z "${NANOSTACK_STORE:-}" ] && source "$STORE_PATH_SH" 2>/dev/null || true
  AUDIT_LOG="${NANOSTACK_STORE:-}/audit.log"
  if [ -n "$AUDIT_LOG" ] && [ -d "$(dirname "$AUDIT_LOG")" ]; then
    echo "{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"cmd\":$(echo "$CMD" | jq -Rs .),\"result\":\"allowed\"}" >> "$AUDIT_LOG" 2>/dev/null || true
  fi
fi

# No rules matched. Allow.
exit 0
