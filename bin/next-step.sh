#!/usr/bin/env bash
# next-step.sh — Determine which sprint phases still need to run.
#
# Usage:
#   next-step.sh <current-phase>             Legacy: space-separated pending peers
#   next-step.sh --json [current-phase]      Structured next-action object
#
# Legacy text mode (kept for review/security/qa SKILL.md callers): emits
# the post-build peers (review, security, qa) that are still pending,
# excluding <current-phase>, plus "ship" when anything else is pending.
#
# JSON mode: derives state from session.json first, falls back to fresh
# artifacts when session is absent. profile shapes user_message wording
# only — phase requirements are identical for guided and professional.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

JSON=0
CURRENT=""
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    *)      [ -z "$CURRENT" ] && CURRENT="$arg" ;;
  esac
done

FIND="$SCRIPT_DIR/find-artifact.sh"
PEERS="review security qa"

# ─── helpers ────────────────────────────────────────────────

# Pending = no completed phase entry in session.json AND no fresh
# artifact within 1 day. Session is authoritative when present; the
# artifact fallback is only consulted when session is missing or
# does not yet record the phase.
phase_completed() {
  local phase="$1"
  if [ -f "$NANOSTACK_STORE/session.json" ]; then
    local hits
    hits=$(jq -r --arg p "$phase" \
      '[.phase_log[]? | select(.phase == $p and .status == "completed")] | length' \
      "$NANOSTACK_STORE/session.json" 2>/dev/null || echo "0")
    if [ "$hits" -gt 0 ]; then return 0; fi
  fi
  "$FIND" "$phase" 1 >/dev/null 2>&1
}

# ─── legacy text mode (default, no --json) ──────────────────
if [ "$JSON" -eq 0 ]; then
  if [ -z "$CURRENT" ]; then
    echo "Usage: next-step.sh <current-phase>" >&2
    exit 1
  fi
  PENDING=""
  for phase in $PEERS; do
    [ "$phase" = "$CURRENT" ] && continue
    if ! phase_completed "$phase"; then
      PENDING="${PENDING:+$PENDING }$phase"
    fi
  done
  if [ -n "$PENDING" ]; then
    PENDING="$PENDING ship"
  elif ! phase_completed "ship"; then
    PENDING="ship"
  fi
  echo "$PENDING"
  exit 0
fi

# ─── JSON mode ──────────────────────────────────────────────
# Profile and phase_log come from session.json when present. Without
# a session we still answer truthfully using the artifact fallback,
# but we cannot know the user's profile so default to professional
# (less paternalistic when wording is unknown).

PROFILE="professional"
SESSION_FILE="$NANOSTACK_STORE/session.json"
if [ -f "$SESSION_FILE" ]; then
  PROFILE=$(jq -r '.profile // (if (.capabilities // null) == null then "guided" else "professional" end)' "$SESSION_FILE" 2>/dev/null || echo "professional")
fi

PENDING_JSON="[]"
for phase in $PEERS; do
  if ! phase_completed "$phase"; then
    PENDING_JSON=$(echo "$PENDING_JSON" | jq --arg p "$phase" '. + [$p]')
  fi
done

NEXT_PHASE=$(echo "$PENDING_JSON" | jq -r '.[0] // "ship"')
PENDING_COUNT=$(echo "$PENDING_JSON" | jq 'length')
if [ "$PENDING_COUNT" -eq 0 ]; then
  if phase_completed "ship"; then
    NEXT_PHASE="compound"
    CAN_SHIP="true"
  else
    NEXT_PHASE="ship"
    CAN_SHIP="true"
  fi
else
  CAN_SHIP="false"
fi

# user_message wording rules:
#  - guided: one plain action, no slash commands, no phase jargon.
#  - professional: name the phase explicitly (callers print evidence).
case "$PROFILE:$NEXT_PHASE" in
  guided:review)   MSG="I will check that what was built actually works and has no obvious risks." ;;
  guided:security) MSG="I will check for risky patterns or leaked secrets." ;;
  guided:qa)       MSG="I will try the feature end to end and confirm it behaves." ;;
  guided:ship)     MSG="I will package the result so you can try it." ;;
  guided:compound) MSG="Done. I will record what I learned for next time." ;;
  professional:review)   MSG="Run /review to check scope, structure, and edge cases." ;;
  professional:security) MSG="Run /security to audit for vulnerabilities." ;;
  professional:qa)       MSG="Run /qa to verify the feature works." ;;
  professional:ship)     MSG="Run /ship to commit, push, and create the PR." ;;
  professional:compound) MSG="Sprint complete. Run /compound to record learnings." ;;
  *) MSG="" ;;
esac

jq -n \
  --arg profile "$PROFILE" \
  --arg next "$NEXT_PHASE" \
  --argjson pending "$PENDING_JSON" \
  --arg can_ship "$CAN_SHIP" \
  --arg msg "$MSG" \
  '{
    profile: $profile,
    next_phase: $next,
    pending_phases: $pending,
    required_before_ship: ["review","security","qa"],
    user_message: $msg,
    can_ship: ($can_ship == "true")
  }'
