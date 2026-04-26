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

# Cell 11: agents/openai.yaml is present with the three discovery keys.
# Narrow grep beats PyYAML here — keep the harness portable on any
# machine with bash + jq + node.
echo "[11] agents/openai.yaml present with required keys"
SKILLS_ROOT_FOR_CHECK="${NANOSTACK_STORE:-$PROJ/.nanostack}/skills"
[ -d "$SKILLS_ROOT_FOR_CHECK/license-audit/agents" ] || \
  SKILLS_ROOT_FOR_CHECK="$PROJ/.nanostack/skills"
assert_true "openai.yaml exists" \
  test -f "$SKILLS_ROOT_FOR_CHECK/license-audit/agents/openai.yaml"
assert_true "openai.yaml has display_name + short_description + default_prompt" \
  bash -c "grep -qE '^[[:space:]]+display_name:' '$SKILLS_ROOT_FOR_CHECK/license-audit/agents/openai.yaml' && grep -qE '^[[:space:]]+short_description:' '$SKILLS_ROOT_FOR_CHECK/license-audit/agents/openai.yaml' && grep -qE '^[[:space:]]+default_prompt:' '$SKILLS_ROOT_FOR_CHECK/license-audit/agents/openai.yaml'"

# Cell 12: copied skill has no repo-relative example paths.
echo "[12] copied skill has no repo-relative example paths"
assert_true "SKILL.md has no ./examples/custom-skill-template/ leak" \
  bash -c "! grep -qE '\\./examples/custom-skill-template/' .nanostack/skills/license-audit/SKILL.md"

# Cell 13: scaffolding from a git subdirectory must land in the repo
# root's .nanostack, not the subdir's. Codex caught a regression here:
# create-skill.sh used cwd-relative paths so a user invoking the tool
# from src/ wrote .nanostack/ inside src/, then check-custom-skill.sh
# (which resolves the store via store-path.sh -> repo root) failed
# the registration check.
echo "[13] create-skill resolves the store from a subdirectory"
SUB_PROJ="$TMP_ROOT/subdir-project"
mkdir -p "$SUB_PROJ/src/feature"
cd "$SUB_PROJ"
git init -q
cd "$SUB_PROJ/src/feature"
"$REPO/bin/create-skill.sh" subdir-skill --concurrency read >/dev/null
assert_true "skill landed in repo root, not in src/feature" \
  test -f "$SUB_PROJ/.nanostack/skills/subdir-skill/SKILL.md"
assert_true "no rogue .nanostack inside src/feature" \
  bash -c "! test -d '$SUB_PROJ/src/feature/.nanostack'"
out=$( "$REPO/bin/check-custom-skill.sh" "$SUB_PROJ/.nanostack/skills/subdir-skill" 2>&1 )
assert_true "check-custom-skill passes from a subdir scaffold" \
  bash -c "echo '$out' | tail -1 | grep -qE '^OK:'"
# Conductor invoked from the subdir must still read the scaffolded
# SKILL.md from the resolved store. Without the lookup-roots fix, batch
# silently defaults to concurrency=write because nano_phase_skill_path
# only searched .nanostack/skills relative to cwd.
"$REPO/conductor/bin/sprint.sh" start \
  --phases '[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"subdir-skill","depends_on":["build"]},{"name":"ship","depends_on":["subdir-skill"]}]' \
  >/dev/null
sub_batch=$( "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
assert_true "subdir conductor reads SKILL.md (no 'no SKILL.md' warning)" \
  bash -c "! echo '$sub_batch' | grep -qF 'no SKILL.md found'"
assert_true "subdir conductor schedules subdir-skill as type=read" \
  bash -c "echo '$sub_batch' | grep -qE '\"phases\":\\[[^]]*\"subdir-skill\"[^]]*\\].*\"type\":\"read\"|\"type\":\"read\".*\"phases\":\\[[^]]*\"subdir-skill\"'"

# Cell 14: scaffolding outside any git repo. lib/store-path.sh falls
# back to $HOME/.nanostack, so create-skill must too. Use a fake HOME
# inside TMP_ROOT so the test does not touch the real ~/.nanostack.
echo "[14] create-skill resolves the store outside git (fake HOME)"
NOGIT_HOME="$TMP_ROOT/nogit-home"
NOGIT_PROJ="$TMP_ROOT/nogit-project"
mkdir -p "$NOGIT_HOME" "$NOGIT_PROJ"
cd "$NOGIT_PROJ"
HOME="$NOGIT_HOME" "$REPO/bin/create-skill.sh" nogit-skill --concurrency read >/dev/null
assert_true "skill landed in fake-HOME store, not cwd" \
  test -f "$NOGIT_HOME/.nanostack/skills/nogit-skill/SKILL.md"
assert_true "no rogue .nanostack inside the cwd" \
  bash -c "! test -d '$NOGIT_PROJ/.nanostack'"
out=$( HOME="$NOGIT_HOME" "$REPO/bin/check-custom-skill.sh" "$NOGIT_HOME/.nanostack/skills/nogit-skill" 2>&1 )
assert_true "check-custom-skill passes outside git" \
  bash -c "echo '$out' | tail -1 | grep -qE '^OK:'"
# Conductor outside git must read the scaffolded SKILL.md from
# $HOME/.nanostack/skills, not fall through to ~/.claude/skills or
# the cwd-relative legacy root.
HOME="$NOGIT_HOME" "$REPO/conductor/bin/sprint.sh" start \
  --phases '[{"name":"think","depends_on":[]},{"name":"build","depends_on":["think"]},{"name":"nogit-skill","depends_on":["build"]},{"name":"ship","depends_on":["nogit-skill"]}]' \
  >/dev/null
nogit_batch=$( HOME="$NOGIT_HOME" "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
assert_true "no-git conductor reads SKILL.md (no 'no SKILL.md' warning)" \
  bash -c "! echo '$nogit_batch' | grep -qF 'no SKILL.md found'"
assert_true "no-git conductor schedules nogit-skill as type=read" \
  bash -c "echo '$nogit_batch' | grep -qE '\"phases\":\\[[^]]*\"nogit-skill\"[^]]*\\].*\"type\":\"read\"|\"type\":\"read\".*\"phases\":\\[[^]]*\"nogit-skill\"'"

# Cell 15: validator catches a frontmatter name that does not match
# the directory basename. Codex hit a false-positive OK after a
# manual copy that left `name: audit-licenses` inside a
# license-audit/ folder; the agent would have exposed the wrong
# slash command.
echo "[15] validator rejects mismatched frontmatter name"
DRIFT_HOME="$TMP_ROOT/drift-home"
DRIFT_PROJ="$TMP_ROOT/drift-project"
mkdir -p "$DRIFT_HOME" "$DRIFT_PROJ"
cd "$DRIFT_PROJ"
HOME="$DRIFT_HOME" "$REPO/bin/create-skill.sh" license-audit >/dev/null
# Sabotage the SKILL.md so the frontmatter still says the source
# template name. This is the "user copied by hand and forgot to
# rename" path.
DRIFT_SKILL="$DRIFT_HOME/.nanostack/skills/license-audit"
sed 's/^name:.*/name: audit-licenses/' "$DRIFT_SKILL/SKILL.md" > "$DRIFT_SKILL/SKILL.md.tmp"
mv "$DRIFT_SKILL/SKILL.md.tmp" "$DRIFT_SKILL/SKILL.md"
assert_false "check-custom-skill rejects mismatched frontmatter name" \
  bash -c "HOME='$DRIFT_HOME' '$REPO/bin/check-custom-skill.sh' '$DRIFT_SKILL'"

cd "$PROJ"

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
