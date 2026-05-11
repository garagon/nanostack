#!/usr/bin/env bash
# artifact-schemas.sh — Phase-specific validators for nanostack artifacts.
#
# Single source of truth for "is this artifact shape valid for this
# phase?" save-artifact.sh calls nano_validate_artifact <phase> <json>
# in normal (structured) mode and refuses to write when the artifact
# is missing required fields. The 2026-05-10 architecture audit
# (PR 3) moves this enforcement out of advisory SKILL.md guidance and
# into the save path itself so downstream skills (resolve.sh,
# restore-context.sh, sprint-journal.sh, release-readiness) can rely
# on named fields being present.
#
# Public function:
#   nano_validate_artifact <phase> <json>
#     Returns 0 if the artifact JSON conforms to the phase contract.
#     Returns 1 with a stderr message listing missing or wrong-shape
#     fields. The function is read-only: it never modifies the JSON.
#
# Required fields per phase:
#   think     — handled by /think SKILL.md autopilot brief gate; here
#               we only require .summary to be an object so the
#               structured contract is consistent with the four other
#               core phases.
#   plan      — summary.planned_files (array), summary.plan_approval,
#               context_checkpoint.
#   review    — summary (object), scope_drift, findings (array),
#               context_checkpoint.
#   qa        — summary (object), findings (array), context_checkpoint.
#   security  — summary (object), findings (array), context_checkpoint.
#   ship      — summary (object), context_checkpoint. When run_mode is
#               report_only, summary may be a string and findings is
#               not required (the artifact is a report, not a release
#               record). Other ship artifacts must look like a real
#               PR record (summary.status or summary.pr_number).
#   custom    — phase + summary only (already enforced by save-artifact).
#
# Every core phase requires context_checkpoint so restore-context.sh
# can rebuild state across long sprints. The field's own shape is
# documented in reference/artifact-schema.md.

if [ "${_NANO_ARTIFACT_SCHEMAS_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NANO_ARTIFACT_SCHEMAS_LOADED=1

# Helper: report a missing field. Accumulates into the caller's
# MISSING variable. Stays internal so callers stay small.
_nano_validate_emit() {
  if [ -z "$_MISSING_FIELDS" ]; then
    _MISSING_FIELDS="$1"
  else
    _MISSING_FIELDS="$_MISSING_FIELDS, $1"
  fi
}

# Helper: check that a jq path resolves to a non-null value of the
# expected type. type may be "any" (just non-null), "string",
# "object", "array", "number", "boolean".
_nano_validate_field() {
  local json="$1" path="$2" expected="$3"
  local actual
  actual=$(printf '%s' "$json" | jq -r "$path | type" 2>/dev/null || echo "missing")
  case "$actual" in
    null|missing)
      _nano_validate_emit "$path"
      return 1
      ;;
  esac
  if [ "$expected" != "any" ] && [ "$actual" != "$expected" ]; then
    _nano_validate_emit "$path (expected $expected, got $actual)"
    return 1
  fi
  return 0
}

nano_validate_artifact() {
  local phase="${1:?nano_validate_artifact requires <phase> <json>}"
  local json="${2:?nano_validate_artifact requires <phase> <json>}"
  _MISSING_FIELDS=""

  # JSON must parse. save-artifact already checks this, but the
  # validator is callable on its own (lint, ad-hoc verification).
  if ! printf '%s' "$json" | jq -e '.' >/dev/null 2>&1; then
    echo "nano_validate_artifact: invalid JSON input" >&2
    return 1
  fi

  case "$phase" in
    think)
      # /think autopilot brief gate already enforces the rich field
      # set (value_proposition, scope_mode, ...). Here we only check
      # that summary is an object so the structured contract is
      # consistent across core phases.
      _nano_validate_field "$json" '.summary' 'object'
      ;;
    plan)
      _nano_validate_field "$json" '.summary' 'object'
      _nano_validate_field "$json" '.summary.planned_files' 'array'
      _nano_validate_field "$json" '.summary.plan_approval' 'any'
      _nano_validate_field "$json" '.context_checkpoint' 'object'
      ;;
    review)
      _nano_validate_field "$json" '.summary' 'object'
      # scope_drift must be an object with a .status field: the
      # downstream consumer bin/sprint-journal.sh reads
      # .scope_drift.status. An empty object satisfies "is an object"
      # but still drops the drift signal silently, so .status is
      # required too. Codex caught the contract mismatch on the PR 3
      # fourth and fifth review passes.
      _nano_validate_field "$json" '.scope_drift' 'object'
      _nano_validate_field "$json" '.scope_drift.status' 'string'
      _nano_validate_field "$json" '.findings' 'array'
      _nano_validate_field "$json" '.context_checkpoint' 'object'
      ;;
    qa)
      _nano_validate_field "$json" '.summary' 'object'
      _nano_validate_field "$json" '.findings' 'array'
      _nano_validate_field "$json" '.context_checkpoint' 'object'
      ;;
    security)
      _nano_validate_field "$json" '.summary' 'object'
      _nano_validate_field "$json" '.findings' 'array'
      _nano_validate_field "$json" '.context_checkpoint' 'object'
      ;;
    ship)
      # report_only ship artifacts are reports, not release records.
      # They keep the looser shape (summary may be a string, no
      # findings expected). Normal-mode ship artifacts must include a
      # structured summary and a context_checkpoint so /compound and
      # post-deploy verification can read PR / status fields by name.
      local run_mode
      run_mode=$(printf '%s' "$json" | jq -r '.run_mode // .summary.run_mode // ""' 2>/dev/null)
      if [ "$run_mode" = "report_only" ]; then
        _nano_validate_field "$json" '.summary' 'any'
      else
        _nano_validate_field "$json" '.summary' 'object'
        _nano_validate_field "$json" '.context_checkpoint' 'object'
      fi
      ;;
    *)
      # Custom phases and unrecognized core phases: only the base
      # contract (phase + summary) is enforced. The base check lives
      # in save-artifact.sh and runs before us.
      return 0
      ;;
  esac

  if [ -n "$_MISSING_FIELDS" ]; then
    echo "nano_validate_artifact: $phase artifact is missing required fields: $_MISSING_FIELDS" >&2
    echo "                        see reference/artifact-schema.md for the canonical shape." >&2
    return 1
  fi
  return 0
}
