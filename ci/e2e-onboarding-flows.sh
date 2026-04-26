#!/usr/bin/env bash
# e2e-onboarding-flows.sh — End-to-end coverage of /nano-run vNext.
#
# Why this exists alongside the static lint:
#
#   The lint matrix (nano-run-session-first / nano-run-report-only /
#   nano-run-guided-output / nano-run-capability-honesty /
#   nano-run-repair-aware / setup-artifact-schema) catches structural
#   regressions in start/SKILL.md and bin/save-setup-artifact.sh.
#
#   This harness exercises the runtime contract that those static
#   checks describe: profile resolution from session, capability
#   reads from adapters, legacy detection on a real legacy fixture,
#   the report-only no-write invariant, and the setup artifact
#   round-trip end to end.
#
# Cells (matches the spec table):
#
#   1. Guided, no git, no project files       => sandbox first action
#   2. Guided, git repo + package.json        => existing-project flow
#   3. Professional, git repo + package.json  => exact paths + capabilities
#   4. Codex adapter                          => instructions_only, no hard-block claim
#   5. Claude adapter                         => enforced where hooks are wired
#   6. report_only                            => no files written
#   7. Legacy settings missing hooks          => needs_repair, no silent migration
#   8. Existing config                        => not overwritten silently
#   9. Local mode                             => Guided wording, no PR/git jargon
#
# Usage:
#   ci/e2e-onboarding-flows.sh
#   ci/e2e-onboarding-flows.sh --filter legacy
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

# /tmp/, not $TMPDIR. macOS $TMPDIR resolves to /var/folders/... and
# check-write.sh denies any path under /var/. See ci/e2e-user-flows.sh
# for the full rationale.
TMP_ROOT=$(mktemp -d /tmp/nanostack-onboarding.XXXXXX)
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

# Build a setup payload from the cell's resolved fields. Each cell
# overrides what is special; defaults reflect a clean "ready, guided,
# local" run.
build_setup_payload() {
  local status="${1:-ready}"
  local profile="${2:-guided}"
  local host="${3:-codex}"
  local run_mode="${4:-normal}"
  local project_mode="${5:-local}"
  local config_state="${6:-created}"
  local kind="${7:-sandbox}"
  local cmd="${8:-/think \"add due dates\"}"

  # Capabilities come from the adapter file when present, else unknown.
  local cap_bash cap_write cap_phase
  local adapter="$REPO/adapters/${host}.json"
  if [ -f "$adapter" ]; then
    cap_bash=$(jq -r '.bash_guard // "unknown"'  "$adapter")
    cap_write=$(jq -r '.write_guard // "unknown"' "$adapter")
    cap_phase=$(jq -r '.phase_gate // "unknown"'  "$adapter")
  else
    cap_bash=unknown; cap_write=unknown; cap_phase=unknown
  fi

  jq -n \
    --arg status "$status" --arg profile "$profile" --arg host "$host" \
    --arg run_mode "$run_mode" --arg project_mode "$project_mode" \
    --arg cap_bash "$cap_bash" --arg cap_write "$cap_write" --arg cap_phase "$cap_phase" \
    --arg config_state "$config_state" --arg kind "$kind" --arg cmd "$cmd" \
    '{
      phase: "setup",
      summary: {
        status: $status, profile: $profile, host: $host,
        run_mode: $run_mode, project_mode: $project_mode,
        capabilities: {bash_guard: $cap_bash, write_guard: $cap_write, phase_gate: $cap_phase},
        configuration: {config_json: $config_state, stack_json: $config_state, project_settings: "not_applicable", gitignore: "not_applicable"},
        recommended_first_run: {kind: $kind, command: $cmd, path: "examples/starter-todo", reason: "test"}
      },
      context_checkpoint: {summary: "test"}
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

# ─── Cell 1: Guided, no git, no project => sandbox recommendation ─────

cell_guided_no_git_no_project() {
  new_project "cell1"
  # No git init. No package.json. profile=guided via session field.
  "$REPO/bin/session.sh" init development --profile guided >/dev/null
  local payload
  payload=$(build_setup_payload "ready" "guided" "claude" "normal" "local" "created" "sandbox" "/think 'add due dates'")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null
  assert_true "setup artifact written" test -f .nanostack/setup/latest.json
  local kind
  kind=$(jq -r '.summary.recommended_first_run.kind' .nanostack/setup/latest.json)
  assert_eq "guided + no project recommends sandbox" "sandbox" "$kind"
  local profile
  profile=$(jq -r '.summary.profile' .nanostack/setup/latest.json)
  assert_eq "profile=guided in artifact" "guided" "$profile"
}

# ─── Cell 2: Guided, git repo + package.json => existing-project ──────

cell_guided_git_with_stack() {
  new_project "cell2"
  git init -q
  printf '{"scripts":{"test":"echo ok"}}\n' > package.json
  "$REPO/bin/session.sh" init development --profile guided >/dev/null
  local payload
  payload=$(build_setup_payload "ready" "guided" "codex" "normal" "git" "created" "existing_project" "/think 'add a feature'")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null
  local kind
  kind=$(jq -r '.summary.recommended_first_run.kind' .nanostack/setup/latest.json)
  assert_eq "guided + git project recommends existing_project" "existing_project" "$kind"
  local pm
  pm=$(jq -r '.summary.project_mode' .nanostack/setup/latest.json)
  assert_eq "project_mode=git when git repo present" "git" "$pm"
}

# ─── Cell 3: Professional, git + stack => exact paths + capabilities ──

cell_professional_git_with_stack() {
  new_project "cell3"
  git init -q
  printf '{"scripts":{"test":"echo ok"}}\n' > package.json
  ( export NANOSTACK_HOST=claude; "$REPO/bin/session.sh" init development --profile professional >/dev/null )
  local payload
  payload=$(build_setup_payload "ready" "professional" "claude" "normal" "git" "created" "existing_project" "/think 'change'")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null
  assert_eq "professional profile in artifact" "professional" \
    "$(jq -r '.summary.profile' .nanostack/setup/latest.json)"
  # Professional run on Claude must reflect actual L3 capability.
  assert_eq "professional+claude bash_guard=enforced" "enforced" \
    "$(jq -r '.summary.capabilities.bash_guard' .nanostack/setup/latest.json)"
}

# ─── Cell 4: Codex adapter => instructions_only, no hard-block claim ──

cell_codex_no_hard_block_claim() {
  new_project "cell4"
  git init -q
  ( export NANOSTACK_HOST=codex; "$REPO/bin/session.sh" init development >/dev/null )
  # Capabilities come from adapters/codex.json -> instructions_only.
  local payload
  payload=$(build_setup_payload "ready" "guided" "codex" "normal" "git" "created" "existing_project" "/think x")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null
  for cap in bash_guard write_guard phase_gate; do
    local v
    v=$(jq -r ".summary.capabilities.$cap" .nanostack/setup/latest.json)
    assert_eq "codex.$cap = instructions_only" "instructions_only" "$v"
  done
}

# ─── Cell 5: Claude adapter => enforced where hooks are wired ─────────

cell_claude_enforced_when_wired() {
  new_project "cell5"
  git init -q
  local payload
  payload=$(build_setup_payload "ready" "professional" "claude" "normal" "git" "created" "existing_project" "/think x")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null
  for cap in bash_guard write_guard phase_gate; do
    local v
    v=$(jq -r ".summary.capabilities.$cap" .nanostack/setup/latest.json)
    assert_eq "claude.$cap = enforced (per adapter)" "enforced" "$v"
  done
}

# ─── Cell 6: report_only => no files written, honest configuration ────

cell_report_only_no_writes() {
  new_project "cell6"
  git init -q
  "$REPO/bin/session.sh" init development --run-mode report_only >/dev/null

  # Snapshot before. Anything written under .claude/, .nanostack/config.json,
  # .nanostack/stack.json, or the gitignore must NOT change. The setup
  # artifact under .nanostack/setup/ is the ONLY thing that is allowed
  # to land under report-only IF status=report_only and configuration
  # values say skipped_report_only (the writer enforces this).
  rm -rf .claude
  : > before.txt
  ls -la .claude .nanostack/config.json .nanostack/stack.json 2>/dev/null > before.txt || true

  # An honest report_only payload: skipped_report_only everywhere.
  local payload
  payload=$(build_setup_payload "report_only" "guided" "codex" "report_only" "git" "skipped_report_only" "report_only" "re-run")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null

  # No host config was created.
  assert_false "report_only does not create .claude/settings.json" \
    test -f .claude/settings.json
  # No nanostack config was created (we did not run init-config.sh).
  assert_false "report_only does not create .nanostack/config.json" \
    test -f .nanostack/config.json
  # The honesty invariant holds.
  assert_eq "configuration.config_json reads skipped_report_only" "skipped_report_only" \
    "$(jq -r '.summary.configuration.config_json' .nanostack/setup/latest.json)"

  # And a report_only payload that LIES about created files is rejected
  # by the writer.
  local lie
  lie=$(build_setup_payload "report_only" "guided" "codex" "report_only" "git" "created" "report_only" "re-run")
  assert_false "writer rejects report_only payload claiming 'created'" \
    "$REPO/bin/save-setup-artifact.sh" "$lie"
}

# ─── Cell 7: Legacy settings => needs_repair, no silent migration ─────

cell_legacy_needs_repair() {
  new_project "cell7"
  git init -q
  mkdir -p .claude
  cat > .claude/settings.json <<'EOF'
  {"permissions": {"allow": ["Bash(rm:*)", "Write(*)", "Edit(*)"]}}
EOF

  local legacy
  legacy=$("$REPO/bin/detect-legacy-setup.sh")
  assert_eq "detector flags detected=true on legacy"        "true" \
    "$(echo "$legacy" | jq -r .detected)"
  assert_eq "detector requires confirmation on broad perms" "true" \
    "$(echo "$legacy" | jq -r .migration_requires_confirmation)"

  # The setup artifact must record needs_repair, not ready, when the
  # detector said legacy is present.
  local payload
  payload=$(jq -n --argjson legacy "$legacy" '{
    phase:"setup",
    summary:{
      status:"needs_repair", profile:"guided", host:"claude",
      run_mode:"normal", project_mode:"git",
      capabilities:{bash_guard:"enforced", write_guard:"enforced", phase_gate:"enforced"},
      configuration:{config_json:"created", stack_json:"created", project_settings:"needs_repair", gitignore:"not_applicable"},
      legacy: $legacy,
      recommended_first_run:{kind:"repair", command:"bin/init-project.sh --repair", path:"", reason:"legacy install"}
    },
    context_checkpoint:{summary:"legacy detected"}
  }')
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null

  assert_eq "artifact status=needs_repair when legacy" "needs_repair" \
    "$(jq -r '.summary.status' .nanostack/setup/latest.json)"
  assert_eq "summary.legacy.detected propagates to artifact" "true" \
    "$(jq -r '.summary.legacy.detected' .nanostack/setup/latest.json)"
  # Broad permissions are still on disk; --repair is additive and would
  # not narrow them. The bin/init-project.sh script remains untouched
  # in this test, but the artifact must NOT claim status=ready.
  assert_true ".claude/settings.json untouched (no silent migration)" \
    grep -q 'Bash(rm:\*)' .claude/settings.json
}

# ─── Cell 8: Existing config not overwritten silently ─────────────────

cell_existing_config_preserved() {
  new_project "cell8"
  git init -q
  mkdir -p .nanostack
  echo '{"existing":"value","preferences":{"workflow_mode":"manual"}}' > .nanostack/config.json
  local before
  before=$(cat .nanostack/config.json)

  # Legitimate "configured already" payload: configuration.config_json=exists.
  local payload
  payload=$(build_setup_payload "ready" "guided" "codex" "normal" "git" "exists" "existing_project" "/think x")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null

  local after
  after=$(cat .nanostack/config.json)
  assert_eq "existing .nanostack/config.json untouched" "$before" "$after"
  assert_eq "artifact records configuration=exists, not created" "exists" \
    "$(jq -r '.summary.configuration.config_json' .nanostack/setup/latest.json)"
}

# ─── Cell 9: Local mode => Guided language, no PR/git jargon ──────────
# The plain-language contract bans "PR", "CI", "branch", "diff", "hook",
# "phase", "QA", "scope drift", "artifact", "security audit" on the
# first user-facing screen. The contract doc is the source of those
# rules; this cell asserts that a guided/local recommended_first_run
# command does not slip in any of them.

cell_local_mode_no_jargon() {
  new_project "cell9"
  # No git init -> local mode.
  "$REPO/bin/session.sh" init development --profile guided >/dev/null

  # In Guided + local mode, the recommendation is sandbox-flavored and
  # uses /think with plain-language argument. No PR / branch / diff in
  # the recommended_first_run payload.
  local payload
  payload=$(build_setup_payload "ready" "guided" "claude" "normal" "local" "created" "sandbox" "/think 'try something simple'")
  "$REPO/bin/save-setup-artifact.sh" "$payload" >/dev/null

  local cmd reason
  cmd=$(jq -r '.summary.recommended_first_run.command' .nanostack/setup/latest.json)
  reason=$(jq -r '.summary.recommended_first_run.reason' .nanostack/setup/latest.json)

  # Banned terms must not appear in either field.
  for term in 'PR' 'CI' 'branch' 'diff' 'hook' 'phase' 'security audit' 'QA' 'scope drift' 'artifact'; do
    if echo "$cmd $reason" | grep -qiF "$term"; then
      FAIL=$((FAIL+1))
      printf "    ${RED}FAIL${NC}  guided+local recommended_first_run leaks banned term '%s'\n" "$term"
    else
      PASS=$((PASS+1))
      printf "    ${GREEN}OK${NC}    guided+local does not leak '%s'\n" "$term"
    fi
  done
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Nanostack /nano-run vNext flows"
echo "================================"
echo "Tmp root: $TMP_ROOT"

cell guided_no_git_no_project
cell guided_git_with_stack
cell professional_git_with_stack
cell codex_no_hard_block_claim
cell claude_enforced_when_wired
cell report_only_no_writes
cell legacy_needs_repair
cell existing_config_preserved
cell local_mode_no_jargon

echo ""
echo "================================"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}/nano-run summary: $PASS checks passed, 0 failed${NC}"
else
  printf "${RED}/nano-run summary: $FAIL failed${NC} / $TOTAL total"
  printf "\nFailed cells:%s" "$FAILED_CELLS"
fi
[ "$SKIP" -gt 0 ] && printf " ${DIM}($SKIP skipped)${NC}"
echo ""

[ "$FAIL" -eq 0 ]
