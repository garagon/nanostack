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
[ -f "$SCRIPT_DIR/lib/phases.sh" ] && . "$SCRIPT_DIR/lib/phases.sh"

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

# PR 4 of the 2026-05-10 architecture audit: when the session has a
# non-default phase_graph (custom workflow stack OR a project that
# customized dependencies between built-in phases), read next_phase
# and ready_phases that session.sh already computed graph-aware. The
# review/security/qa shape only describes the built-in sprint, so a
# graph like build -> license-audit -> ... or a serialized review ->
# qa -> security override would otherwise fall back to the legacy
# peer logic and miss the configured dependencies.
DEFAULT_GRAPH_JSON='[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"review","depends_on":["build"]},{"name":"qa","depends_on":["build"]},{"name":"security","depends_on":["build"]},{"name":"ship","depends_on":["review","qa","security"]}]'
GRAPH_AWARE_NEXT=""
GRAPH_AWARE_READY="[]"
IS_CUSTOM_GRAPH=0
if [ -f "$SESSION_FILE" ]; then
  # Compare the full graph (sorted, normalized) rather than just the
  # set of node names. A project can keep the default names but rewire
  # the dependencies; Codex caught the name-only false-negative on the
  # PR 4 first review pass.
  session_graph=$(jq -c '
    (.phase_graph // [])
    | map({name: .name, depends_on: (.depends_on // [] | sort)})
    | sort_by(.name)
  ' "$SESSION_FILE" 2>/dev/null || echo "[]")
  default_normalized=$(echo "$DEFAULT_GRAPH_JSON" | jq -c '
    map({name: .name, depends_on: (.depends_on // [] | sort)})
    | sort_by(.name)
  ')
  if [ -n "$session_graph" ] && [ "$session_graph" != "[]" ] && [ "$session_graph" != "$default_normalized" ]; then
    IS_CUSTOM_GRAPH=1
    GRAPH_AWARE_NEXT=$(jq -r '.next_phase // ""' "$SESSION_FILE" 2>/dev/null || echo "")
    GRAPH_AWARE_READY=$(jq -c '.ready_phases // []' "$SESSION_FILE" 2>/dev/null || echo "[]")
  fi
fi

if [ "$IS_CUSTOM_GRAPH" = "1" ]; then
  PENDING_JSON="$GRAPH_AWARE_READY"
  NEXT_PHASE="$GRAPH_AWARE_NEXT"
  PENDING_COUNT=$(echo "$PENDING_JSON" | jq 'length')
  if [ -z "$NEXT_PHASE" ] || [ "$NEXT_PHASE" = "null" ]; then
    # No phase is ready right now. This can mean two things:
    #   - The sprint is finished (everything past ship completed).
    #   - The sprint has not started yet and the initial ready set
    #     was not snapshotted (legacy session pre-PR-4).
    # In both cases the safe answer is "no specific next phase" with
    # can_ship gated on the required_before_ship chain still being
    # incomplete. We do not collapse to "ship" because that wrongly
    # suggested a fresh custom session was ship-ready (Codex caught
    # this on the PR 4 first review pass).
    NEXT_PHASE=""
    if [ "$PENDING_COUNT" -eq 0 ]; then
      # Check whether ship has actually completed in this session.
      ship_done=$(jq -r '[.phase_log[]? | select(.phase == "ship" and .status == "completed")] | length' "$SESSION_FILE" 2>/dev/null || echo "0")
      if [ "$ship_done" -gt 0 ]; then
        NEXT_PHASE="compound"
        CAN_SHIP="true"
      else
        CAN_SHIP="false"
      fi
    else
      CAN_SHIP="false"
    fi
  elif [ "$NEXT_PHASE" = "ship" ] || [ "$NEXT_PHASE" = "compound" ]; then
    CAN_SHIP="true"
  else
    CAN_SHIP="false"
  fi
else
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
fi

# user_message wording rules:
#  - guided: one plain action, no slash commands, no phase jargon.
#  - professional: name the phase explicitly (callers print evidence).
# Custom phases (anything outside the built-in sprint) fall back to
# generic wording that uses the phase name without exposing "graph"
# or "DAG" jargon to a Guided user.
if [ -z "$NEXT_PHASE" ]; then
  case "$PROFILE" in
    guided)        MSG="Nothing is queued to run right now." ;;
    professional)  MSG="No phase is ready. Start the next sprint or finish the in-progress phase." ;;
    *)             MSG="" ;;
  esac
else
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
    guided:*)              MSG="I will run the $NEXT_PHASE step next." ;;
    professional:*)        MSG="Run /$NEXT_PHASE next." ;;
    *)                     MSG="" ;;
  esac
fi

# required_before_ship reflects the active graph: for the default
# sprint that is ["review","security","qa"]; for a custom graph it is
# every phase that ship transitively depends on (excluding think/plan/
# build, which are pre-build phases). Consumers that gated on the
# hardcoded shape continue to receive it when the session uses the
# default graph.
REQUIRED_BEFORE_SHIP_JSON='["review","security","qa"]'
if [ "$IS_CUSTOM_GRAPH" = "1" ] && [ -f "$SESSION_FILE" ]; then
  REQUIRED_BEFORE_SHIP_JSON=$(jq -c '
    (.phase_graph // []) as $g
    | def ancestors($name):
        ($g | map(select(.name == $name)) | first // {depends_on:[]}).depends_on as $deps
        | $deps + ($deps | map(ancestors(.)) | add // []);
      ancestors("ship") | unique | map(select(. != "think" and . != "plan" and . != "build"))
  ' "$SESSION_FILE" 2>/dev/null || echo '["review","security","qa"]')
fi

jq -n \
  --arg profile "$PROFILE" \
  --arg next "$NEXT_PHASE" \
  --argjson pending "$PENDING_JSON" \
  --argjson required "$REQUIRED_BEFORE_SHIP_JSON" \
  --arg can_ship "$CAN_SHIP" \
  --arg msg "$MSG" \
  '{
    profile: $profile,
    next_phase: (if $next == "" then null else $next end),
    pending_phases: $pending,
    ready_phases: $pending,
    required_before_ship: $required,
    user_message: $msg,
    can_ship: ($can_ship == "true")
  }'
