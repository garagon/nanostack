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
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d /tmp/nanostack-structured.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

assert_true() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}cmd: %s${NC}\n" "$*"
  fi
}

assert_false() {
  local name="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}cmd unexpectedly succeeded: %s${NC}\n" "$*"
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}expected: %s${NC}\n" "$expected"
    printf "          ${DIM}actual:   %s${NC}\n" "$actual"
  fi
}

# Set up a fresh project + store. Every cell shares this base.
PROJ="$TMP_ROOT/project"
STORE="$PROJ/.nanostack"
mkdir -p "$PROJ" "$STORE"
cd "$PROJ"
git init -q
git config user.email "e2e@test.local"
git config user.name  "e2e"
export NANOSTACK_STORE="$STORE"

SAVE="$REPO/bin/save-artifact.sh"
FIND="$REPO/bin/find-artifact.sh"
RESOLVE="$REPO/bin/resolve.sh"

echo "Structured Artifact Enforcement E2E"
echo "==================================="
echo "Tmp root: $TMP_ROOT"
echo

# Cell 1: per-phase validator accepts the canonical structured shapes.
echo "[1] nano_validate_artifact accepts canonical shapes"
plan_ok=$(jq -n '{phase:"plan",summary:{planned_files:["a.ts"],plan_approval:"manual"},context_checkpoint:{summary:"x"}}')
review_ok=$(jq -n '{phase:"review",summary:{blocking:0},scope_drift:"none",findings:[],context_checkpoint:{summary:"x"}}')
qa_ok=$(jq -n '{phase:"qa",summary:{tests_run:5},findings:[],context_checkpoint:{summary:"x"}}')
sec_ok=$(jq -n '{phase:"security",summary:{total_findings:0},findings:[],context_checkpoint:{summary:"x"}}')
ship_ok=$(jq -n '{phase:"ship",summary:{pr_number:42,status:"merged"},context_checkpoint:{summary:"x"}}')
ship_ro=$(jq -n '{phase:"ship",summary:"would have shipped",run_mode:"report_only"}')
think_ok=$(jq -n '{phase:"think",summary:{value_proposition:"x"}}')
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
  assert_true "validator accepts canonical $kind" \
    bash -c "source '$REPO/bin/lib/artifact-schemas.sh'; nano_validate_artifact '$phase' '$json'"
done

# Cell 2: validator rejects invalid shapes with a stable error format.
echo "[2] nano_validate_artifact rejects missing required fields"
plan_bad=$(jq -n '{phase:"plan",summary:{plan_approval:"manual"},context_checkpoint:{summary:"x"}}')
review_bad=$(jq -n '{phase:"review",summary:{},context_checkpoint:{summary:"x"}}')
qa_bad=$(jq -n '{phase:"qa",summary:{tests_run:5}}')
sec_bad=$(jq -n '{phase:"security",summary:"a string"}')
ship_bad=$(jq -n '{phase:"ship",summary:"loose without report_only"}')
think_bad=$(jq -n '{phase:"think",summary:"plain string"}')
for kind in plan review qa sec ship think; do
  case "$kind" in
    plan)   json="$plan_bad";   phase=plan ;;
    review) json="$review_bad"; phase=review ;;
    qa)     json="$qa_bad";     phase=qa ;;
    sec)    json="$sec_bad";    phase=security ;;
    ship)   json="$ship_bad";   phase=ship ;;
    think)  json="$think_bad";  phase=think ;;
  esac
  assert_false "validator rejects invalid $kind" \
    bash -c "source '$REPO/bin/lib/artifact-schemas.sh'; nano_validate_artifact '$phase' '$json'"
done

# Cell 3: save-artifact.sh refuses to write invalid shapes.
echo "[3] save-artifact.sh exits 1 on invalid shape (no file written)"
before=$(find "$STORE" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
set +e
out=$( "$SAVE" plan "$plan_bad" 2>&1 )
rc=$?
set -e
after=$(find "$STORE" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exit code is 1"           "1"        "$rc"
assert_eq "no artifact written"      "$before"  "$after"
echo "$out" | grep -qE 'missing required fields' && \
  assert_eq "stderr mentions missing required fields" "yes" "yes" || \
  assert_eq "stderr mentions missing required fields" "yes" "no"

# Cell 4: save-artifact.sh writes valid structured artifacts and the
# saved file passes nano_artifact_trust (integrity field present).
echo "[4] save-artifact.sh writes valid structured artifacts"
saved_plan=$( "$SAVE" plan "$plan_ok" )
assert_true "plan artifact file exists" test -f "$saved_plan"
assert_true "plan artifact has context_checkpoint" \
  bash -c "jq -e '.context_checkpoint != null' '$saved_plan' >/dev/null"
assert_true "plan artifact has integrity field" \
  bash -c "jq -e '.integrity != null' '$saved_plan' >/dev/null"
assert_true "plan artifact has summary.planned_files array" \
  bash -c "jq -e '(.summary.planned_files | type) == \"array\"' '$saved_plan' >/dev/null"

saved_ship_ro=$( "$SAVE" ship "$ship_ro" )
assert_true "ship report_only artifact file exists" test -f "$saved_ship_ro"

# Cell 5: --from-session still works, emits deprecation, marks legacy.
echo "[5] --from-session writes a legacy artifact with deprecation warning"
set +e
out=$( "$SAVE" --from-session qa 'N tests passed' 2>&1 )
rc=$?
set -e
saved_legacy=$(echo "$out" | tail -1)
assert_eq "legacy save exit code is 0" "0" "$rc"
assert_true "legacy artifact file exists" test -f "$saved_legacy"
assert_true "legacy artifact has schema_legacy: true" \
  bash -c "jq -e '.schema_legacy == true' '$saved_legacy' >/dev/null"
echo "$out" | grep -qE '^save-artifact.sh: --from-session is a legacy mode' && \
  assert_eq "deprecation warning printed" "yes" "yes" || \
  assert_eq "deprecation warning printed" "yes" "no"

# Cell 6: legacy artifacts remain readable by find-artifact + resolve.
echo "[6] legacy artifacts are still readable by downstream tools"
found=$( "$FIND" qa 30 2>/dev/null )
assert_true "find-artifact returns the legacy qa artifact" test -f "$found"
# resolve.sh /ship reads qa upstream; the legacy qa load should not break it
# but the legacy artifact has summary as string, so upstream_status will
# be verified (because save-artifact still writes integrity).
resolved=$( "$RESOLVE" ship 2>/dev/null )
status_qa=$( echo "$resolved" | jq -r '.upstream_status.qa // ""' )
assert_eq "resolve.sh upstream_status.qa is verified" "verified" "$status_qa"

# Cell 7: SKILL.md acceptance regex (mirrors the lint job).
echo "[7] core SKILL.md no longer references --from-session normal save"
set +e
out=$( grep -nE -- '--from-session (plan|review|qa|security|ship)' \
  "$REPO/plan/SKILL.md" "$REPO/review/SKILL.md" "$REPO/qa/SKILL.md" \
  "$REPO/security/SKILL.md" "$REPO/ship/SKILL.md" 2>&1 )
rc=$?
set -e
assert_eq "spec acceptance regex matches nothing (rc 1)" "1" "$rc"

# Cell 8: save-artifact.sh sources artifact-schemas.sh and calls the
# validator (the lint guards this too; cell exists so the harness is
# self-contained for local development).
echo "[8] save-artifact.sh wires the per-phase validator"
script="$REPO/bin/save-artifact.sh"
grep -qF 'artifact-schemas.sh' "$script" && \
  assert_eq "save-artifact.sh sources artifact-schemas.sh" "yes" "yes" || \
  assert_eq "save-artifact.sh sources artifact-schemas.sh" "yes" "no"
grep -qF 'nano_validate_artifact' "$script" && \
  assert_eq "save-artifact.sh calls nano_validate_artifact" "yes" "yes" || \
  assert_eq "save-artifact.sh calls nano_validate_artifact" "yes" "no"

cd "$TMP_ROOT"

echo
echo "==================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Structured Artifact E2E: %d checks passed, 0 failed${NC}\n" "$PASS"
  exit 0
else
  printf "${RED}Structured Artifact E2E: %d failed of %d total${NC}\n" "$FAIL" "$TOTAL"
  exit 1
fi
