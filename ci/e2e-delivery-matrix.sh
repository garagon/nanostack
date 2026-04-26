#!/usr/bin/env bash
# e2e-delivery-matrix.sh — Cell-by-cell coverage of the v1.0 delivery
# experience matrix. Complement to ci/e2e-user-flows.sh, not a
# replacement: e2e-user-flows simulates one full user journey end to
# end, this one tests every cell of the profile/run-mode/skip-trio
# matrix in isolation so a regression in any single cell is caught.
#
# Cells covered:
#   1. Claude + git              => profile=professional
#   2. Codex  + git              => profile=guided (instructions_only)
#   3. no git                    => profile=guided (local implies guided)
#   4. --run-mode report_only    => plan_approval=not_required
#   5. skip specialist (review+qa, review+security, qa+security) => commit blocked
#   6. full trio                 => commit unblocked
#   7. guided next-step          => no slash commands in user_message
#   8. professional next-step    => slash command in user_message
#   9. leaf symlink adversarial  => write guard blocks
#
# Usage:
#   ci/e2e-delivery-matrix.sh
#   ci/e2e-delivery-matrix.sh --filter profile
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

# /tmp/, not $TMPDIR — see ci/e2e-user-flows.sh for the rationale.
TMP_ROOT=$(mktemp -d /tmp/nanostack-matrix.XXXXXX)
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

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}did not expect: %s${NC}\n" "$needle"
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

# Each cell sets up its own project + NANOSTACK_STORE, runs assertions,
# tears down by overwriting NANOSTACK_STORE on the next cell. The trap
# wipes everything at exit.
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

# Mark a phase completed in session.json without going through the
# real save-artifact path. Cells 5 and 6 only care about the phase
# gate, not artifact freshness, so this stays intentionally minimal.
fake_complete() {
  local phase="$1"
  jq --arg p "$phase" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .phase_log += [{
      phase: $p, status: "completed",
      started_at: $date, started_epoch: 0,
      completed_at: $date, duration_seconds: 0,
      artifact: null
    }]
  ' "$NANOSTACK_STORE/session.json" > "$NANOSTACK_STORE/session.json.tmp"
  mv "$NANOSTACK_STORE/session.json.tmp" "$NANOSTACK_STORE/session.json"

  # save-artifact creates the artifact file the phase gate looks for.
  # Use the real save-artifact so the on-disk shape matches production.
  "$REPO/bin/save-artifact.sh" "$phase" \
    "{\"phase\":\"$phase\",\"summary\":{\"v\":1}}" >/dev/null 2>&1 || true
}

# ─── Cell 1: Claude + git => professional ─────────────────────────────

cell_claude_git_professional() {
  new_project "cell1"
  git init -q
  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development >/dev/null )
  local profile
  profile=$(jq -r .profile "$NANOSTACK_STORE/session.json")
  assert_eq "Claude+git resolves to professional" "professional" "$profile"
}

# ─── Cell 2: Codex + git => guided ────────────────────────────────────

cell_codex_git_guided() {
  new_project "cell2"
  git init -q
  ( export NANOSTACK_HOST=codex; "$REPO/bin/session.sh" init development >/dev/null )
  local profile
  profile=$(jq -r .profile "$NANOSTACK_STORE/session.json")
  assert_eq "Codex+git resolves to guided (instructions_only adapter)" "guided" "$profile"
}

# ─── Cell 3: no-git => guided/local ───────────────────────────────────

cell_no_git_guided() {
  new_project "cell3"
  # Intentionally no git init.
  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development >/dev/null )
  local profile
  profile=$(jq -r .profile "$NANOSTACK_STORE/session.json")
  assert_eq "no-git resolves to guided (local implies guided)" "guided" "$profile"
}

# ─── Cell 4: report_only => plan_approval=not_required ────────────────

cell_report_only_plan_approval() {
  new_project "cell4"
  git init -q
  "$REPO/bin/session.sh" init development --run-mode report_only >/dev/null
  local rm pa
  rm=$(jq -r .run_mode "$NANOSTACK_STORE/session.json")
  pa=$(jq -r .plan_approval "$NANOSTACK_STORE/session.json")
  assert_eq "run_mode is report_only"          "report_only"   "$rm"
  assert_eq "plan_approval forced to not_required" "not_required" "$pa"
}

# ─── Cell 5: skip-specialist combinations block ship ──────────────────
# The phase gate requires fresh artifacts for review, security, AND qa.
# Each two-of-three combination must still leave commit blocked.

cell_skip_specialist_blocks_ship() {
  local guard="$REPO/guard/bin/check-dangerous.sh"

  for combo in "review qa" "review security" "qa security"; do
    new_project "cell5-$(echo "$combo" | tr ' ' '-')"
    git init -q
    "$REPO/bin/session.sh" init development --autopilot >/dev/null
    for phase in $combo; do
      fake_complete "$phase"
    done
    assert_false "two of three ($combo): git commit still blocked" \
      "$guard" 'git commit -m "wip"'
  done
}

# ─── Cell 6: full trio releases ship ──────────────────────────────────

cell_full_trio_releases_ship() {
  new_project "cell6"
  git init -q
  "$REPO/bin/session.sh" init development --autopilot >/dev/null
  for phase in review security qa; do
    fake_complete "$phase"
  done
  assert_true "full review+security+qa: git commit unblocked" \
    "$REPO/guard/bin/check-dangerous.sh" 'git commit -m "ship"'
}

# ─── Cell 7: guided next-step has no slash commands ───────────────────
# next-step.sh --json reads .profile and shapes user_message
# accordingly. In guided, the message must read like a plain
# sentence — no "/review", no "/security", no "/ship".

cell_guided_next_step_no_slash() {
  new_project "cell7"
  git init -q
  "$REPO/bin/session.sh" init development --profile guided --autopilot >/dev/null
  local out msg
  out=$("$REPO/bin/next-step.sh" --json 2>/dev/null)
  msg=$(echo "$out" | jq -r .user_message)
  assert_eq "guided profile propagated"      "guided" "$(echo "$out" | jq -r .profile)"
  assert_not_contains "guided user_message has no /review"   "/review"   "$msg"
  assert_not_contains "guided user_message has no /security" "/security" "$msg"
  assert_not_contains "guided user_message has no /qa"       "/qa"       "$msg"
  assert_not_contains "guided user_message has no /ship"     "/ship"     "$msg"
}

# ─── Cell 8: professional next-step uses slash commands ──────────────

cell_professional_next_step_uses_slash() {
  new_project "cell8"
  git init -q
  "$REPO/bin/session.sh" init development --profile professional --autopilot >/dev/null
  local out msg
  out=$("$REPO/bin/next-step.sh" --json 2>/dev/null)
  msg=$(echo "$out" | jq -r .user_message)
  assert_eq "professional profile propagated" "professional" "$(echo "$out" | jq -r .profile)"
  # Empty post-build state suggests review next.
  assert_contains "professional user_message names /review" "/review" "$msg"
}

# ─── Cell 9: leaf symlink adversarial (post-PR C) ─────────────────────
# Backstop for the macOS BSD bypass. Lives here too so a regression in
# check-write.sh would fail this targeted matrix run, not only the
# longer e2e-user-flows.sh.

cell_leaf_symlink_blocked() {
  local proj="$TMP_ROOT/cell9"
  mkdir -p "$proj"
  cd "$proj"
  ln -sfn /etc/passwd "$proj/etc-passwd-leaf"
  assert_false "leaf symlink to /etc/passwd is blocked" \
    "$REPO/guard/bin/check-write.sh" "$proj/etc-passwd-leaf"
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Nanostack delivery matrix"
echo "========================="
echo "Tmp root: $TMP_ROOT"

cell claude_git_professional
cell codex_git_guided
cell no_git_guided
cell report_only_plan_approval
cell skip_specialist_blocks_ship
cell full_trio_releases_ship
cell guided_next_step_no_slash
cell professional_next_step_uses_slash
cell leaf_symlink_blocked

echo ""
echo "========================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Matrix summary: $PASS cells passed, 0 failed${NC}"
else
  printf "${RED}Matrix summary: $FAIL failed${NC} / $TOTAL total"
  printf "\nFailed cells:%s" "$FAILED_CELLS"
fi
[ "$SKIP" -gt 0 ] && printf " ${DIM}($SKIP skipped)${NC}"
echo ""

[ "$FAIL" -eq 0 ]
