#!/usr/bin/env bash
# e2e-custom-stack-examples.sh — Custom Stack Examples v1 runtime contract.
#
# Walks the full new-user journey for the compliance-release stack on
# a real /tmp project, no network, no installs. Proves that the stack
# composes save / find / resolve / journal / analytics / discard /
# conductor end-to-end, and that the install path resolves correctly
# from a git subdirectory and from a no-git project.
#
# 15 cells, ≥35 assertions per the spec
# (reference/custom-stack-examples-technical-spec.md).
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="$REPO/examples/custom-stack-template/compliance-release"
TMP_ROOT=$(mktemp -d /tmp/cse-runtime.XXXXXX)
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

echo "Custom Stack Examples v1 runtime E2E"
echo "===================================="
echo "Tmp root: $TMP_ROOT"
echo

# ─── Cell 1: fixture project ────────────────────────────────────────
# Minimal Node app with one MIT dep installed under node_modules, a
# README, an .env.example, and a source file with email + name fields.
# License-audit + privacy-check both need real bytes to scan.
echo "[1] fixture project"
PROJ="$TMP_ROOT/main"
mkdir -p "$PROJ/src" "$PROJ/node_modules/lodash"
cd "$PROJ"
git init -q
cat > package.json <<'JSON'
{ "name": "cse-fixture", "dependencies": { "lodash": "4.17.21" } }
JSON
cat > node_modules/lodash/package.json <<'JSON'
{ "name": "lodash", "version": "4.17.21", "license": "MIT" }
JSON
cat > README.md <<'MD'
# CSE Fixture
A minimal app for the runtime stack harness.
MD
cat > src/signup.js <<'JS'
const profile = { email: req.body.email, name: req.body.name };
JS
cat > .env.example <<'ENV'
EMAIL_API_KEY=replace_me
APP_NAME=demo
ENV
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
assert_true "fixture has package.json + src + README + .env.example" \
  bash -c "test -f package.json && test -f src/signup.js && test -f README.md && test -f .env.example"

# ─── Cell 2: install via bin/create-skill.sh --from ────────────────
# Mirrors the install commands documented in compliance-release/README.md.
echo "[2] install three skills via bin/create-skill.sh --from"
"$REPO/bin/create-skill.sh" license-audit \
  --from "$STACK_DIR/skills/license-audit" \
  --concurrency read --depends-on build >/dev/null
"$REPO/bin/create-skill.sh" privacy-check \
  --from "$STACK_DIR/skills/privacy-check" \
  --concurrency read --depends-on build >/dev/null
"$REPO/bin/create-skill.sh" release-readiness \
  --from "$STACK_DIR/skills/release-readiness" \
  --concurrency read \
  --depends-on review --depends-on qa --depends-on security \
  --depends-on license-audit --depends-on privacy-check >/dev/null
assert_true "license-audit installed under store" \
  test -f "$NANOSTACK_STORE/skills/license-audit/SKILL.md"
assert_true "privacy-check installed under store" \
  test -f "$NANOSTACK_STORE/skills/privacy-check/SKILL.md"
assert_true "release-readiness installed under store" \
  test -f "$NANOSTACK_STORE/skills/release-readiness/SKILL.md"
assert_true "all three phases registered in config" \
  bash -c '
    cfg="$NANOSTACK_STORE/config.json"
    jq -e ".custom_phases | (index(\"license-audit\") != null) and (index(\"privacy-check\") != null) and (index(\"release-readiness\") != null)" "$cfg" >/dev/null
  '

# ─── Cell 3: bin/check-custom-skill.sh validates each ──────────────
echo "[3] bin/check-custom-skill.sh per skill"
for s in license-audit privacy-check release-readiness; do
  out=$( "$REPO/bin/check-custom-skill.sh" "$NANOSTACK_STORE/skills/$s" 2>&1 )
  if echo "$out" | tail -1 | grep -qE "^OK:"; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    check-custom-skill: %s\n" "$s"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  check-custom-skill: %s\n" "$s"
    echo "$out"
  fi
done

# ─── Cell 4: save fake core artifacts (review, qa, security) ───────
# Each is OK so the rollup later only depends on license-audit /
# privacy-check / release-readiness.
echo "[4] save core artifacts (review, qa, security) via save-artifact.sh"
"$REPO/bin/save-artifact.sh" review \
  '{"phase":"review","summary":{"status":"OK","blocking":0,"should_fix":0,"nitpicks":0,"positive":1},"context_checkpoint":{"summary":"reviewed"}}' \
  >/dev/null
"$REPO/bin/save-artifact.sh" qa \
  '{"phase":"qa","summary":{"status":"OK","tests_run":1,"tests_passed":1,"tests_failed":0,"bugs_found":0,"bugs_fixed":0},"context_checkpoint":{"summary":"qa"}}' \
  >/dev/null
"$REPO/bin/save-artifact.sh" security \
  '{"phase":"security","summary":{"status":"OK","critical":0,"high":0,"medium":0,"low":0,"total_findings":0},"context_checkpoint":{"summary":"clean"}}' \
  >/dev/null
assert_true "review artifact saved with .integrity" \
  bash -c 'jq -e ".integrity != null" $(ls $NANOSTACK_STORE/review/*.json | head -1) >/dev/null'
assert_true "qa artifact saved with .integrity" \
  bash -c 'jq -e ".integrity != null" $(ls $NANOSTACK_STORE/qa/*.json | head -1) >/dev/null'
assert_true "security artifact saved with .integrity" \
  bash -c 'jq -e ".integrity != null" $(ls $NANOSTACK_STORE/security/*.json | head -1) >/dev/null'

# ─── Cell 5: run license-audit and save its artifact ───────────────
echo "[5] run license-audit/bin/audit.sh + save artifact"
audit_out=$( "$NANOSTACK_STORE/skills/license-audit/bin/audit.sh" )
assert_true "audit.sh emits .counts" \
  bash -c "echo '$audit_out' | jq -e '.counts' >/dev/null"
assert_true "audit detects MIT lodash as permissive" \
  bash -c "echo '$audit_out' | jq -e '.counts.permissive == 1 and .counts.strong_copyleft == 0' >/dev/null"
license_summary=$( jq -n \
  --argjson counts "$(echo "$audit_out" | jq '.counts')" \
  --argjson flagged "$(echo "$audit_out" | jq '.flagged')" \
  '{
    phase: "license-audit",
    summary: { status: "OK", headline: "e2e: 1 MIT dep", counts: $counts, flagged: $flagged, next_action: "None." },
    context_checkpoint: { summary: "license audit completed" }
  }' )
"$REPO/bin/save-artifact.sh" license-audit "$license_summary" >/dev/null
assert_true "license-audit artifact saved" \
  bash -c "ls $NANOSTACK_STORE/license-audit/*.json | head -1 | grep -q ."

# ─── Cell 6: run privacy-check and save its artifact ───────────────
echo "[6] run privacy-check/bin/check.sh + save artifact"
priv_out=$( "$NANOSTACK_STORE/skills/privacy-check/bin/check.sh" )
assert_true "privacy-check detects email signal" \
  bash -c "echo '$priv_out' | jq -e '.signals | any(.kind == \"personal_data\" and .evidence == \"email\")' >/dev/null"
assert_true "privacy-check detects name signal" \
  bash -c "echo '$priv_out' | jq -e '.signals | any(.kind == \"personal_data\" and .evidence == \"name\")' >/dev/null"
assert_true "privacy-check flags missing privacy_note (no PRIVACY.md, no Privacy section)" \
  bash -c "echo '$priv_out' | jq -e '.missing | index(\"privacy_note\") != null' >/dev/null"
privacy_summary=$( jq -n \
  --argjson signals "$(echo "$priv_out" | jq '.signals')" \
  --argjson missing "$(echo "$priv_out" | jq '.missing')" \
  '{
    phase: "privacy-check",
    summary: { status: "WARN", headline: "Email + name without privacy note", signals: $signals, missing: $missing, next_action: "Add a privacy note before shipping." },
    context_checkpoint: { summary: "privacy hygiene completed" }
  }' )
"$REPO/bin/save-artifact.sh" privacy-check "$privacy_summary" >/dev/null
assert_true "privacy-check artifact saved" \
  bash -c "ls $NANOSTACK_STORE/privacy-check/*.json | head -1 | grep -q ."

# ─── Cell 7: bin/resolve.sh release-readiness ──────────────────────
echo "[7] bin/resolve.sh release-readiness"
resolved=$( "$REPO/bin/resolve.sh" release-readiness 2>/dev/null )
assert_eq "resolver phase_kind == custom" "custom" \
  "$( echo "$resolved" | jq -r '.phase_kind' )"
for upstream in review qa security license-audit privacy-check; do
  assert_true "upstream_artifacts has '$upstream' key" \
    bash -c "echo '$resolved' | jq -e '.upstream_artifacts | has(\"$upstream\")' >/dev/null"
done
# Each declared upstream now has a saved artifact, so the resolver
# returns a path (not null) for each.
assert_true "every declared upstream resolves to a path (not null)" \
  bash -c "echo '$resolved' | jq -e '.upstream_artifacts | to_entries | all(.value | type == \"string\")' >/dev/null"

# ─── Cell 8: run release-readiness summarize + save ────────────────
echo "[8] run release-readiness/bin/summarize.sh + save artifact"
sum_out=$( NANOSTACK_ROOT="$REPO" "$NANOSTACK_STORE/skills/release-readiness/bin/summarize.sh" )
rollup=$( echo "$sum_out" | jq -r '.rollup_status' )
# privacy-check is WARN, others OK -> rollup WARN.
assert_eq "rollup is WARN (privacy-check WARN, others OK)" "WARN" "$rollup"
assert_true "checks include all five upstreams" \
  bash -c "echo '$sum_out' | jq -e '.checks | length == 5' >/dev/null"
release_summary=$( jq -n \
  --argjson checks "$(echo "$sum_out" | jq '.checks')" \
  --arg rollup "$rollup" \
  '{
    phase: "release-readiness",
    summary: { status: $rollup, headline: ("Release readiness: " + $rollup), checks: $checks, next_action: "Add a privacy note and re-run /privacy-check." },
    context_checkpoint: { summary: "release readiness composed" }
  }' )
"$REPO/bin/save-artifact.sh" release-readiness "$release_summary" >/dev/null
assert_true "release-readiness artifact saved" \
  bash -c "ls $NANOSTACK_STORE/release-readiness/*.json | head -1 | grep -q ."

# ─── Cell 9: sprint-journal sections ───────────────────────────────
echo "[9] sprint-journal includes the three custom phases"
journal=$( "$REPO/bin/sprint-journal.sh" )
for s in license-audit privacy-check release-readiness; do
  assert_true "journal has '## /$s' section" \
    bash -c "grep -qF '## /$s' '$journal'"
done

# ─── Cell 10: analytics --json includes custom counts ─────────────
echo "[10] analytics --json counts the three custom phases"
analytics=$( "$REPO/bin/analytics.sh" --json )
for s in license-audit privacy-check release-readiness; do
  assert_true "analytics.sprints.custom.\"$s\" >= 1" \
    bash -c "echo '$analytics' | jq -e \".sprints.\\\"custom\\\".\\\"$s\\\" >= 1\" >/dev/null"
done
assert_true "analytics.sprints.custom_total >= 3" \
  bash -c "echo '$analytics' | jq -e '.sprints.custom_total >= 3' >/dev/null"

# ─── Cell 11: discard --dry-run lists custom artifacts ────────────
echo "[11] discard-sprint --dry-run lists the three custom artifacts"
discard=$( "$REPO/bin/discard-sprint.sh" --dry-run )
for s in license-audit privacy-check release-readiness; do
  assert_true "discard --dry-run mentions $s" \
    bash -c "echo '$discard' | grep -qF '$s'"
done

# ─── Cell 12: conductor start with the stack's phase_graph ────────
echo "[12] conductor sprint.sh start with stack.json phase_graph"
phase_graph=$( jq '.phase_graph' "$STACK_DIR/stack.json" )
jq --argjson g "$phase_graph" '.phase_graph = $g' "$NANOSTACK_STORE/config.json" \
  > "$NANOSTACK_STORE/config.json.tmp" \
  && mv "$NANOSTACK_STORE/config.json.tmp" "$NANOSTACK_STORE/config.json"
"$REPO/conductor/bin/sprint.sh" start >/dev/null
sprint_status=$( "$REPO/conductor/bin/sprint.sh" status )
for p in license-audit privacy-check release-readiness; do
  assert_true "sprint includes '$p'" \
    bash -c "echo '$sprint_status' | jq -e '.phases | has(\"$p\")' >/dev/null"
done
assert_true "sprint has 10 nodes (think+plan+build+review+qa+security+3 custom+ship)" \
  bash -c "echo '$sprint_status' | jq -e '.phases | length == 10' >/dev/null"

# ─── Cell 13: conductor batch ordering and concurrency ────────────
echo "[13] conductor sprint.sh batch — ordering + concurrency"
batch_out=$( "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
# license-audit + privacy-check both depend only on build; both are
# concurrency=read; conductor should schedule them in the same
# type=read batch after build completes.
build_line=$( echo "$batch_out" | grep -nF '"build"' | head -1 | cut -d: -f1 )
la_line=$( echo "$batch_out" | grep -nF '"license-audit"' | head -1 | cut -d: -f1 )
pc_line=$( echo "$batch_out" | grep -nF '"privacy-check"' | head -1 | cut -d: -f1 )
rr_line=$( echo "$batch_out" | grep -nF '"release-readiness"' | head -1 | cut -d: -f1 )
ship_line=$( echo "$batch_out" | grep -nF '"ship"' | head -1 | cut -d: -f1 )
assert_true "build appears before license-audit + privacy-check" \
  bash -c "[ '$build_line' -lt '$la_line' ] && [ '$build_line' -lt '$pc_line' ]"
assert_true "release-readiness appears after license-audit + privacy-check" \
  bash -c "[ '$rr_line' -gt '$la_line' ] && [ '$rr_line' -gt '$pc_line' ]"
assert_true "ship appears after release-readiness" \
  bash -c "[ '$ship_line' -gt '$rr_line' ]"
assert_true "license-audit scheduled as type=read" \
  bash -c "echo '$batch_out' | grep -qE '\"type\":\"read\".*\"phases\":\\[[^]]*\"license-audit\"|\"phases\":\\[[^]]*\"license-audit\"[^]]*\\].*\"type\":\"read\"'"
assert_true "privacy-check scheduled as type=read" \
  bash -c "echo '$batch_out' | grep -qE '\"type\":\"read\".*\"phases\":\\[[^]]*\"privacy-check\"|\"phases\":\\[[^]]*\"privacy-check\"[^]]*\\].*\"type\":\"read\"'"

# ─── Cell 14: subdir scaffold lands in repo root .nanostack ───────
# Same install, run from a subdirectory. store-path.sh resolves to
# the git repo root, so the skill must land there (not in subdir/.nanostack).
echo "[14] scaffold from a git subdirectory"
SUB_PROJ="$TMP_ROOT/subdir-project"
mkdir -p "$SUB_PROJ/src/feature"
cd "$SUB_PROJ"
git init -q
cd "$SUB_PROJ/src/feature"
unset NANOSTACK_STORE
"$REPO/bin/create-skill.sh" license-audit \
  --from "$STACK_DIR/skills/license-audit" \
  --concurrency read --depends-on build >/dev/null
assert_true "subdir scaffold lands in repo root .nanostack/skills" \
  test -f "$SUB_PROJ/.nanostack/skills/license-audit/SKILL.md"
assert_false "no rogue .nanostack inside the subdir" \
  test -d "$SUB_PROJ/src/feature/.nanostack"

# ─── Cell 15: no-git scaffold lands in $HOME/.nanostack ───────────
# No git init in this project; HOME points at a fresh tmp so the
# real ~/.nanostack is untouched.
echo "[15] scaffold without git (fake HOME)"
NOGIT_HOME="$TMP_ROOT/nogit-home"
NOGIT_PROJ="$TMP_ROOT/nogit-project"
mkdir -p "$NOGIT_HOME" "$NOGIT_PROJ"
cd "$NOGIT_PROJ"
HOME="$NOGIT_HOME" "$REPO/bin/create-skill.sh" license-audit \
  --from "$STACK_DIR/skills/license-audit" \
  --concurrency read --depends-on build >/dev/null
assert_true "no-git scaffold lands in fake \$HOME/.nanostack/skills" \
  test -f "$NOGIT_HOME/.nanostack/skills/license-audit/SKILL.md"
assert_false "no .nanostack inside the no-git project cwd" \
  test -d "$NOGIT_PROJ/.nanostack"

echo
echo "===================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Custom Stack Examples runtime E2E: %d checks passed, 0 failed${NC}\n" "$PASS"
  exit 0
else
  printf "${RED}Custom Stack Examples runtime E2E: %d failed of %d total${NC}\n" "$FAIL" "$TOTAL"
  exit 1
fi
