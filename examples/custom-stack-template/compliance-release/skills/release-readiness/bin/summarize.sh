#!/usr/bin/env bash
# summarize.sh — release-readiness skill helper.
#
# Composes upstream evidence from review, qa, security, license-audit,
# and privacy-check into a single rolled-up status. Reads the latest
# artifact for each upstream phase via bin/find-artifact.sh and maps
# each artifact's summary to a per-check status.
#
# Per-upstream status:
#   - artifact missing                              -> MISSING
#   - artifact present but integrity hash mismatch  -> TAMPERED
#   - artifact present but .integrity field absent  -> TAMPERED
#     (a release gate rejects unverifiable evidence; an attacker who
#     can write the file can remove the integrity field as easily as
#     mutate it, so missing integrity is the same risk class as a
#     bad hash)
#   - artifact present + verified, status=OK        -> OK
#   - artifact present + verified, status=WARN      -> WARN
#   - artifact present + verified, status=BLOCKED   -> BLOCKED
#   - artifact present + verified, status absent or
#     unrecognized                                  -> WARN
#
# Each lookup goes through find-artifact.sh --verify so a tampered
# artifact (mtime untouched, content rewritten) cannot quietly roll
# the gate up to OK. The tampered case is recorded as TAMPERED in
# the per-check entry and forces the rollup to BLOCKED, separately
# from "artifact never saved" which records as MISSING.
#
# save-artifact.sh always writes the .integrity field, so a
# legitimate artifact never trips the missing-integrity check.
#
# Rollup (monotonic, worst case wins):
#   - any check is BLOCKED, TAMPERED, or MISSING -> BLOCKED
#   - else any check is WARN                     -> WARN
#   - else                                       -> OK
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

CHECKS_JSON='[]'
ROLLUP="OK"
HAS_FAILURE=false  # any of BLOCKED, TAMPERED, MISSING
HAS_WARN=false

for phase in $UPSTREAMS; do
  # First: does an artifact exist at all (any artifact, regardless of
  # integrity)? Used to distinguish "never saved" from "saved but
  # tampered with".
  raw=$( "$FIND_ARTIFACT" "$phase" 30 2>/dev/null || true )
  if [ -z "$raw" ] || [ ! -f "$raw" ]; then
    status="MISSING"
    evidence=""
  else
    # Then: does it pass integrity verification? --verify exits 1 and
    # prints "INTEGRITY FAILED" to stderr when the stored hash does
    # not match the recomputed hash. A release gate must surface that
    # explicitly, not treat a tampered file as clean evidence.
    verified=$( "$FIND_ARTIFACT" "$phase" 30 --verify 2>/dev/null || true )
    if [ -z "$verified" ] || [ ! -f "$verified" ]; then
      status="TAMPERED"
      evidence="integrity_failure"
    else
      # find-artifact.sh --verify silently accepts artifacts whose
      # .integrity field is missing — it only fails on a hash
      # MISMATCH, not on absence. A release gate cannot afford that:
      # an attacker who can write the file can delete the field as
      # easily as mutate the hash. Require .integrity to be present.
      stored_integrity=$( jq -r '.integrity // ""' "$verified" 2>/dev/null )
      if [ -z "$stored_integrity" ]; then
        status="TAMPERED"
        evidence="missing_integrity"
      else
        raw_status=$( jq -r '.summary.status // ""' "$verified" 2>/dev/null )
        case "$raw_status" in
          OK|WARN|BLOCKED) status="$raw_status" ;;
          "") status="WARN" ;;
          *)  status="WARN" ;;
        esac
        evidence="artifact"
      fi
    fi
  fi

  case "$status" in
    BLOCKED|TAMPERED|MISSING) HAS_FAILURE=true ;;
    WARN)                     HAS_WARN=true ;;
  esac

  CHECKS_JSON=$( echo "$CHECKS_JSON" | jq \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg evidence "$evidence" \
    '. + [{phase: $phase, status: $status, evidence: ($evidence | select(. != "") // null)}]' )
done

# Monotonic worst-case rollup. BLOCKED dominates everything.
if [ "$HAS_FAILURE" = "true" ]; then
  ROLLUP="BLOCKED"
elif [ "$HAS_WARN" = "true" ]; then
  ROLLUP="WARN"
fi

jq -n \
  --argjson checks "$CHECKS_JSON" \
  --arg rollup_status "$ROLLUP" \
  '{
    checks: $checks,
    rollup_status: $rollup_status
  }'
