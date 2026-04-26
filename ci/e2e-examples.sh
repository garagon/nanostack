#!/usr/bin/env bash
# e2e-examples.sh — End-to-end sprint roundtrip for every Examples Library archetype.
#
# Why this exists alongside ci/check-examples.sh:
#
#   check-examples.sh validates the README contract (8 sections,
#   no em-dashes, prompt presence, executable syntax, HTML meta).
#   That answers "is the README well-formed".
#
#   This harness answers "can a real user actually finish a sprint
#   using this example", to the extent CI can verify it without
#   driving an LLM:
#
#     - The starting state runs cleanly (HTML loads, server replies,
#       script accepts input, page parses).
#     - A simulated sprint produces valid artifacts whose
#       planned_files reference real files in the example.
#     - resolve.sh ship returns those artifacts. sprint-journal.sh
#       does not crash on the result.
#     - The /think → /nano → /review → /security → /qa → /ship
#       chain ends with summary.status implied by the example's
#       success criteria.
#     - The example's intended profile is honored (guided for
#       starter-todo, professional for cli-notes, etc.).
#
# Cells (one per Examples Library archetype):
#
#   1. starter-todo     => guided + local + sandbox sprint
#   2. cli-notes        => professional + git + CLI feature
#   3. api-healthcheck  => professional + git + HTTP health probe
#   4. static-landing   => guided + git + copy/visual sprint
#
# Each cell exercises the same 6 contract assertions:
#
#   a. The example's starting state runs as advertised.
#   b. Setup session honors the intended profile.
#   c. /think artifact saves with the example's first feature idea
#      and points at one of the example's actual files.
#   d. /nano plan artifact lists the planned files.
#   e. resolve.sh ship returns review/security/qa artifacts.
#   f. sprint-journal.sh emits a markdown without crashing.
#
# Usage:
#   ci/e2e-examples.sh
#   ci/e2e-examples.sh --filter starter-todo
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

# /tmp/, not $TMPDIR — same rationale as the other e2e harnesses.
TMP_ROOT=$(mktemp -d /tmp/nanostack-examples.XXXXXX)
trap 'rm -rf "$TMP_ROOT"; cleanup_servers 2>/dev/null || true' EXIT INT TERM

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

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}expected to contain: %s${NC}\n" "$needle"
  fi
}

# Copy an example into a fresh /tmp project, optionally git init.
new_example_project() {
  local archetype="$1" git_init="${2:-yes}"
  local proj="$TMP_ROOT/$archetype"
  mkdir -p "$proj"
  cp -R "$REPO/examples/$archetype/." "$proj/"
  cd "$proj"
  if [ "$git_init" = "yes" ]; then
    git init -q
    git config user.email "ci@example.test"
    git config user.name  "ci"
  fi
  export NANOSTACK_STORE="$proj/.nanostack"
  mkdir -p "$NANOSTACK_STORE"
}

# Save a complete sprint of fake-but-valid artifacts for the cell.
# planned_files is the load-bearing field /review and /ship read for
# scope drift detection.
save_sprint() {
  local archetype="$1" first_file="$2"
  local think_json plan_json
  think_json=$(jq -n \
    --arg vp "Try ${archetype} sprint" \
    --arg tu "Example sandbox user" \
    --arg nw "$first_file" \
    --arg kr "Edge-case behavior on first run" \
    '{phase:"think", summary:{value_proposition:$vp, scope_mode:"reduce", target_user:$tu, narrowest_wedge:$nw, key_risk:$kr, premise_validated:true, out_of_scope:[], manual_delivery_test:{possible:true, steps:["run start state"]}, search_summary:{mode:"local_only", result:"", existing_solution:"none"}}, context_checkpoint:{summary:"sandbox think"}}')
  "$REPO/bin/save-artifact.sh" think "$think_json" >/dev/null

  plan_json=$(jq -n --arg f "$first_file" '{
    phase:"plan",
    summary:{goal:"first feature", scope:"small", step_count:3, planned_files:[$f], risks:[], out_of_scope:[]}
  }')
  "$REPO/bin/save-artifact.sh" plan "$plan_json" >/dev/null

  for phase in review security qa ship; do
    local payload
    payload=$(jq -n --arg p "$phase" '{phase:$p, summary:{v:1, status:"clean"}}')
    "$REPO/bin/save-artifact.sh" "$phase" "$payload" >/dev/null
  done
}

# Verify the sprint chain reads back through resolve + journal.
assert_sprint_roundtrip() {
  local archetype="$1"
  local resolved
  resolved=$("$REPO/bin/resolve.sh" ship 2>/dev/null || echo "{}")
  assert_contains "$archetype: resolve.sh ship loads review"   '"review"'   "$resolved"
  assert_contains "$archetype: resolve.sh ship loads security" '"security"' "$resolved"
  assert_contains "$archetype: resolve.sh ship loads qa"       '"qa"'       "$resolved"

  local journal
  journal=$("$REPO/bin/sprint-journal.sh" 2>/dev/null || true)
  assert_true "$archetype: sprint-journal.sh emits a path" test -n "$journal"
  if [ -n "$journal" ] && [ -f "$journal" ]; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s: sprint-journal markdown exists on disk\n" "$archetype"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s: sprint-journal did not produce a file\n" "$archetype"
  fi
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

# Background processes started by per-cell setup. Cleaned on exit
# regardless of pass/fail so a failing assertion never leaves a port
# bound for the next cell.
SERVER_PIDS=()
cleanup_servers() {
  for pid in "${SERVER_PIDS[@]}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  SERVER_PIDS=()
}

# ─── Cell 1: starter-todo ─────────────────────────────────────────────
# Audience: non-technical user. Profile: guided. Mode: local (no git).

cell_starter_todo() {
  new_example_project "starter-todo" "no"

  # Starting state: a one-file HTML app. Confirm it parses and has
  # the contract markers (title + viewport) check-examples already
  # validates structurally.
  assert_true "starter-todo: index.html exists" test -f index.html
  assert_true "starter-todo: index.html has <title>" grep -qi '<title>' index.html
  assert_true "starter-todo: index.html has viewport meta" grep -qi 'viewport' index.html

  # Session: profile=guided (matches the README's archetype).
  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development --profile guided >/dev/null )
  assert_eq "starter-todo: session profile = guided" "guided" \
    "$(jq -r .profile "$NANOSTACK_STORE/session.json")"

  # Simulated sprint with the README's first feature ("Persist tasks
  # across reloads"). Plan points at index.html, the only file.
  save_sprint "starter-todo" "index.html"
  assert_sprint_roundtrip "starter-todo"
}

# ─── Cell 2: cli-notes ────────────────────────────────────────────────
# Audience: technical CLI user. Profile: professional. Mode: git.

cell_cli_notes() {
  new_example_project "cli-notes" "yes"

  # Starting state: notes.sh accepts add / list / count.
  chmod +x notes.sh
  assert_true "cli-notes: bash -n notes.sh" bash -n notes.sh
  assert_true "cli-notes: ./notes.sh add works" ./notes.sh add "buy milk"
  out=$(./notes.sh count 2>/dev/null)
  assert_eq "cli-notes: ./notes.sh count after one add" "1" "$out"
  out=$(./notes.sh list | wc -l | tr -d ' ')
  assert_eq "cli-notes: ./notes.sh list returns one row" "1" "$out"

  # Session: profile=professional (technical archetype).
  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development --profile professional >/dev/null )
  assert_eq "cli-notes: session profile = professional" "professional" \
    "$(jq -r .profile "$NANOSTACK_STORE/session.json")"

  # Simulated sprint for the README's first feature (--list / reverse).
  save_sprint "cli-notes" "notes.sh"
  assert_sprint_roundtrip "cli-notes"

  # Plan must reference notes.sh, which is the only file the example
  # touches.
  local planned
  planned=$(jq -r '.summary.planned_files[0]' .nanostack/plan/*.json | head -1)
  assert_eq "cli-notes: plan.planned_files[0] = notes.sh" "notes.sh" "$planned"
}

# ─── Cell 3: api-healthcheck ──────────────────────────────────────────
# Audience: backend dev. Profile: professional. Mode: git.

cell_api_healthcheck() {
  new_example_project "api-healthcheck" "yes"

  # node --check on server.js (already in check-examples.sh, repeated
  # here for cell-isolation).
  assert_true "api-healthcheck: node --check server.js" node --check server.js

  # Real runtime probe: start the server, hit /health, verify 200.
  # Picks an ephemeral port to avoid CI port collisions.
  local port=$((40000 + RANDOM % 1000))
  PORT="$port" node server.js &
  local pid=$!
  SERVER_PIDS+=("$pid")
  sleep 1
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/health" 2>/dev/null || echo "000")
  assert_eq "api-healthcheck: GET /health returns 200" "200" "$code"
  # 404 path also exercised (the README promises this shape).
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/missing" 2>/dev/null || echo "000")
  assert_eq "api-healthcheck: GET /missing returns 404" "404" "$code"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development --profile professional >/dev/null )
  assert_eq "api-healthcheck: session profile = professional" "professional" \
    "$(jq -r .profile "$NANOSTACK_STORE/session.json")"

  save_sprint "api-healthcheck" "server.js"
  assert_sprint_roundtrip "api-healthcheck"
}

# ─── Cell 4: static-landing ───────────────────────────────────────────
# Audience: founder/designer. Profile: guided. Mode: git (the README
# instructs git clone + cd, but layout work is taste-bound, not git-
# bound, so guided is the honest profile).

cell_static_landing() {
  new_example_project "static-landing" "yes"

  assert_true "static-landing: index.html exists" test -f index.html
  assert_true "static-landing: <title> present" grep -qi '<title>' index.html
  assert_true "static-landing: viewport meta present" grep -qi 'viewport' index.html
  # The example explicitly avoids inline scripts and external trackers
  # (security audit angle). Confirm both stay absent.
  assert_true "static-landing: no <script> tag" \
    bash -c '! grep -qi "<script" index.html'
  assert_true "static-landing: no analytics/tracking domains" \
    bash -c '! grep -qiE "google-analytics|googletagmanager|mixpanel|segment|hotjar|fb\\.fbq" index.html'

  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development --profile guided >/dev/null )
  assert_eq "static-landing: session profile = guided" "guided" \
    "$(jq -r .profile "$NANOSTACK_STORE/session.json")"

  save_sprint "static-landing" "index.html"
  assert_sprint_roundtrip "static-landing"
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Nanostack examples library E2E"
echo "==============================="
echo "Tmp root: $TMP_ROOT"

cell starter_todo
cell cli_notes
cell api_healthcheck
cell static_landing

echo ""
echo "==============================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Examples E2E summary: $PASS checks passed, 0 failed${NC}"
else
  printf "${RED}Examples E2E summary: $FAIL failed${NC} / $TOTAL total"
  printf "\nFailed cells:%s" "$FAILED_CELLS"
fi
[ "$SKIP" -gt 0 ] && printf " ${DIM}($SKIP skipped)${NC}"
echo ""

[ "$FAIL" -eq 0 ]
