#!/usr/bin/env bash
# e2e-custom-stack-flows.sh — Custom Stack Framework v1, end-to-end.
#
# Runs the full new-user journey on a real /tmp project:
#   1. Scaffold a custom skill with bin/create-skill.sh.
#   2. Validate it with bin/check-custom-skill.sh.
#   3. Run its helper script.
#   4. Save and find an artifact.
#   5. Resolve the custom phase (phase_kind=custom).
#   6. Generate a sprint journal (custom phase appears).
#   7. Run analytics --json (custom phase counted).
#   8. Default discard --dry-run (custom artifact listed).
#   9. Start a conductor sprint with --phases that includes the custom phase.
#  10. Conductor batch reads concurrency=read from the custom skill.
#  11. agents/openai.yaml is present and parses.
#  12. The copied skill has no repo-relative example paths.
#
# This harness is the contract Codex's spec calls for in PR 6: a clean
# sandbox user can complete the entire workflow without reading source.
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d /tmp/nanostack-cs-flows.XXXXXX)
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

echo "Custom Stack Framework v1 E2E"
echo "============================="
echo "Tmp root: $TMP_ROOT"
echo

PROJ="$TMP_ROOT/project"
mkdir -p "$PROJ"
cd "$PROJ"
git init -q

# Cell 1: scaffold a new custom skill via bin/create-skill.sh.
echo "[1] scaffold custom skill"
"$REPO/bin/create-skill.sh" license-audit --concurrency read --depends-on build >/dev/null
assert_true "skill directory exists" \
  test -d ".nanostack/skills/license-audit"
assert_true "phase registered in config" \
  bash -c 'jq -e ".custom_phases | index(\"license-audit\")" .nanostack/config.json >/dev/null'

# Cell 2: bin/check-custom-skill.sh passes on the scaffolded skill.
echo "[2] check-custom-skill validates the scaffolded skill"
out=$( "$REPO/bin/check-custom-skill.sh" .nanostack/skills/license-audit 2>&1 )
last_line=$(echo "$out" | tail -1)
assert_true "check-custom-skill ends with OK summary" \
  bash -c "echo '$last_line' | grep -qE '^OK:'"

# Cell 3: helper script runs from its copied location.
echo "[3] helper runs from copied location"
printf '%s\n' '{"name":"e2e","dependencies":{"lodash":"4.17.21"}}' > package.json
audit_json=$( ".nanostack/skills/license-audit/bin/audit.sh" node 2>/dev/null )
assert_true "helper emits .counts" \
  bash -c "echo '$audit_json' | jq -e '.counts' >/dev/null"

# Cell 4: save + find artifact.
echo "[4] save and find an artifact"
"$REPO/bin/save-artifact.sh" license-audit \
  '{"phase":"license-audit","summary":{"status":"OK","headline":"e2e smoke"},"context_checkpoint":{"summary":"saved"}}' \
  >/dev/null
found=$( "$REPO/bin/find-artifact.sh" license-audit 30 2>/dev/null )
assert_true "find-artifact returns a file" test -f "$found"
assert_true "saved artifact has phase=license-audit" \
  bash -c "jq -e '.phase == \"license-audit\"' '$found' >/dev/null"

# Cell 5: resolver classifies the phase as custom.
echo "[5] resolver returns phase_kind=custom"
resolved=$( "$REPO/bin/resolve.sh" license-audit 2>/dev/null )
kind=$( echo "$resolved" | jq -r '.phase_kind' )
assert_eq "phase_kind == custom" "custom" "$kind"

# Cell 6: sprint journal includes a /<phase> section.
echo "[6] sprint-journal emits /license-audit section"
journal=$( "$REPO/bin/sprint-journal.sh" )
assert_true "journal file exists" test -f "$journal"
assert_true "journal includes /license-audit" \
  bash -c "grep -qF '## /license-audit' '$journal'"
assert_true "journal mentions e2e smoke headline" \
  bash -c "grep -qF 'e2e smoke' '$journal'"

# Cell 7: analytics --json includes the custom count.
echo "[7] analytics --json includes custom count"
analytics=$( "$REPO/bin/analytics.sh" --json )
assert_true "analytics.sprints.custom.license-audit >= 1" \
  bash -c "echo '$analytics' | jq -e '.sprints.\"custom\".\"license-audit\" >= 1' >/dev/null"
assert_true "analytics.sprints.total >= 1" \
  bash -c "echo '$analytics' | jq -e '.sprints.total >= 1' >/dev/null"

# Cell 8: default discard --dry-run lists the custom artifact.
echo "[8] default discard --dry-run lists the custom artifact"
discard_out=$( "$REPO/bin/discard-sprint.sh" --dry-run )
assert_true "dry-run includes license-audit" \
  bash -c "echo '$discard_out' | grep -qF 'license-audit'"

# Cell 9: conductor sprint includes the custom phase via --phases.
echo "[9] conductor sprint includes the custom phase"
"$REPO/conductor/bin/sprint.sh" start \
  --phases '[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"license-audit","depends_on":["build"]},{"name":"ship","depends_on":["license-audit"]}]' \
  >/dev/null
sprint_status=$( "$REPO/conductor/bin/sprint.sh" status )
assert_true "conductor.phases has license-audit" \
  bash -c "echo '$sprint_status' | jq -e '.phases | has(\"license-audit\")' >/dev/null"
assert_true "conductor sprint has 5 phases" \
  bash -c "echo '$sprint_status' | jq -e '.phases | length == 5' >/dev/null"

# Cell 10: cmd_batch reads the custom skill's concurrency.
echo "[10] conductor batch reads custom skill concurrency=read"
batch_out=$( "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
assert_true "license-audit appears in a type=read batch" \
  bash -c "echo '$batch_out' | grep -qE '\"phases\":\\[[^]]*\"license-audit\"[^]]*\\].*\"type\":\"read\"|\"type\":\"read\".*\"phases\":\\[[^]]*\"license-audit\"'"

# Cell 11: agents/openai.yaml is present and parses.
echo "[11] agents/openai.yaml present and parses"
assert_true "openai.yaml exists" \
  test -f ".nanostack/skills/license-audit/agents/openai.yaml"
assert_true "openai.yaml parses as YAML" \
  python3 -c "import yaml; yaml.safe_load(open('.nanostack/skills/license-audit/agents/openai.yaml'))"

# Cell 12: copied skill has no repo-relative example paths.
echo "[12] copied skill has no repo-relative example paths"
assert_true "SKILL.md has no ./examples/custom-skill-template/ leak" \
  bash -c "! grep -qE '\\./examples/custom-skill-template/' .nanostack/skills/license-audit/SKILL.md"

echo
echo "============================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Custom Stack E2E: %d checks passed, 0 failed${NC}\n" "$PASS"
  exit 0
else
  printf "${RED}Custom Stack E2E: %d failed of %d total${NC}\n" "$FAIL" "$TOTAL"
  exit 1
fi
