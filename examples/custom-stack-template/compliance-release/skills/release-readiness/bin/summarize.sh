#!/usr/bin/env bash
# summarize.sh — release-readiness skill helper.
#
# Composes upstream evidence from review, qa, security, license-audit,
# and privacy-check into a single rolled-up status. Reads the latest
# artifact for each upstream phase via bin/find-artifact.sh and maps
# each artifact's summary to a per-check status.
#
# Per-upstream status:
#   - artifact missing            -> MISSING
#   - artifact present, status=OK -> OK
#   - artifact present, status=WARN -> WARN
#   - artifact present, status=BLOCKED -> BLOCKED
#   - artifact present, status absent or unrecognized -> WARN
#     (the upstream did not declare a status; treat as soft warning)
#
# Rollup (monotonic, worst case wins):
#   - any check is BLOCKED                          -> BLOCKED
#   - else any check is MISSING (required upstream)  -> BLOCKED
#   - else any check is WARN                         -> WARN
#   - else                                           -> OK
#
# Output: JSON object with `checks` array and `rollup_status`. The
# calling skill saves the artifact and surfaces a headline + next
# action based on the rollup.
#
# Read-only. Does not run /ship, open PRs, commit, or deploy.
set -eu

# Resolve nanostack root via env-var fallback so the snippet copy-pastes
# from the SKILL.md instructions. find-artifact.sh lives under bin/.
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
FIND_ARTIFACT="$NANOSTACK_ROOT/bin/find-artifact.sh"

if [ ! -x "$FIND_ARTIFACT" ]; then
  echo "ERROR: $FIND_ARTIFACT not found or not executable" >&2
  echo "       Set NANOSTACK_ROOT to your Nanostack checkout." >&2
  exit 2
fi

UPSTREAMS="review qa security license-audit privacy-check"

# Status precedence used by the rollup: lower index = worse.
status_rank() {
  case "$1" in
    BLOCKED) printf '0' ;;
    MISSING) printf '1' ;;
    WARN)    printf '2' ;;
    OK)      printf '3' ;;
    *)       printf '2' ;; # unknown maps to WARN-ish
  esac
}

CHECKS_JSON='[]'
ROLLUP="OK"
ROLLUP_RANK=3
HAS_BLOCKER=false
HAS_MISSING=false

for phase in $UPSTREAMS; do
  artifact=$( "$FIND_ARTIFACT" "$phase" 30 2>/dev/null || true )
  if [ -z "$artifact" ] || [ ! -f "$artifact" ]; then
    status="MISSING"
    evidence=""
    HAS_MISSING=true
  else
    raw_status=$( jq -r '.summary.status // ""' "$artifact" 2>/dev/null )
    case "$raw_status" in
      OK|WARN|BLOCKED) status="$raw_status" ;;
      "") status="WARN" ;;  # artifact present but no declared status
      *)  status="WARN" ;;  # unrecognized status string
    esac
    evidence="artifact"
    [ "$status" = "BLOCKED" ] && HAS_BLOCKER=true
  fi

  CHECKS_JSON=$( echo "$CHECKS_JSON" | jq \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg evidence "$evidence" \
    '. + [{phase: $phase, status: $status, evidence: ($evidence | select(. != "") // null)}]' )

  rank=$(status_rank "$status")
  if [ "$rank" -lt "$ROLLUP_RANK" ]; then
    ROLLUP_RANK=$rank
    case "$rank" in
      0) ROLLUP="BLOCKED" ;;
      1) ROLLUP="BLOCKED" ;; # MISSING required upstream blocks the gate
      2) ROLLUP="WARN" ;;
      3) ROLLUP="OK" ;;
    esac
  fi
done

# Always-blocked override: if anything was BLOCKED or MISSING, the
# rollup must reflect that even if a later check OK'd the rank.
if [ "$HAS_BLOCKER" = "true" ] || [ "$HAS_MISSING" = "true" ]; then
  ROLLUP="BLOCKED"
fi

jq -n \
  --argjson checks "$CHECKS_JSON" \
  --arg rollup_status "$ROLLUP" \
  '{
    checks: $checks,
    rollup_status: $rollup_status
  }'
