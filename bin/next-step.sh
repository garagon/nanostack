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
# When a session exists, trust the session-computed ready_phases /
# next_phase. session.sh already runs nano_phase_ready_from_graph on
# every phase-start and phase-complete with the correct completed +
# in_progress lists, so we get parallel-graph correctness AND
# in-progress exclusion for free. The legacy artifact-based fallback
# only kicks in when no session file exists.
#
# Codex flagged the in-progress leak on the PR 4 fourth review pass:
# the previous default-sprint branch only consulted phase_completed,
# so an active /review showed up in ready_phases and could trigger
# duplicate starts.
SESSION_READY="[]"
SESSION_NEXT=""
HAS_GRAPH_AWARE_SESSION=0
HAS_SESSION=0
if [ -f "$SESSION_FILE" ]; then
  HAS_SESSION=1
  # A session that was written by a pre-PR-4 build has neither
  # phase_graph nor ready_phases. Detect that and route through the
  # legacy artifact-based lookup so an in-progress sprint upgraded
  # mid-flight still gets sensible next-step output. Codex flagged
  # the upgrade regression on the PR 4 fifth review pass.
  if jq -e '(.phase_graph // []) | length > 0' "$SESSION_FILE" >/dev/null 2>&1; then
    HAS_GRAPH_AWARE_SESSION=1
    SESSION_READY=$(jq -c '.ready_phases // []' "$SESSION_FILE" 2>/dev/null || echo "[]")
    SESSION_NEXT=$(jq -r '.next_phase // ""' "$SESSION_FILE" 2>/dev/null || echo "")
  fi
fi

# can_ship derives from the graph contract, not from NEXT_PHASE.
# It means "every phase in required_before_ship has completed" so a
# graph where ship is parallel-ready alongside another phase still
# reports can_ship=true. Codex flagged the dependency-vs-display
# mix-up on the PR 4 fifth review pass.
compute_can_ship_from_session() {
  # can_ship means "ship is actually ready to run or has already
  # completed". The previous form computed it from "required set
  # minus completed", but for a graph where ship depends only on
  # think/plan/build (no post-build gates), the required set was
  # empty after filtering and can_ship was true even before any
  # phase ran. Codex caught this on the PR 4 eighth review pass.
  # Reading from the session's ready_phases (which session.sh keeps
  # current via nano_phase_ready_from_graph) is the single source
  # of truth: ship is ready exactly when its declared deps are all
  # completed and ship itself is neither completed nor in_progress.
  jq -r '
    ((.ready_phases // []) | any(. == "ship")) as $ship_ready
    | ([.phase_log[]? | select(.phase == "ship" and .status == "completed")] | length > 0) as $ship_done
    | ($ship_ready or $ship_done)
  ' "$SESSION_FILE" 2>/dev/null || echo "false"
}

if [ "$HAS_GRAPH_AWARE_SESSION" = "1" ]; then
  PENDING_JSON="$SESSION_READY"
  NEXT_PHASE="$SESSION_NEXT"
  PENDING_COUNT=$(echo "$PENDING_JSON" | jq 'length')
  CAN_SHIP=$(compute_can_ship_from_session)
  if [ -z "$NEXT_PHASE" ] || [ "$NEXT_PHASE" = "null" ]; then
    NEXT_PHASE=""
    ship_done=$(jq -r '[.phase_log[]? | select(.phase == "ship" and .status == "completed")] | length' "$SESSION_FILE" 2>/dev/null || echo "0")
    if [ "$ship_done" -gt 0 ]; then
      NEXT_PHASE="compound"
    fi
  fi
else
  # No session file OR a legacy session without phase_graph. Fall
  # back to the artifact-based lookup so a host that drives
  # /review/security/qa without going through (or before) the
  # graph-aware session contract still gets sensible output.
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
if [ "$HAS_GRAPH_AWARE_SESSION" = "1" ]; then
  # The graph snapshot inside session.json is authoritative. For the
  # default sprint that yields ["review","security","qa"] (the legacy
  # order, preserved by walking the graph in declared order); for a
  # custom graph it returns the actual transitive chain ship depends
  # on. Falls back to the legacy default if the jq filter fails.
  #
  # The previous form used `unique`, which sorts in jq and produced
  # ["qa","review","security"]. Consumers that compared the array
  # exactly broke on that ordering. Codex caught the regression on
  # the PR 4 seventh review pass.
  REQUIRED_BEFORE_SHIP_JSON=$(jq -c '
    (.phase_graph // []) as $g
    | def ancestors($name):
        ($g | map(select(.name == $name)) | first // {depends_on:[]}).depends_on as $deps
        | $deps + ($deps | map(ancestors(.)) | add // []);
      (ancestors("ship")) as $ancs
      | [$g[].name
          | select(. as $n | $ancs | any(. == $n))
          | select(. != "think" and . != "plan" and . != "build")
        ]
  ' "$SESSION_FILE" 2>/dev/null)
  # Only fall back to the legacy default when the jq filter failed
  # outright (empty stdout). A legitimate empty array means the graph
  # really has no post-build gates ahead of ship, which is unusual
  # but valid; we keep it as-is so consumers see the graph's truth.
  # The legacy default applies only when there is no session-level
  # graph to read from.
  if [ -z "$REQUIRED_BEFORE_SHIP_JSON" ]; then
    REQUIRED_BEFORE_SHIP_JSON='["review","security","qa"]'
  fi
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
