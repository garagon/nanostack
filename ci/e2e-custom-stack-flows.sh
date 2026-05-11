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
#  13. Scaffolding from a git subdirectory lands in the repo root store.
#  14. Scaffolding outside any git repo lands in $HOME/.nanostack.
#  15. Validator rejects mismatched frontmatter name.
#  16. Guard blocks writes during a read-only custom phase.
#  17. Custom write phase does not trigger the concurrency block.
#  18. Built-in review phase still blocks (regression check).
#  19. Guard finds repo-bundled non-core skills (feature, doctor).
#  20. Registered custom skill wins over bundled non-core fallback.
#  21. Unrelated user-installed skill does not shadow a bundled phase.
#  22. Guard still works when the store path contains a space.
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

# Cell 16: guard concurrency is registry-aware. A read-only custom phase
# must block writes the same way a built-in read phase does. Without the
# registry lookup, guard fell back to $NANOSTACK_ROOT/<phase>/SKILL.md
# and silently no-oped for every custom skill (which lives under the
# store's skills/, not the repo). Also exercises the in-project bypass
# (./ prefix + absolute in-project path) that Codex flagged on the
# PR 1 review — Tier 2.4 must run before the in-project fast-path or
# `touch ./x` inside a git worktree slips through.
echo "[16] guard blocks writes during a read-only custom phase"
GUARD_HOME="$TMP_ROOT/guard-home"
GUARD_PROJ="$TMP_ROOT/guard-project"
mkdir -p "$GUARD_HOME" "$GUARD_PROJ"
cd "$GUARD_PROJ"
git init -q
HOME="$GUARD_HOME" "$REPO/bin/create-skill.sh" license-audit --concurrency read >/dev/null
GUARD_STORE="$GUARD_PROJ/.nanostack"
[ -d "$GUARD_STORE/skills/license-audit" ] || GUARD_STORE="$GUARD_HOME/.nanostack"
echo '{"current_phase":"license-audit"}' > "$GUARD_STORE/session.json"
for case_cmd in "touch should-not-pass" "touch ./should-not-pass" "touch $GUARD_PROJ/should-not-pass"; do
  set +e
  NANOSTACK_STORE="$GUARD_STORE" HOME="$GUARD_HOME" \
    "$REPO/guard/bin/check-dangerous.sh" "$case_cmd" >/dev/null 2>&1
  guard_rc=$?
  set -e
  assert_eq "blocks: $case_cmd" "1" "$guard_rc"
done

# Cell 17: switching the same custom phase to concurrency: write lifts
# the concurrency block. (Other guard tiers may still object to specific
# commands; here we use a path outside the project so Tier 2 in-project
# fast-path does not auto-pass.)
echo "[17] custom write phase does not trigger the concurrency block"
sed_target="$GUARD_STORE/skills/license-audit/SKILL.md"
sed 's/^concurrency: read$/concurrency: write/' "$sed_target" > "$sed_target.tmp"
mv "$sed_target.tmp" "$sed_target"
OUT_TMP=$(mktemp -d /tmp/guard-outside.XXXXXX)
set +e
NANOSTACK_STORE="$GUARD_STORE" HOME="$GUARD_HOME" \
  "$REPO/guard/bin/check-dangerous.sh" "touch $OUT_TMP/x" >/dev/null 2>&1
guard_rc=$?
set -e
rm -rf "$OUT_TMP"
assert_eq "custom write phase does not block on concurrency (exit 0)" "0" "$guard_rc"

# Cell 18: built-in read phases keep working unchanged. /review is the
# canonical case: it must keep blocking touch even after the lookup
# moved through the phase registry.
echo "[18] built-in review phase still blocks writes"
echo '{"current_phase":"review"}' > "$GUARD_STORE/session.json"
set +e
NANOSTACK_STORE="$GUARD_STORE" HOME="$GUARD_HOME" \
  "$REPO/guard/bin/check-dangerous.sh" "touch should-not-pass" >/dev/null 2>&1
guard_rc=$?
set -e
assert_eq "built-in review phase blocks write (exit 1)" "1" "$guard_rc"

# Cell 19: repo-bundled non-core skills (feature, doctor, help, ...)
# also have concurrency: read frontmatter. The guard's previous raw
# lookup at $NANOSTACK_ROOT/<phase>/SKILL.md saw them directly; the
# registry-aware lookup must keep finding them. Codex caught the
# regression on PR 1's fourth pass — without the repo-root fallback,
# `current_phase=feature` left SKILL_CONC empty and the guard allowed
# writes.
echo "[19] guard finds repo-bundled non-core skills"
BUNDLED_PROJ="$TMP_ROOT/bundled-project"
mkdir -p "$BUNDLED_PROJ/.nanostack"
cd "$BUNDLED_PROJ"
git init -q
for bundled in feature doctor; do
  echo "{\"current_phase\":\"$bundled\"}" > "$BUNDLED_PROJ/.nanostack/session.json"
  set +e
  NANOSTACK_STORE="$BUNDLED_PROJ/.nanostack" \
    "$REPO/guard/bin/check-dangerous.sh" "touch should-not-pass" >/dev/null 2>&1
  guard_rc=$?
  set -e
  assert_eq "bundled $bundled phase blocks write" "1" "$guard_rc"
done
cd "$PROJ"

# Cell 20: a registered custom phase that reuses a repo-bundled
# directory name (feature, doctor, ...) must win over the bundled
# fallback. create-skill.sh does not reserve bundled names, so a
# user can legitimately register `feature` themselves with their own
# concurrency. Codex caught the precedence regression on the PR 1
# fifth pass; this cell locks the correct order.
echo "[20] registered custom skill wins over bundled non-core fallback"
PREC_PROJ="$TMP_ROOT/precedence-project"
mkdir -p "$PREC_PROJ/.nanostack/skills/feature"
cd "$PREC_PROJ"
git init -q
cat > "$PREC_PROJ/.nanostack/config.json" <<'EOF'
{"custom_phases":["feature"]}
EOF
cat > "$PREC_PROJ/.nanostack/skills/feature/SKILL.md" <<'EOF'
---
name: feature
description: user-registered feature override
concurrency: write
---
body
EOF
echo '{"current_phase":"feature"}' > "$PREC_PROJ/.nanostack/session.json"
PREC_OUT=$(mktemp -d /tmp/precedence-out.XXXXXX)
set +e
NANOSTACK_STORE="$PREC_PROJ/.nanostack" \
  "$REPO/guard/bin/check-dangerous.sh" "touch $PREC_OUT/x" >/dev/null 2>&1
guard_rc=$?
set -e
rm -rf "$PREC_OUT"
cd "$PROJ"
assert_eq "custom feature (write) shadows bundled feature (read)" "0" "$guard_rc"

# Cell 21: an unrelated user-installed skill under ~/.claude/skills or
# ~/.agents/skills that happens to share a name with a bundled non-core
# phase must NOT silently shadow the bundled SKILL.md. Only an
# explicitly registered custom phase (in .nanostack/config.json's
# custom_phases) is allowed to override. Codex caught this on the
# PR 1 sixth pass.
echo "[21] unrelated user-installed skill does not shadow bundled phase"
SHADOW_HOME="$TMP_ROOT/shadow-home"
SHADOW_PROJ="$TMP_ROOT/shadow-project"
mkdir -p "$SHADOW_HOME/.claude/skills/feature" "$SHADOW_PROJ/.nanostack"
cat > "$SHADOW_HOME/.claude/skills/feature/SKILL.md" <<'EOF'
---
name: feature
description: unrelated user-installed skill (no registration)
concurrency: write
---
body
EOF
cd "$SHADOW_PROJ"
git init -q
echo '{"current_phase":"feature"}' > "$SHADOW_PROJ/.nanostack/session.json"
set +e
HOME="$SHADOW_HOME" NANOSTACK_STORE="$SHADOW_PROJ/.nanostack" \
  "$REPO/guard/bin/check-dangerous.sh" "touch x" >/dev/null 2>&1
guard_rc=$?
set -e
cd "$PROJ"
assert_eq "bundled feature still wins when no registered custom" "1" "$guard_rc"

# Cell 22: a HOME (or store) path that contains a space must not break
# the guard. The previous space-separated root iteration in
# nano_phase_skill_path silently dropped path halves and made the
# concurrency block a no-op for these users. Codex caught the
# regression on PR 1 of the architecture round; this cell locks it.
echo "[22] guard works when store path contains a space"
SPACE_TMP=$(mktemp -d /tmp/nanostack-space.XXXXXX)
SPACE_HOME="$SPACE_TMP/home with space"
SPACE_PROJ="$SPACE_TMP/nogit"
mkdir -p "$SPACE_HOME" "$SPACE_PROJ"
cd "$SPACE_PROJ"
HOME="$SPACE_HOME" "$REPO/bin/create-skill.sh" license-audit --concurrency read >/dev/null
SPACE_STORE="$SPACE_HOME/.nanostack"
echo '{"current_phase":"license-audit"}' > "$SPACE_STORE/session.json"
set +e
NANOSTACK_STORE="$SPACE_STORE" HOME="$SPACE_HOME" \
  "$REPO/guard/bin/check-dangerous.sh" "touch should-not-pass" >/dev/null 2>&1
guard_rc=$?
set -e
cd "$PROJ"
rm -rf "$SPACE_TMP"
assert_eq "store path with space still blocks (exit 1)" "1" "$guard_rc"

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
