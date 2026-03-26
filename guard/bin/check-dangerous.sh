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
          REAL_PATH=$(cd "$(dirname "$token" 2>/dev/null)" 2>/dev/null && pwd)/$(basename "$token") 2>/dev/null || REAL_PATH="$token"
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

# No rules matched. Allow.
exit 0
