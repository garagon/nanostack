#!/usr/bin/env bash
# detect-legacy-setup.sh — Read-only probe for legacy host config.
#
# /nano-run runs this before any setup mutation. It tells the skill:
#
#   - whether a previous nanostack install left state behind,
#   - which PreToolUse hooks are missing,
#   - whether broad permissions (Bash(rm:*), Write(*), Edit(*)) are
#     present,
#   - whether bin/init-project.sh --repair would help,
#   - whether narrowing those broad permissions requires explicit
#     user confirmation (--migrate-permissions is destructive and
#     /nano-run must NEVER run it silently).
#
# Output is JSON suitable for embedding into the setup artifact's
# summary.legacy field. Read-only; never mutates.
#
# Usage:
#   detect-legacy-setup.sh                  Probe current project
#   detect-legacy-setup.sh /path/to/project Probe a specific path
#
# Exit codes:
#   0  detection ran (whether or not legacy state was found)
#   2  invalid path argument
set -e

PROJECT="${1:-$(pwd)}"
if [ ! -d "$PROJECT" ]; then
  echo "ERROR: not a directory: $PROJECT" >&2
  exit 2
fi

SETTINGS="$PROJECT/.claude/settings.json"

# Defaults assume "no legacy state at all".
DETECTED=false
SETTINGS_PRESENT=false
MISSING_HOOKS_JSON='[]'
BROAD_PERMS_JSON='[]'
REPAIR_AVAILABLE=false
MIGRATION_REQUIRES_CONFIRMATION=false

if [ -f "$SETTINGS" ]; then
  SETTINGS_PRESENT=true

  # The hooks block lives at .hooks.PreToolUse, an array. Each entry
  # carries a `matcher` regex naming the tools it gates plus a
  # `hooks` array. The two matchers nanostack expects today:
  BASH_HOOK_PRESENT=$(jq -r '
    (.hooks.PreToolUse // []) as $h
    | any($h[]; .matcher == "Bash" and (.hooks // [])[0].command and ((.hooks[0].command // "") | test("check-dangerous"))) | tostring
  ' "$SETTINGS" 2>/dev/null || echo "false")

  WRITE_HOOK_PRESENT=$(jq -r '
    (.hooks.PreToolUse // []) as $h
    | any($h[]; .matcher == "Write|Edit|MultiEdit" and (.hooks // [])[0].command and ((.hooks[0].command // "") | test("check-write"))) | tostring
  ' "$SETTINGS" 2>/dev/null || echo "false")

  MISSING=()
  [ "$BASH_HOOK_PRESENT"  != "true" ] && MISSING+=("Bash:check-dangerous")
  [ "$WRITE_HOOK_PRESENT" != "true" ] && MISSING+=("Write|Edit|MultiEdit:check-write")
  if [ ${#MISSING[@]} -gt 0 ]; then
    MISSING_HOOKS_JSON=$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -s .)
  fi

  # Broad permissions that --repair leaves alone but
  # --migrate-permissions narrows. Their presence is the signal that
  # confirmation is required before any narrowing.
  BROAD=()
  if jq -e '.permissions.allow // [] | any(. == "Bash(rm:*)")' "$SETTINGS" >/dev/null 2>&1; then
    BROAD+=("Bash(rm:*)")
  fi
  if jq -e '.permissions.allow // [] | any(. == "Write(*)")' "$SETTINGS" >/dev/null 2>&1; then
    BROAD+=("Write(*)")
  fi
  if jq -e '.permissions.allow // [] | any(. == "Edit(*)")' "$SETTINGS" >/dev/null 2>&1; then
    BROAD+=("Edit(*)")
  fi
  if [ ${#BROAD[@]} -gt 0 ]; then
    BROAD_PERMS_JSON=$(printf '%s\n' "${BROAD[@]}" | jq -R . | jq -s .)
  fi

  # Detected = settings exist AND something is off about them.
  if [ ${#MISSING[@]} -gt 0 ] || [ ${#BROAD[@]} -gt 0 ]; then
    DETECTED=true
  fi

  # Repair (additive) helps when hooks are missing.
  [ ${#MISSING[@]} -gt 0 ] && REPAIR_AVAILABLE=true

  # Migration (destructive) is required to narrow broad permissions.
  # The flag stays a boolean, not a verb: it does NOT mean "go run
  # the migration". It means "you cannot reach a clean state without
  # explicit user confirmation".
  [ ${#BROAD[@]} -gt 0 ] && MIGRATION_REQUIRES_CONFIRMATION=true
fi

jq -n \
  --argjson detected "$DETECTED" \
  --argjson settings_present "$SETTINGS_PRESENT" \
  --argjson missing_hooks "$MISSING_HOOKS_JSON" \
  --argjson broad_permissions "$BROAD_PERMS_JSON" \
  --argjson repair_available "$REPAIR_AVAILABLE" \
  --argjson migration_requires_confirmation "$MIGRATION_REQUIRES_CONFIRMATION" \
  --arg settings_path "$SETTINGS" \
  '{
    detected:                          $detected,
    settings_present:                  $settings_present,
    settings_path:                     $settings_path,
    missing_hooks:                     $missing_hooks,
    broad_permissions:                 $broad_permissions,
    repair_available:                  $repair_available,
    migration_requires_confirmation:   $migration_requires_confirmation
  }'
