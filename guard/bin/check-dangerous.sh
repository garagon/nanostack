#!/usr/bin/env bash
# Guard: check-dangerous.sh
# Layered permission check for every Bash call. Block rules run before
# the allowlist so allowlisted binaries (cat, find, head, tail) still
# match known-bad patterns like `cat .env` or `find . -delete`.
#
# Order:
#   Block rules                (no exceptions, fail closed)
#   Allowlist                  (safe commands short-circuit)
#   Phase-aware concurrency    (read phases block write commands)
#   In-project fast-path       (git-reviewable changes pass)
#   Sprint phase gate          (blocks commit/push until required
#                               ancestors of ship are complete)
#   Budget gate                (blocks all commands when over budget)
#   Warn rules                 (allowed but flagged)
#
# On block: suggests a safer alternative (deny-and-continue).
# On warn: allows but flags the risk.
#
# Called by the PreToolUse hook on Bash commands (Claude Code hosts the
# hook directly; other adapters install per their host docs).
# Exit 0 = safe/warn, Exit 1 = blocked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RULES_FILE="$SCRIPT_DIR/rules.json"
CMD="${1:-$(cat)}"

# Resolve the nanostack root and store-path helper up front so every
# downstream tier (block, warn, audit trail) sees a consistent view.
# Previously STORE_PATH_SH was set inside Tier 2.5, which meant Tier
# 1.5 blocks never appended to audit.log when NANOSTACK_STORE was
# unset. Doing it here keeps blocking and trace visibility together.
GUARD_DIR="$SCRIPT_DIR"
NANOSTACK_ROOT="$(cd "$GUARD_DIR/.." && pwd)"
STORE_PATH_SH="$NANOSTACK_ROOT/bin/lib/store-path.sh"
if [ -z "${NANOSTACK_STORE:-}" ] && [ -f "$STORE_PATH_SH" ]; then
  # shellcheck disable=SC1090
  source "$STORE_PATH_SH" 2>/dev/null || true
fi
AUDIT_LOG="${NANOSTACK_STORE:-}/audit.log"

# Fallback if rules.json missing
if [ ! -f "$RULES_FILE" ]; then
  echo "⚠️  GUARD: rules.json not found, allowing command"
  exit 0
fi

# Helper: append a JSON record to the audit log if the store resolved.
# No-op when the store is unavailable so guard still blocks even on
# machines without a configured .nanostack/ directory.
audit_trail_append() {
  local result="$1" rule="$2"
  [ -n "${AUDIT_LOG:-}" ] && [ -d "$(dirname "$AUDIT_LOG")" ] || return 0
  jq -cn \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cmd "$CMD" \
    --arg result "$result" \
    --arg rule "$rule" \
    '{at:$at, cmd:$cmd, result:$result, rule:$rule}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

CMD_BASE=$(echo "$CMD" | awk '{print $1}' | sed 's|.*/||')

BLOCK_INPUT="$CMD"

# Catastrophic recursive rm, independent of flag spelling and operand order.
# The rm rules (G-001..G-004) are written against the canonical
# `rm -rf <target>`, but `rm -fr`, `rm -r -f`, `rm --recursive --force`,
# `rm -r -f -- ~`, `rm -r --interactive=never *`, and `rm -fr /tmp /` are the
# same operation. Rather than rewrite flags in place (which is sensitive to
# operand position), detect a recursive rm and then scan every operand for a
# catastrophic target (root, home, current dir, wildcard) in any quoting. For
# each catastrophic target found, append the canonical form so the existing
# rules fire. A recursive cleanup of an ordinary path (e.g. `rm -r /tmp/build`)
# has no catastrophic operand, so nothing is appended and it is not blocked.
if printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])rm[[:space:]]+([-][-a-zA-Z0-9=]*[[:space:]]+)*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)' 2>/dev/null; then
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?/+[*]?[\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf /"
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?~/?[*]?[\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf ~"
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?[*][\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf *"
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?[.]/?[\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf ."
fi

# Heredoc and other multi-line invocations put the interpreter on one line
# and the secret read on another. Add a newline-flattened copy so rules like
# the interpreter secret-read guard (G-036) can match across the lines.
case "$CMD" in
  *"
"*)
    FLAT_CMD=$(printf '%s' "$CMD" | tr '\n' ' ')
    [ -n "$FLAT_CMD" ] && BLOCK_INPUT="$BLOCK_INPUT
$FLAT_CMD"
    ;;
esac

# ─── Tier 1: Block rules (authoritative, no exceptions) ─────
# Block patterns run before the allowlist so commands whose binary
# happens to be on the allowlist (cat, find, head, tail) still get
# evaluated against known-bad patterns such as reading .env or
# find . -delete. Previous ordering let allowlisted binaries short
# circuit past block rules; audit finding from April 2026.
BLOCK_PATTERNS=$(jq -r '.tiers.block.rules[] | .pattern' "$RULES_FILE" 2>/dev/null)
BLOCK_COMBINED=$(echo "$BLOCK_PATTERNS" | paste -sd'|' -)
if [ -n "$BLOCK_COMBINED" ] && printf '%s\n' "$BLOCK_INPUT" | grep -qiE -- "$BLOCK_COMBINED" 2>/dev/null; then
  BLOCK_IDX=0
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if printf '%s\n' "$BLOCK_INPUT" | grep -qiE -- "$PATTERN" 2>/dev/null; then
      RULE=$(jq -c ".tiers.block.rules[$BLOCK_IDX]" "$RULES_FILE")
      ID=$(echo "$RULE" | jq -r '.id')
      DESC=$(echo "$RULE" | jq -r '.description')
      CATEGORY=$(echo "$RULE" | jq -r '.category')
      ALT=$(echo "$RULE" | jq -r '.alternative')

      echo "BLOCKED [$ID] $DESC"
      echo "Category: $CATEGORY"
      echo "Command: $CMD"
      echo ""
      echo "Safer alternative: $ALT"
      audit_trail_append blocked "$ID"
      exit 1
    fi
    BLOCK_IDX=$((BLOCK_IDX + 1))
  done <<< "$BLOCK_PATTERNS"
fi

# ─── Tier 2: Allowlist ──────────────────────────────────────
# Runs only after block rules had a chance to fire. For commands
# that matched no block, a matching allowlist entry short-circuits
# the remaining tiers.
TIER1=$(jq -r --arg cmd "$CMD" --arg base "$CMD_BASE" '
  .tiers.allowlist.commands[] |
  split(" ")[0] | gsub(".*/"; "") |
  select(. == $base)' "$RULES_FILE" 2>/dev/null | head -1)

if [ -n "$TIER1" ]; then
  # Base matches. For multi-word entries, verify full match
  MULTI=$(jq -r --arg base "$CMD_BASE" '
    .tiers.allowlist.commands[] |
    select((split(" ")[0] | gsub(".*/"; "")) == $base and (split(" ") | length) > 1)' "$RULES_FILE" 2>/dev/null | head -1)
  if [ -z "$MULTI" ]; then
    # Single-word entry: base match is enough
    exit 0
  elif echo "$CMD" | grep -qF "$MULTI" 2>/dev/null; then
    exit 0
  fi
fi

# ─── Tier 2.4: Phase-aware concurrency enforcement ─────────
# Runs BEFORE the in-project fast-path. A read-only phase must block
# write commands even when they only touch in-project paths, otherwise
# `touch ./foo` or `mv ./a ./b` slip through the git-reviewable
# allowlist and silently mutate files during a phase that promised no
# writes. Codex caught this on the PR 1 review by testing `touch ./x`
# from a git worktree while concurrency was set to read.
#
# Skill resolution goes through bin/lib/phases.sh so custom phases are
# protected the same way built-in ones are. The previous lookup did a
# raw $NANOSTACK_ROOT/$CURRENT_PHASE/SKILL.md, which silently no-oped
# for any phase whose SKILL.md lived outside the repo (every custom
# skill under $NANOSTACK_STORE/skills, ~/.claude/skills, etc.).
if [ -n "${NANOSTACK_STORE:-}" ]; then
  # Resolve the active phase's concurrency through the shared registry
  # helper (bin/lib/phases.sh). The SAME helper backs the Write/Edit
  # guard (guard/bin/check-write.sh) so the two hooks cannot drift on
  # what "read-only phase" means. The helper fails open (non-zero, no
  # output) for stale sessions, the conductor's "build" stage, removed
  # skills, and malformed custom skill metadata — so the guard never
  # blocks because of a bad session pointer.
  PHASES_LIB="$NANOSTACK_ROOT/bin/lib/phases.sh"
  if [ -f "$PHASES_LIB" ]; then
    # shellcheck disable=SC1090
    source "$PHASES_LIB" 2>/dev/null || true
    if command -v nano_active_phase_concurrency >/dev/null 2>&1; then
      ACTIVE_REC=$(nano_active_phase_concurrency 2>/dev/null) || ACTIVE_REC=""
      if [ -n "$ACTIVE_REC" ]; then
        CURRENT_PHASE=$(printf '%s' "$ACTIVE_REC" | cut -f1)
        SKILL_CONC=$(printf '%s' "$ACTIVE_REC" | cut -f2)
      else
        CURRENT_PHASE=""
        SKILL_CONC=""
      fi

      # Block writes during read-only phases
      if [ "$SKILL_CONC" = "read" ]; then
        case "$CMD" in
          *rm\ *|*mv\ *|*cp\ *|*mkdir\ *|*touch\ *|*chmod\ *|*git\ add*|*git\ commit*|*git\ push*|*git\ reset*)
            echo "BLOCKED [PHASE] Write operation during read-only phase '$CURRENT_PHASE'"
            echo "Category: concurrency-safety"
            echo "Command: $CMD"
            echo ""
            echo "Action: report this as a finding instead of auto-fixing. The current phase is read-only to prevent race conditions when multiple agents run in parallel."
            echo "Bypass: complete the current phase first (\`bin/session.sh phase-complete $CURRENT_PHASE\`), or end the session if you're not in a sprint."
            audit_trail_append blocked "PHASE-RO"
            exit 1
            ;;
        esac
      fi
    fi
  fi
fi

# ─── Tier 2.5: In-project operations ────────────────────────
# If the command only touches files inside the current git repo,
# it's reviewable via version control. Let it through. Phase
# concurrency above already prevented in-project writes during a
# read phase, so this fast-path only fires when writes are allowed.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

if [ -n "$PROJECT_ROOT" ]; then
  # Commands that write files but stay in-project are Tier 2.5
  # We only check simple file-targeting commands, not pipes or chains
  case "$CMD" in
    # Skip tier 2.5 for chained/piped commands (too hard to analyze)
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

# ─── Tier 2.8: Budget gate ────────────────────────────────────
# If a sprint budget is set and exceeded, block ALL commands.
if [ -z "${NANOSTACK_SKIP_BUDGET:-}" ]; then
  BUDGET_GATE="$(dirname "$0")/budget-gate.sh"
  if [ -x "$BUDGET_GATE" ]; then
    BGATE_OUTPUT=$("$BUDGET_GATE" 2>&1) || {
      echo "$BGATE_OUTPUT"
      exit 1
    }
  fi
fi

# ─── Tier 3: Warn patterns ──────────────────────────────────
# Block patterns already ran at Tier 1.5 before the in-project
# fast-path; only warn patterns need checking here.

WARN_PATTERNS=$(jq -r '.tiers.warn.rules[] | .pattern' "$RULES_FILE" 2>/dev/null)

# Fast pre-check for warn rules
WARN_COMBINED=$(echo "$WARN_PATTERNS" | paste -sd'|' -)
if [ -n "$WARN_COMBINED" ] && echo "$CMD" | grep -qiE -- "$WARN_COMBINED" 2>/dev/null; then
  WARN_IDX=0
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if echo "$CMD" | grep -qiE -- "$PATTERN" 2>/dev/null; then
      RULE=$(jq -c ".tiers.warn.rules[$WARN_IDX]" "$RULES_FILE")
      ID=$(echo "$RULE" | jq -r '.id')
      DESC=$(echo "$RULE" | jq -r '.description')
      CATEGORY=$(echo "$RULE" | jq -r '.category')

      echo "WARNING [$ID] $DESC"
      echo "Category: $CATEGORY"
      echo "Command: $CMD"
      echo ""
      echo "Proceeding. Consider the impact."
      exit 0
    fi
    WARN_IDX=$((WARN_IDX + 1))
  done <<< "$WARN_PATTERNS"
fi

# ─── Audit trail ────────────────────────────────────────────
# Append every evaluated command to .nanostack/audit.log (non-blocking).
# Store path and helper already resolved at the top of this script so
# the log line is consistent with the blocked-path helper above.
audit_trail_append allowed ""

# No rules matched. Allow.
exit 0
