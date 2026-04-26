#!/usr/bin/env bash
# e2e-think-flows.sh — Cell-by-cell coverage of the /think vNext
# contracts. Complement to ci/e2e-user-flows.sh and
# ci/e2e-delivery-matrix.sh. The static lint jobs in
# .github/workflows/lint.yml cover the structural assertions (file
# X mentions field Y); this harness exercises behavior end-to-end so
# a future skill rewrite that "still mentions the field" but actually
# misroutes it gets caught.
#
# Cells:
#   1. Structured artifact roundtrip — save via canonical mode, confirm
#      every required field is retrievable by jq, sprint-journal reads it,
#      resolve.sh plan returns its path.
#   2. Profile resolution: Codex+git => guided.
#   3. Profile resolution: Claude+git => professional.
#   4. Autopilot brief gate — complete brief returns true.
#   5. Autopilot brief gate — incomplete brief (missing target_user)
#      returns false; the spec promise is "stop, ask one question".
#   6. Preset no-dump — think/SKILL.md does not contain `cat
#      "$PRESET_FILE"` or the default.md cat (regression backstop on
#      top of the static lint).
#   7. Search privacy modes — reference doc declares the three modes
#      and the search_summary fields exist by name.
#
# Usage:
#   ci/e2e-think-flows.sh
#   ci/e2e-think-flows.sh --filter brief-gate
#
# Exit code: 0 on success, 1 if any cell failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FILTER=""
[ "${1:-}" = "--filter" ] && FILTER="${2:-}"

PASS=0
FAIL=0
SKIP=0
FAILED_CELLS=""

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

# /tmp/, not $TMPDIR — see ci/e2e-user-flows.sh for rationale.
TMP_ROOT=$(mktemp -d /tmp/nanostack-think.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

# ─── helpers ──────────────────────────────────────────────────────────

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

new_project() {
  local name="$1"
  local proj="$TMP_ROOT/$name"
  mkdir -p "$proj"
  cd "$proj"
  export NANOSTACK_STORE="$proj/.nanostack"
  mkdir -p "$NANOSTACK_STORE"
}

cell() {
  local name="$1"
  if [ -n "$FILTER" ] && ! echo "$name" | grep -qi "$FILTER"; then
    SKIP=$((SKIP+1))
    return
  fi
  local before_fail=$FAIL
  echo ""
  echo "[$name]"
  "cell_$name" || true
  if [ "$FAIL" -gt "$before_fail" ]; then
    FAILED_CELLS="$FAILED_CELLS $name"
  fi
}

# Build a structured think artifact JSON. Optional second arg can drop
# a field by setting it to empty (used by cell 5 to test the brief
# gate's failure path).
build_think_json() {
  local drop="${1:-}"
  local vp="Restore JSON backups in 2 minutes" tu="Solo developers" nw="CLI imports a JSON snapshot" kr="Format drift" pv=true
  case "$drop" in
    value_proposition) vp="" ;;
    target_user)       tu="" ;;
    narrowest_wedge)   nw="" ;;
    key_risk)          kr="" ;;
    premise_validated) pv=null ;;
  esac
  jq -n \
    --arg vp "$vp" --arg tu "$tu" --arg nw "$nw" --arg kr "$kr" \
    --argjson pv "$pv" \
    '{
      phase: "think",
      summary: {
        value_proposition: $vp,
        scope_mode: "reduce",
        target_user: $tu,
        narrowest_wedge: $nw,
        key_risk: $kr,
        premise_validated: $pv,
        out_of_scope: ["multi-file", "schema migrations"],
        manual_delivery_test: {possible: true, steps: ["run cli","verify"]},
        search_summary: {mode: "local_only", result: "no equivalent in repo", existing_solution: "none"}
      },
      context_checkpoint: {summary: "x", key_files: [], decisions_made: [], open_questions: []}
    }'
}

# Pure jq evaluation of the brief gate. Mirrors the snippet in
# think/SKILL.md Phase 6.6 so a regression in the doc shows up as a
# behavior change here.
brief_gate_pass() {
  local file="$1"
  jq -r '
    (.summary.value_proposition // "") != "" and
    (.summary.target_user        // "") != "" and
    (.summary.narrowest_wedge    // "") != "" and
    (.summary.key_risk           // "") != "" and
    (.summary.premise_validated // null) != null
  ' "$file"
}

# ─── Cell 1: structured artifact roundtrip ────────────────────────────

cell_structured_artifact_roundtrip() {
  new_project "cell1"
  git init -q
  "$REPO/bin/session.sh" init development >/dev/null

  local think_json
  think_json=$(build_think_json)
  "$REPO/bin/save-artifact.sh" think "$think_json" >/dev/null

  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_true "artifact saved at .nanostack/think/*.json" test -f "$artifact"

  for field in value_proposition scope_mode target_user narrowest_wedge key_risk premise_validated; do
    assert_true "jq retrieves .summary.$field" \
      jq -e ".summary.$field" "$artifact"
  done
  for field in out_of_scope manual_delivery_test search_summary; do
    assert_true "jq retrieves optional .summary.$field" \
      jq -e ".summary.$field" "$artifact"
  done

  # sprint-journal.sh smoke check — must not crash on the structured
  # artifact and must produce a journal file path.
  local journal
  journal=$("$REPO/bin/sprint-journal.sh" 2>/dev/null || true)
  assert_true "sprint-journal returns a path" test -n "$journal"
  if [ -n "$journal" ] && [ -f "$journal" ]; then
    PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    sprint-journal wrote a markdown file\n"
  else
    FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  sprint-journal did not produce a file\n"
  fi

  # resolve.sh plan returns the artifact PATH (not the parsed object);
  # that is the documented contract /nano consumes.
  local resolved_path
  resolved_path=$("$REPO/bin/resolve.sh" plan 2>/dev/null | jq -r '.upstream_artifacts.think // empty')
  assert_true "resolve.sh plan returns a think artifact path" test -n "$resolved_path"
  assert_true "resolved path is the saved artifact" test -f "$resolved_path"
}

# ─── Cell 2: Codex + git resolves to guided ───────────────────────────

cell_codex_git_guided() {
  new_project "cell2"
  git init -q
  ( export NANOSTACK_HOST=codex; "$REPO/bin/session.sh" init development >/dev/null )
  local profile
  profile=$(jq -r .profile "$NANOSTACK_STORE/session.json")
  assert_eq "Codex+git => guided (instructions_only adapter)" "guided" "$profile"
}

# ─── Cell 3: Claude + git resolves to professional ───────────────────

cell_claude_git_professional() {
  new_project "cell3"
  git init -q
  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development >/dev/null )
  local profile
  profile=$(jq -r .profile "$NANOSTACK_STORE/session.json")
  assert_eq "Claude+git => professional" "professional" "$profile"
}

# ─── Cell 4: brief gate passes on a complete brief ────────────────────

cell_brief_gate_complete() {
  new_project "cell4"
  git init -q
  "$REPO/bin/session.sh" init development --autopilot >/dev/null
  local think_json
  think_json=$(build_think_json)
  "$REPO/bin/save-artifact.sh" think "$think_json" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  local result
  result=$(brief_gate_pass "$artifact")
  assert_eq "complete brief: gate passes (true)" "true" "$result"
}

# ─── Cell 5: brief gate fails on incomplete brief ─────────────────────
# Spec: "/think --autopilot 'build something useful' should not
# advance to /nano". The gate is the deterministic test for that
# claim. We exercise it for each required field.

cell_brief_gate_incomplete() {
  for missing in value_proposition target_user narrowest_wedge key_risk premise_validated; do
    new_project "cell5-$missing"
    git init -q
    "$REPO/bin/session.sh" init development --autopilot >/dev/null
    local think_json
    think_json=$(build_think_json "$missing")
    "$REPO/bin/save-artifact.sh" think "$think_json" >/dev/null
    local artifact result
    artifact=$(ls .nanostack/think/*.json | head -1)
    result=$(brief_gate_pass "$artifact")
    assert_eq "missing $missing: gate refuses (false)" "false" "$result"
  done
}

# ─── Cell 6: preset no-dump (regression backstop) ─────────────────────
# The static lint already blocks this; the harness adds a behavior
# check that stays useful even if the lint job is renamed or moved.

cell_preset_no_dump() {
  if grep -qE 'cat[[:space:]]+"\$PRESET_FILE"' "$REPO/think/SKILL.md"; then
    FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  think/SKILL.md regressed to cat \$PRESET_FILE\n"
  else
    PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    no cat \$PRESET_FILE in skill\n"
  fi
  if grep -qE 'cat[[:space:]]+"\$HOME/\.claude/skills/nanostack/think/presets/default\.md"' "$REPO/think/SKILL.md"; then
    FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  think/SKILL.md regressed to cat default.md\n"
  else
    PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    no cat default.md in skill\n"
  fi
  if grep -q 'Preset:' "$REPO/think/SKILL.md"; then
    PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    headline form 'Preset:' present\n"
  else
    FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  headline form missing\n"
  fi
}

# ─── Cell 7: search privacy modes documented ─────────────────────────

cell_search_privacy_modes() {
  local doc="$REPO/think/references/search-before-building.md"
  for mode in local_only private public; do
    if grep -qE "\`?${mode}\`?" "$doc"; then
      PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    mode '%s' declared\n" "$mode"
    else
      FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  mode '%s' missing\n" "$mode"
    fi
  done
  for field in '"mode"' '"result"' '"existing_solution"'; do
    if grep -q "$field" "$doc"; then
      PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    search_summary field %s declared\n" "$field"
    else
      FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  search_summary field %s missing\n" "$field"
    fi
  done
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Nanostack /think vNext flows"
echo "============================"
echo "Tmp root: $TMP_ROOT"

cell structured_artifact_roundtrip
cell codex_git_guided
cell claude_git_professional
cell brief_gate_complete
cell brief_gate_incomplete
cell preset_no_dump
cell search_privacy_modes

echo ""
echo "============================"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}/think summary: $PASS checks passed, 0 failed${NC}"
else
  printf "${RED}/think summary: $FAIL failed${NC} / $TOTAL total"
  printf "\nFailed cells:%s" "$FAILED_CELLS"
fi
[ "$SKIP" -gt 0 ] && printf " ${DIM}($SKIP skipped)${NC}"
echo ""

[ "$FAIL" -eq 0 ]
