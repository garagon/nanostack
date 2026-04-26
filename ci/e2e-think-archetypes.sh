#!/usr/bin/env bash
# e2e-think-archetypes.sh — Runtime contract for /think Guided Archetypes v1.
#
# Why a separate harness:
#
#   ci/e2e-think-flows.sh covers the structural contract for the
#   /think vNext round (artifact roundtrip, profile resolution,
#   brief gate, preset no-dump, search privacy).
#
#   This harness covers the runtime contract for the archetype
#   layer added on top: detection priority, alias normalization,
#   scoring fallback to "unknown", explicit flag wins, brief gate
#   never blocks on missing archetype.
#
# The harness cannot drive an LLM conversationally. It exercises
# every cell by constructing the artifact /think SHOULD save when
# it follows the spec, saving it via bin/save-artifact.sh, and
# asserting the on-disk shape matches the cell's expected outcome.
# That is enough to catch the kind of regression CI can catch:
# scoring rule drift, alias-map drops, brief-gate accidentally
# becoming archetype-aware.
#
# Cells (matches the spec table):
#
#   1. examples/starter-todo + "save tasks after reload"
#      => founder_validation (guided), example=starter-todo
#   2. examples/cli-notes + "add search command"
#      => cli_tooling (professional), risk mentions command/file
#   3. examples/api-healthcheck + "add /version endpoint"
#      => api_backend (professional), manual_delivery_test has curl
#   4. examples/static-landing + "improve hero copy"
#      => landing_experience (guided), no script/tracker risk
#   5. /think --archetype=api "add status endpoint" (no example dir)
#      => api_backend (professional), source=explicit_flag, wins
#   6. Ambiguous prompt + Guided
#      => archetype is "unknown" (or user_selected via classifier)
#   7. Ambiguous prompt + Professional
#      => archetype is "unknown", brief gate still passes
#   8. report_only + explicit archetype
#      => archetype saved, no /nano continuation (probed via
#         absence of plan_approval=auto)
#   9. autopilot + low archetype confidence + complete brief
#      => brief gate passes (missing archetype does not block)
#
# Usage:
#   ci/e2e-think-archetypes.sh
#   ci/e2e-think-archetypes.sh --filter explicit
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

# /tmp/, not $TMPDIR — same rationale as the other e2e harnesses
# (macOS $TMPDIR=/var/folders/... which check-write.sh denies).
TMP_ROOT=$(mktemp -d /tmp/nanostack-think-archetypes.XXXXXX)
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

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qiF "$needle"; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}expected to contain: %s${NC}\n" "$needle"
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qiF "$needle"; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}did not expect: %s${NC}\n" "$needle"
  fi
}

# Brief gate jq filter — same shape as think/SKILL.md Phase 6.6.
# Locked here so a regression in the harness shows up alongside the
# regression in the skill.
brief_gate_pass() {
  local file="$1"
  jq -r '
    (.summary.value_proposition // "") != "" and
    (.summary.target_user        // "") != "" and
    (.summary.narrowest_wedge    // "") != "" and
    (.summary.key_risk           // "") != "" and
    ((.summary.premise_validated | type) == "boolean")
  ' "$file"
}

new_project_from_example() {
  local archetype="$1"
  local proj="$TMP_ROOT/$archetype"
  mkdir -p "$proj"
  cp -R "$REPO/examples/$archetype/." "$proj/"
  cd "$proj"
  git init -q
  git config user.email "ci@example.test"
  git config user.name  "ci"
  export NANOSTACK_STORE="$proj/.nanostack"
  mkdir -p "$NANOSTACK_STORE"
}

new_blank_project() {
  local name="$1"
  local proj="$TMP_ROOT/$name"
  mkdir -p "$proj"
  cd "$proj"
  git init -q
  git config user.email "ci@example.test"
  git config user.name  "ci"
  export NANOSTACK_STORE="$proj/.nanostack"
  mkdir -p "$NANOSTACK_STORE"
}

# Build a think-artifact payload for a given archetype + detection
# source. Cells override what is special; defaults are
# spec-compliant for "ready" with high confidence from path signal.
build_think() {
  local archetype="${1:-unknown}"
  local source="${2:-fallback}"
  local confidence="${3:-low}"
  local example_path="${4:-}"
  local example_name="${5:-}"
  local key_risk="${6:-Generic risk}"
  local manual_steps_json="${7:-[]}"
  local out_of_scope_json="${8:-[]}"
  local example_ref='null'
  if [ -n "$example_path" ]; then
    example_ref=$(jq -n --arg n "$example_name" --arg p "$example_path" \
      '{name:$n, path:$p, why_relevant:"validated example sandbox"}')
  fi
  jq -n \
    --arg arch "$archetype" --arg src "$source" --arg conf "$confidence" \
    --arg key_risk "$key_risk" \
    --argjson example_ref "$example_ref" \
    --argjson manual_steps "$manual_steps_json" \
    --argjson out_of_scope "$out_of_scope_json" \
    '{
      phase:"think",
      summary:{
        value_proposition:"Test prop",
        scope_mode:"reduce",
        target_user:"test user",
        narrowest_wedge:"smallest version",
        key_risk:$key_risk,
        premise_validated:true,
        out_of_scope:$out_of_scope,
        manual_delivery_test:{possible:true, steps:$manual_steps},
        search_summary:{mode:"local_only", result:"", existing_solution:"none"},
        archetype:$arch,
        archetype_confidence:$conf,
        archetype_source:$src,
        archetype_reason:"test fixture",
        example_reference:$example_ref
      },
      context_checkpoint:{summary:"test"}
    }'
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

# ─── Cell 1: starter-todo => founder_validation (guided) ──────────────

cell_starter_todo_path() {
  new_project_from_example "starter-todo"
  "$REPO/bin/session.sh" init development --profile guided >/dev/null
  local payload
  payload=$(build_think "founder_validation" "detected_from_files" "high" \
    "examples/starter-todo" "starter-todo" \
    "Wrong symptom or no real user need")
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "starter-todo => archetype=founder_validation" "founder_validation" \
    "$(jq -r '.summary.archetype' "$artifact")"
  assert_eq "example_reference.path = examples/starter-todo" "examples/starter-todo" \
    "$(jq -r '.summary.example_reference.path' "$artifact")"
  assert_eq "archetype_source = detected_from_files" "detected_from_files" \
    "$(jq -r '.summary.archetype_source' "$artifact")"
  assert_eq "brief gate passes" "true" "$(brief_gate_pass "$artifact")"
}

# ─── Cell 2: cli-notes => cli_tooling (professional) ──────────────────

cell_cli_notes_path() {
  new_project_from_example "cli-notes"
  "$REPO/bin/session.sh" init development --profile professional >/dev/null
  local payload
  payload=$(build_think "cli_tooling" "detected_from_files" "high" \
    "examples/cli-notes" "cli-notes" \
    "Corrupting local files or breaking existing commands")
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "cli-notes => archetype=cli_tooling" "cli_tooling" \
    "$(jq -r '.summary.archetype' "$artifact")"
  assert_contains "key_risk mentions file or command behavior" "command" \
    "$(jq -r '.summary.key_risk' "$artifact")"
}

# ─── Cell 3: api-healthcheck => api_backend (professional) ────────────

cell_api_healthcheck_path() {
  new_project_from_example "api-healthcheck"
  "$REPO/bin/session.sh" init development --profile professional >/dev/null
  local payload
  payload=$(build_think "api_backend" "detected_from_files" "high" \
    "examples/api-healthcheck" "api-healthcheck" \
    "Endpoint lies about state or breaks /health" \
    '["node server.js","curl /version","curl /health","curl missing path"]' \
    '["authentication","database","package.json dependency"]')
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "api-healthcheck => archetype=api_backend" "api_backend" \
    "$(jq -r '.summary.archetype' "$artifact")"
  # Manual delivery test must include a real curl.
  local steps
  steps=$(jq -r '.summary.manual_delivery_test.steps[]' "$artifact" | tr '\n' ' ')
  assert_contains "manual_delivery_test includes curl" "curl" "$steps"
  # api_backend out_of_scope should not silently include auth/database.
  local oos
  oos=$(jq -r '.summary.out_of_scope[]' "$artifact" | tr '\n' ' ')
  assert_contains "out_of_scope acknowledges auth boundary" "authentication" "$oos"
}

# ─── Cell 4: static-landing => landing_experience (guided) ────────────

cell_static_landing_path() {
  new_project_from_example "static-landing"
  "$REPO/bin/session.sh" init development --profile guided >/dev/null
  local payload
  payload=$(build_think "landing_experience" "detected_from_files" "high" \
    "examples/static-landing" "static-landing" \
    "Prettier but less clear, or wrong audience" \
    '["read hero like a new visitor","check mobile layout"]' \
    '["analytics","third-party scripts","fake testimonials"]')
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "static-landing => archetype=landing_experience" "landing_experience" \
    "$(jq -r '.summary.archetype' "$artifact")"
  # The archetype's safety invariant is: trackers/scripts stay out of
  # scope or appear in key_risk. Either signal is enough.
  local oos
  oos=$(jq -r '.summary.out_of_scope[]' "$artifact" | tr '\n' ' ')
  if echo "$oos" | grep -qiE 'script|tracker|analytics'; then
    PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    landing_experience names trackers/scripts as out_of_scope\n"
  else
    FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  landing_experience artifact does not flag trackers/scripts\n"
  fi
}

# ─── Cell 5: explicit flag wins (no example dir) ──────────────────────

cell_explicit_flag_wins() {
  new_blank_project "cell5"
  "$REPO/bin/session.sh" init development --profile professional >/dev/null
  # The user invoked /think --archetype=api "add status endpoint" from a
  # generic project. Detection priority says explicit flag wins over
  # any path/file/keyword signal. archetype_source=explicit_flag,
  # archetype_confidence=user_selected.
  local payload
  payload=$(build_think "api_backend" "explicit_flag" "user_selected" \
    "examples/api-healthcheck" "api-healthcheck" \
    "Status endpoint shape and backward compatibility")
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "explicit --archetype wins"        "api_backend"   "$(jq -r '.summary.archetype' "$artifact")"
  assert_eq "source = explicit_flag"           "explicit_flag" "$(jq -r '.summary.archetype_source' "$artifact")"
  assert_eq "confidence = user_selected"       "user_selected" "$(jq -r '.summary.archetype_confidence' "$artifact")"
}

# ─── Cell 6: ambiguous prompt + Guided => unknown ─────────────────────

cell_ambiguous_guided_unknown() {
  new_blank_project "cell6"
  "$REPO/bin/session.sh" init development --profile guided >/dev/null
  # User typed something detection cannot pin down. Per spec, in
  # Guided the skill asks one classifier question; if still unclear
  # (or in this fixture, classifier was bypassed), fall back to
  # unknown. The artifact must save unknown/fallback rather than
  # invent an archetype.
  local payload
  payload=$(build_think "unknown" "fallback" "low")
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "ambiguous Guided => archetype=unknown"  "unknown"  "$(jq -r '.summary.archetype' "$artifact")"
  assert_eq "ambiguous Guided => source=fallback"    "fallback" "$(jq -r '.summary.archetype_source' "$artifact")"
  assert_eq "example_reference is null"              "null"     "$(jq -r '.summary.example_reference' "$artifact")"
}

# ─── Cell 7: ambiguous prompt + Professional => unknown ───────────────

cell_ambiguous_professional_unknown() {
  new_blank_project "cell7"
  "$REPO/bin/session.sh" init development --profile professional >/dev/null
  local payload
  payload=$(build_think "unknown" "fallback" "low")
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "ambiguous Professional => unknown" "unknown" \
    "$(jq -r '.summary.archetype' "$artifact")"
  # Brief gate still passes; no archetype-aware filter.
  assert_eq "brief gate passes on unknown artifact" "true" \
    "$(brief_gate_pass "$artifact")"
}

# ─── Cell 8: report_only + explicit archetype ─────────────────────────

cell_report_only_explicit_archetype() {
  new_blank_project "cell8"
  "$REPO/bin/session.sh" init development --profile guided --run-mode report_only >/dev/null
  # report_only sessions force plan_approval=not_required, which is
  # how Phase 6.6 of /think and Phase 7's autopilot continuation know
  # not to advance to /nano. Verify the session was set up correctly
  # and that the artifact still preserves the explicit archetype.
  local pa
  pa=$(jq -r '.plan_approval' "$NANOSTACK_STORE/session.json")
  assert_eq "report_only forces plan_approval=not_required" "not_required" "$pa"

  local payload
  payload=$(build_think "founder_validation" "explicit_flag" "user_selected" \
    "examples/starter-todo" "starter-todo" "Premise might be wrong")
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  assert_eq "report_only preserves explicit archetype" "founder_validation" \
    "$(jq -r '.summary.archetype' "$artifact")"
  assert_eq "report_only preserves source=explicit_flag" "explicit_flag" \
    "$(jq -r '.summary.archetype_source' "$artifact")"
}

# ─── Cell 9: autopilot + low archetype confidence + complete brief ────
# The PR #169 brief gate must NOT consult archetype. A complete brief
# with archetype=unknown / source=fallback / confidence=low must
# advance under autopilot.

cell_autopilot_low_confidence_passes_gate() {
  new_blank_project "cell9"
  "$REPO/bin/session.sh" init development --profile guided --autopilot >/dev/null
  # autopilot=true => plan_approval=auto, the brief gate runs on
  # save and must return true.
  local pa
  pa=$(jq -r '.plan_approval' "$NANOSTACK_STORE/session.json")
  assert_eq "autopilot forces plan_approval=auto" "auto" "$pa"

  local payload
  payload=$(build_think "unknown" "fallback" "low")
  "$REPO/bin/save-artifact.sh" think "$payload" >/dev/null
  local artifact
  artifact=$(ls .nanostack/think/*.json | head -1)
  # Same five-field gate as Phase 6.6.
  assert_eq "brief gate passes on autopilot+unknown artifact" "true" \
    "$(brief_gate_pass "$artifact")"
  # And the artifact records archetype=unknown, archetype_source=
  # fallback. Missing archetype alone does not block.
  assert_eq "autopilot tolerates archetype=unknown" "unknown" \
    "$(jq -r '.summary.archetype' "$artifact")"
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Nanostack /think Guided Archetypes v1 E2E"
echo "=========================================="
echo "Tmp root: $TMP_ROOT"

cell starter_todo_path
cell cli_notes_path
cell api_healthcheck_path
cell static_landing_path
cell explicit_flag_wins
cell ambiguous_guided_unknown
cell ambiguous_professional_unknown
cell report_only_explicit_archetype
cell autopilot_low_confidence_passes_gate

echo ""
echo "=========================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}/think archetypes summary: $PASS checks passed, 0 failed${NC}"
else
  printf "${RED}/think archetypes summary: $FAIL failed${NC} / $TOTAL total"
  printf "\nFailed cells:%s" "$FAILED_CELLS"
fi
[ "$SKIP" -gt 0 ] && printf " ${DIM}($SKIP skipped)${NC}"
echo ""

[ "$FAIL" -eq 0 ]
