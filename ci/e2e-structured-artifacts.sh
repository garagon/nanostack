#!/usr/bin/env bash
# e2e-structured-artifacts.sh — PR 3 of the 2026-05-10 architecture
# audit. Locks the structured artifact contract end-to-end:
#
#   - bin/lib/artifact-schemas.sh's per-phase validator accepts valid
#     shapes and rejects invalid ones.
#   - bin/save-artifact.sh refuses to write when the per-phase schema
#     fails, but still writes when it passes.
#   - --from-session continues to work for manual recovery, marks
#     artifacts with schema_legacy: true, and emits a deprecation
#     warning to stderr.
#   - bin/find-artifact.sh and bin/resolve.sh still load legacy
#     artifacts so existing stores are not broken.
#   - core SKILL.md guidance no longer documents --from-session.
#
# Migrated onto ci/lib/harness.sh (Harness Architecture vNext PR 1).
# Same cells, same check count. Supports --filter <pattern>.
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init structured-artifacts nanostack-structured
nh_require_cmd git jq

SAVE="$REPO/bin/save-artifact.sh"
FIND="$REPO/bin/find-artifact.sh"
RESOLVE="$REPO/bin/resolve.sh"

# Shared project + store. Every cell uses this base; fixtures are built
# once here so a --filter run of any single cell still has them.
PROJ="$NH_TMP/project"
STORE="$PROJ/.nanostack"
mkdir -p "$PROJ" "$STORE"
cd "$PROJ"
git init -q
git config user.email "e2e@test.local"
git config user.name  "e2e"
export NANOSTACK_STORE="$STORE"

# Canonical valid shapes.
plan_ok=$(jq -n '{phase:"plan",summary:{planned_files:["a.ts"],plan_approval:"manual"},context_checkpoint:{summary:"x"}}')
review_ok=$(jq -n '{phase:"review",summary:{blocking:0},scope_drift:{status:"clean"},findings:[],context_checkpoint:{summary:"x"}}')
qa_ok=$(jq -n '{phase:"qa",summary:{tests_run:5},findings:[],context_checkpoint:{summary:"x"}}')
sec_ok=$(jq -n '{phase:"security",summary:{total_findings:0},findings:[],context_checkpoint:{summary:"x"}}')
ship_ok=$(jq -n '{phase:"ship",summary:{pr_number:42,status:"merged"},context_checkpoint:{summary:"x"}}')
ship_ro=$(jq -n '{phase:"ship",summary:"would have shipped",run_mode:"report_only"}')
think_ok=$(jq -n '{phase:"think",summary:{value_proposition:"x"}}')

# Invalid shapes (missing required fields).
plan_bad=$(jq -n '{phase:"plan",summary:{plan_approval:"manual"},context_checkpoint:{summary:"x"}}')
review_bad=$(jq -n '{phase:"review",summary:{},context_checkpoint:{summary:"x"}}')
qa_bad=$(jq -n '{phase:"qa",summary:{tests_run:5}}')
sec_bad=$(jq -n '{phase:"security",summary:"a string"}')
ship_bad=$(jq -n '{phase:"ship",summary:"loose without report_only"}')
think_bad=$(jq -n '{phase:"think",summary:"plain string"}')

# Cell 1: per-phase validator accepts the canonical structured shapes.
cell_validator_accepts() {
  local kind json phase
  for kind in plan review qa sec ship ship_ro think; do
    case "$kind" in
      plan)    json="$plan_ok";   phase=plan ;;
      review)  json="$review_ok"; phase=review ;;
      qa)      json="$qa_ok";     phase=qa ;;
      sec)     json="$sec_ok";    phase=security ;;
      ship)    json="$ship_ok";   phase=ship ;;
      ship_ro) json="$ship_ro";   phase=ship ;;
      think)   json="$think_ok";  phase=think ;;
    esac
    nh_assert_true "validator accepts canonical $kind" \
      bash -c "source '$REPO/bin/lib/artifact-schemas.sh'; nano_validate_artifact '$phase' '$json'"
  done
}

# Cell 2: validator rejects invalid shapes.
cell_validator_rejects() {
  local kind json phase
  for kind in plan review qa sec ship think; do
    case "$kind" in
      plan)   json="$plan_bad";   phase=plan ;;
      review) json="$review_bad"; phase=review ;;
      qa)     json="$qa_bad";     phase=qa ;;
      sec)    json="$sec_bad";    phase=security ;;
      ship)   json="$ship_bad";   phase=ship ;;
      think)  json="$think_bad";  phase=think ;;
    esac
    nh_assert_false "validator rejects invalid $kind" \
      bash -c "source '$REPO/bin/lib/artifact-schemas.sh'; nano_validate_artifact '$phase' '$json'"
  done
}

# Cell 3: save-artifact.sh refuses to write invalid shapes.
cell_save_rejects_invalid() {
  local before after out rc
  before=$(find "$STORE" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  nh_capture out rc "$SAVE" plan "$plan_bad"
  after=$(find "$STORE" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  nh_assert_eq "exit code is 1"      "1"       "$rc"
  nh_assert_eq "no artifact written" "$before" "$after"
  nh_assert_contains "stderr mentions missing required fields" "$out" "missing required fields"
}

# Cell 4: save-artifact.sh writes valid structured artifacts with integrity.
cell_save_writes_valid() {
  local saved_plan saved_ship_ro
  saved_plan=$( "$SAVE" plan "$plan_ok" )
  nh_assert_true "plan artifact file exists" test -f "$saved_plan"
  nh_assert_jq_file "plan artifact has context_checkpoint"          "$saved_plan" '.context_checkpoint != null'
  nh_assert_jq_file "plan artifact has integrity field"             "$saved_plan" '.integrity != null'
  nh_assert_jq_file "plan artifact has summary.planned_files array" "$saved_plan" '(.summary.planned_files | type) == "array"'
  saved_ship_ro=$( "$SAVE" ship "$ship_ro" )
  nh_assert_true "ship report_only artifact file exists" test -f "$saved_ship_ro"
}

# Cell 5: --from-session still works, emits deprecation, marks legacy.
cell_from_session_legacy() {
  local out rc saved_legacy
  nh_capture out rc "$SAVE" --from-session qa 'N tests passed'
  saved_legacy=$(printf '%s\n' "$out" | tail -1)
  nh_assert_eq "legacy save exit code is 0" "0" "$rc"
  nh_assert_true "legacy artifact file exists" test -f "$saved_legacy"
  nh_assert_jq_file "legacy artifact has schema_legacy: true" "$saved_legacy" '.schema_legacy == true'
  nh_assert_contains "deprecation warning printed" "$out" "--from-session is a legacy mode"
}

# Cell 6: legacy artifacts remain readable by find-artifact + resolve.
cell_legacy_readable() {
  local found resolved status_qa
  # Self-contained under --filter: ensure a legacy qa artifact exists even
  # when from-session-legacy was filtered out. The full run also seeds one
  # there; re-seeding is harmless (find/resolve take the newest).
  "$SAVE" --from-session qa 'N tests passed' >/dev/null 2>&1 || true
  found=$( "$FIND" qa 30 2>/dev/null )
  nh_assert_true "find-artifact returns the legacy qa artifact" test -f "$found"
  resolved=$( "$RESOLVE" ship 2>/dev/null )
  status_qa=$( printf '%s' "$resolved" | jq -r '.upstream_status.qa // ""' )
  nh_assert_eq "resolve.sh upstream_status.qa is verified" "verified" "$status_qa"
}

# Cell 7: core SKILL.md no longer references --from-session normal save.
cell_skill_md_clean() {
  local out rc
  nh_capture out rc grep -nE -- '--from-session (plan|review|qa|security|ship)' \
    "$REPO/plan/SKILL.md" "$REPO/review/SKILL.md" "$REPO/qa/SKILL.md" \
    "$REPO/security/SKILL.md" "$REPO/ship/SKILL.md"
  nh_assert_eq "spec acceptance regex matches nothing (rc 1)" "1" "$rc"
}

# Cell 8: save-artifact.sh wires the per-phase validator.
cell_save_wires_validator() {
  nh_assert_file_contains "save-artifact.sh sources artifact-schemas.sh"  "$SAVE" 'artifact-schemas.sh'
  nh_assert_file_contains "save-artifact.sh calls nano_validate_artifact" "$SAVE" 'nano_validate_artifact'
}

# Cell 9: nano_validate_artifact stays callable from set -e callers even
# on malformed ship artifacts. A ship payload with a string summary and
# no top-level run_mode used to crash the jq probe (rc 5), so an errexit
# caller exited before the validator could return its documented schema
# error. Codex caught this on the PR 3 sixth review pass.
cell_validator_errexit_safe() {
  local ship_loose out rc
  ship_loose='{"phase":"ship","summary":"loose string"}'
  nh_capture out rc bash -ec "source '$REPO/bin/lib/artifact-schemas.sh'; nano_validate_artifact ship '$ship_loose' 2>/dev/null"
  nh_assert_eq "validator returns 1 (schema fail), not 5 (jq crash)" "1" "$rc"
}

nh_cell validator-accepts      cell_validator_accepts
nh_cell validator-rejects      cell_validator_rejects
nh_cell save-rejects-invalid   cell_save_rejects_invalid
nh_cell save-writes-valid      cell_save_writes_valid
nh_cell from-session-legacy    cell_from_session_legacy
nh_cell legacy-readable        cell_legacy_readable
nh_cell skill-md-clean         cell_skill_md_clean
nh_cell save-wires-validator   cell_save_wires_validator
nh_cell validator-errexit-safe cell_validator_errexit_safe

nh_summary
