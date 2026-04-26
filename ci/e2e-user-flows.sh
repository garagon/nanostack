#!/usr/bin/env bash
# e2e-user-flows.sh — End-to-end simulation of real user flows.
#
# Why this exists: tests/run.sh covers individual scripts in isolation,
# but it does not catch state-leak bugs that surface across the install
# > setup > sprint > phase-gate > ship pipeline. The 1.0 retro found
# one such bug (current_phase did not clear after phase-complete, so
# /qa held its read lock and blocked git commit forever). Running the
# real flow end-to-end is the only way to catch a regression like that.
#
# Isolation: every flow uses a fresh HOME and project dir under a
# trapped tmp root. Nothing touches the developer's real ~/.claude/
# install, real ~/.nanostack/, or any state outside the trap.
#
# Usage:
#   ci/e2e-user-flows.sh                run every flow
#   ci/e2e-user-flows.sh --filter sprint  run flows whose name matches
#
# Exit code: 0 on success, 1 if any flow failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FILTER="${2:-}"
[ "${1:-}" = "--filter" ] && FILTER="${2:-}"

PASS=0
FAIL=0
SKIP=0
FAILED_FLOWS=""

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

# ─── tmp root with cleanup trap ────────────────────────────────────────
# Use /tmp/ explicitly instead of $TMPDIR. On macOS $TMPDIR resolves to
# /var/folders/..., and check-write.sh correctly denies any path under
# /var/, which would make every write-guard "allow" assertion in flow 4
# fail with a false positive about the guard. /tmp resolves to
# /private/tmp on macOS — outside /var/ — and is also recognized by
# init-project.sh's narrow rm rule.
TMP_ROOT=$(mktemp -d /tmp/nanostack-e2e.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

# ─── assertion helpers ────────────────────────────────────────────────
# Each helper increments PASS or FAIL and prints a one-line result. The
# message is the assertion name; if it fails, the helper also prints a
# short diagnostic so the developer can read the cause without re-running.

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

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s\n" "$name"
    printf "          ${DIM}expected NOT to contain: %s${NC}\n" "$needle"
  fi
}

# Each flow opens its own scope. Failures inside do not abort the run.
flow() {
  local name="$1"
  if [ -n "$FILTER" ] && ! echo "$name" | grep -qi "$FILTER"; then
    SKIP=$((SKIP+1))
    return
  fi
  local before_fail=$FAIL
  echo ""
  echo "[$name]"
  "flow_$name" || true
  if [ "$FAIL" -gt "$before_fail" ]; then
    FAILED_FLOWS="$FAILED_FLOWS $name"
  fi
}

# ─── Flow 1: install isolated ─────────────────────────────────────────
# Stand up a fake HOME, link the live repo as the install target, run
# setup --host claude and setup --host codex. Verify the layouts each
# host expects without touching the real ~/.claude/ install.

flow_install_isolated() {
  local home="$TMP_ROOT/install/home"
  mkdir -p "$home/.claude/skills"
  ln -sfn "$REPO" "$home/.claude/skills/nanostack"

  # setup --host claude
  ( export HOME="$home"; cd "$home/.claude/skills/nanostack" && ./setup --host claude >/dev/null 2>&1 )
  assert_true "claude: nanostack symlink resolves" test -d "$home/.claude/skills/nanostack"
  assert_true "claude: think skill linked"          test -L "$home/.claude/skills/think"
  assert_true "claude: nano skill linked"           test -L "$home/.claude/skills/nano"
  assert_true "claude: ship skill linked"           test -L "$home/.claude/skills/ship"

  # setup --host codex creates a separate skills folder.
  ( export HOME="$home"; cd "$home/.claude/skills/nanostack" && ./setup --host codex >/dev/null 2>&1 )
  assert_true "codex: skills root created"      test -d "$home/.codex/skills"
  assert_true "codex: per-skill symlinks created" \
    bash -c "ls '$home/.codex/skills/' 2>/dev/null | grep -q '^nanostack-'"

  # No project registry should be created without explicit opt-in.
  assert_false "no projects registry without opt-in" \
    test -e "$home/.nanostack/projects.json"
  assert_false "no projects directory without opt-in" \
    test -d "$home/.nanostack/projects"
}

# ─── Flow 2: fresh git project ────────────────────────────────────────
# Brand-new repo + init-project.sh writes a hooked settings.json with
# the narrow rm rules. nano-doctor reports both guards present.

flow_fresh_git_project() {
  local proj="$TMP_ROOT/fresh-project"
  mkdir -p "$proj"
  ( cd "$proj" && git init -q )

  ( cd "$proj" && "$REPO/bin/init-project.sh" >/dev/null 2>&1 )
  assert_true "settings.json created" test -f "$proj/.claude/settings.json"

  local s
  s=$(cat "$proj/.claude/settings.json" 2>/dev/null || echo "{}")
  assert_contains "Bash hook present"            "Bash" "$s"
  assert_contains "Write|Edit|MultiEdit hook"    "Write|Edit|MultiEdit" "$s"
  assert_contains "narrow rm: .nanostack/**"     "Bash(rm:.nanostack/**)" "$s"
  assert_contains "narrow rm: /tmp/**"           "Bash(rm:/tmp/**)" "$s"
  assert_not_contains "no broad Bash(rm:*)"      "Bash(rm:*)" "$s"

  local doctor
  doctor=$( cd "$proj" && "$REPO/bin/nano-doctor.sh" --json --offline 2>/dev/null || true )
  assert_true "doctor JSON parses" \
    bash -c "echo '$doctor' | jq -e . >/dev/null"
  assert_true "doctor: bash_guard hook detected" \
    bash -c "echo '$doctor' | jq -e '.checks[] | select(.name==\"bash_guard\") | .status==\"pass\"' >/dev/null"
  assert_true "doctor: write_guard hook detected" \
    bash -c "echo '$doctor' | jq -e '.checks[] | select(.name==\"write_guard\") | .status==\"pass\"' >/dev/null"
}

# ─── Flow 3: bash guard ───────────────────────────────────────────────
# Direct calls to check-dangerous.sh. Each block expectation is one
# assertion, so a regression names the exact rule that failed.

flow_bash_guard() {
  local proj="$TMP_ROOT/bash-guard"
  mkdir -p "$proj"
  ( cd "$proj" && git init -q )
  local guard="$REPO/guard/bin/check-dangerous.sh"

  # Audit log lives in .nanostack/audit.log when run from a project.
  cd "$proj"
  export NANOSTACK_STORE="$proj/.nanostack"
  mkdir -p "$NANOSTACK_STORE"

  # Block list
  for cmd in \
    "rm -rf ./" \
    "find . -delete" \
    "find . -exec rm -rf {} +" \
    "cat .env" \
    "grep SECRET .env" \
    "env" \
    "printenv" \
    "git reset --hard" \
    "git push --force"
  do
    assert_false "guard blocks: $cmd" "$guard" "$cmd"
  done

  # Allow list
  for cmd in \
    "git push --force-with-lease" \
    "git status" \
    "cat README.md" \
    "rm -rf ./docs"
  do
    assert_true "guard allows: $cmd" "$guard" "$cmd"
  done

  # Audit log gets written for blocked attempts.
  assert_true "audit.log was written" test -f "$NANOSTACK_STORE/audit.log"
  cd "$REPO"
  unset NANOSTACK_STORE
}

# ─── Flow 4: write/edit guard ─────────────────────────────────────────
# Symlink-resolving denylist. The "safe symlink" case must use a
# RELATIVE symlink inside the project; an absolute symlink under
# $TMPDIR resolves to /var/folders/... on macOS, which the guard
# correctly blocks.

flow_write_guard() {
  local proj="$TMP_ROOT/write-guard"
  mkdir -p "$proj/src" "$proj/safe-target"
  cd "$proj"
  local guard="$REPO/guard/bin/check-write.sh"

  # Block list — basename matches do not need symlink resolution.
  assert_false "write blocks: .env" "$guard" "$proj/.env"

  # Symlink-bypass coverage. The guard resolves symlinks before
  # matching, so a writable parent-dir symlink to /etc must not let
  # writes reach /etc/passwd. Two patterns:
  #   1. Parent-dir symlink. Works on every OS because the pure-bash
  #      fallback follows the parent at `cd ... && pwd -P`.
  #   2. Leaf symlink. Requires GNU realpath; macOS BSD realpath
  #      lacks `-m`, so the leaf form falls back to a path that does
  #      not get resolved through the symlink. Gate this case behind
  #      a feature probe so the test is portable.
  ln -sfn "/etc" "$proj/etc-dir"
  assert_false "write blocks: parent-dir symlink to /etc reaches passwd" \
    "$guard" "$proj/etc-dir/passwd"

  if [ -d "$HOME/.ssh" ]; then
    ln -sfn "$HOME/.ssh" "$proj/ssh-dir"
    assert_false "write blocks: parent-dir symlink to ~/.ssh reaches config" \
      "$guard" "$proj/ssh-dir/config"
  else
    SKIP=$((SKIP+1))
    printf "    ${DIM}SKIP  write blocks: ~/.ssh/config (no ~/.ssh on this host)${NC}\n"
  fi

  if realpath -m /tmp/foo/bar >/dev/null 2>&1; then
    ln -sfn "/etc/passwd" "$proj/passwd-link"
    assert_false "write blocks: leaf symlink to /etc/passwd (GNU realpath path)" \
      "$guard" "$proj/passwd-link"
  else
    SKIP=$((SKIP+1))
    printf "    ${DIM}SKIP  write blocks: leaf symlink (no GNU realpath; macOS BSD)${NC}\n"
  fi

  # Allow list — paths the guard must NOT block.
  assert_true "write allows: .env.example" "$guard" "$proj/.env.example"
  assert_true "write allows: src/app.js"   "$guard" "$proj/src/app.js"

  # Relative symlink within the project resolves to a safe target.
  ln -sfn "safe-target" "$proj/safe-link"
  assert_true "write allows: relative symlink within project" \
    "$guard" "$proj/safe-link/notes.txt"

  cd "$REPO"
}

# ─── Flow 5: sprint with phase gate ──────────────────────────────────
# This is the regression test for the v1.0 bug. The assertion that
# current_phase clears AND that git commit unblocks after the trio
# completes catches the reported failure mode end-to-end.

flow_sprint_phase_gate() {
  local proj="$TMP_ROOT/sprint"
  mkdir -p "$proj"
  cd "$proj"
  git init -q
  git config user.email "e2e@test.local"
  git config user.name  "e2e"
  "$REPO/bin/init-project.sh" >/dev/null 2>&1

  export NANOSTACK_STORE="$proj/.nanostack"
  local NS="$REPO/bin/session.sh"
  local ART="$REPO/bin/save-artifact.sh"

  "$NS" init development --autopilot >/dev/null

  # Save think + plan artifacts the way the real skills would.
  "$ART" think '{"phase":"think","summary":{"value":"e2e think"}}' >/dev/null
  "$ART" plan  '{"phase":"plan","summary":{"value":"e2e plan","planned_files":["index.html","app.js","tests/todo.test.js"]}}' >/dev/null

  # Mini TODO app so /review and /qa have something real to look at.
  cat > index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>todo</title>
<ul id="list"></ul><script src="app.js"></script>
HTML
  cat > app.js <<'JS'
'use strict';
function add(items, item) { return items.concat([item]); }
function remove(items, idx) { return items.filter(function(_, i){ return i !== idx; }); }
if (typeof module !== 'undefined') module.exports = { add: add, remove: remove };
JS
  mkdir -p tests
  cat > tests/todo.test.js <<'JS'
const { add, remove } = require('../app.js');
const a = add([], 'x');
if (a.length !== 1 || a[0] !== 'x') { console.error('add failed'); process.exit(1); }
const b = remove(['x','y'], 0);
if (b.length !== 1 || b[0] !== 'y') { console.error('remove failed'); process.exit(1); }
console.log('todo tests pass');
JS

  assert_true "node --check app.js"     node --check app.js
  assert_true "node tests/todo.test.js" node tests/todo.test.js

  # Phase gate must block git commit BEFORE review/security/qa exist.
  git add -A
  assert_false "phase gate blocks git commit before sprint trio" \
    "$REPO/guard/bin/check-dangerous.sh" 'git commit -m "wip"'

  # Run the sprint trio. save-artifact.sh auto-calls session.sh
  # phase-complete after writing each artifact, so the harness only
  # needs to start each phase and save its artifact — exactly the
  # contract a real skill follows.
  for phase in review security qa; do
    "$NS" phase-start "$phase" >/dev/null
    "$ART" "$phase" "{\"phase\":\"$phase\",\"summary\":{\"v\":1}}" >/dev/null
  done

  # *** Regression check: current_phase must be null after qa-complete. ***
  # Before the v1.0 fix, current_phase stayed pinned to "qa" forever, which
  # left /qa's read lock active and silently blocked git commit.
  local cp
  cp=$(jq -r '.current_phase // "null"' "$NANOSTACK_STORE/session.json")
  assert_eq "current_phase clears after trio (regression)" "null" "$cp"

  # next-step.sh legacy mode should now report "ship" only.
  local pending
  pending=$("$REPO/bin/next-step.sh" qa 2>/dev/null | tr -s ' ')
  assert_eq "next-step after qa == ship" "ship" "$pending"

  # And git commit must now pass the dangerous-cmd guard.
  assert_true "git commit unblocked after trio (regression)" \
    "$REPO/guard/bin/check-dangerous.sh" 'git commit -m "ship: e2e"'

  # Real commit succeeds (uses the in-project hook layer, not the guard CLI).
  if NANOSTACK_SKIP_GATE=1 git commit -m "ship: e2e" -q >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf "    ${GREEN}OK${NC}    real git commit succeeds\n"
  else
    FAIL=$((FAIL+1)); printf "    ${RED}FAIL${NC}  real git commit failed\n"
  fi

  # resolve.sh ship loads the upstream artifacts.
  local resolved
  resolved=$("$REPO/bin/resolve.sh" ship 2>/dev/null || echo "{}")
  assert_contains "resolve.sh ship loads review artifact"   '"review"'   "$resolved"
  assert_contains "resolve.sh ship loads security artifact" '"security"' "$resolved"
  assert_contains "resolve.sh ship loads qa artifact"       '"qa"'       "$resolved"

  "$ART" ship '{"phase":"ship","summary":{"v":1,"pr_number":null,"ci_passed":true}}' >/dev/null
  assert_true "ship artifact saved" \
    bash -c "ls '$NANOSTACK_STORE/ship/'*.json 2>/dev/null | head -1 | grep -q ."

  cd "$REPO"
  unset NANOSTACK_STORE
}

# ─── Flow 6: legacy repair ────────────────────────────────────────────
# Pre-v0.8 install style: broad Bash(rm:*) + Write(*) + Edit(*) without
# hooks. --repair is additive (hooks added; broad rule still present).
# --migrate-permissions narrows the rm rule.

flow_legacy_repair() {
  local proj="$TMP_ROOT/legacy"
  mkdir -p "$proj/.claude"
  cd "$proj"
  git init -q
  cat > .claude/settings.json <<'JSON'
{
  "permissions": {
    "allow": ["Bash(rm:*)", "Bash(curl:*)", "Bash(find:*)", "Write(*)", "Edit(*)"]
  }
}
JSON

  # Doctor's JSON output must not truncate detail strings that contain
  # pipes (Round 4 audit found awk -F'|' was eating "Write|Edit|MultiEdit"
  # at the first pipe).
  local doctor
  doctor=$( "$REPO/bin/nano-doctor.sh" --json --offline 2>/dev/null || true )
  # Look at any check that mentions Write or curl. The detail field should
  # carry the full string, not a truncation.
  local writes_in_doctor
  writes_in_doctor=$(echo "$doctor" | jq -r '.checks[].detail' | grep -c 'Write|Edit|MultiEdit' || true)
  assert_true "doctor JSON keeps Write|Edit|MultiEdit intact" \
    test "$writes_in_doctor" -gt 0

  # --repair adds hooks, makes a backup, but keeps Bash(rm:*).
  "$REPO/bin/init-project.sh" --repair >/dev/null 2>&1
  assert_true "repair: backup .bak created" \
    bash -c "ls '$proj/.claude/'*.bak 2>/dev/null | head -1 | grep -q ."
  local s
  s=$(cat "$proj/.claude/settings.json")
  assert_contains "repair: Bash hook added"           "Bash" "$s"
  assert_contains "repair: Write|Edit|MultiEdit hook" "Write|Edit|MultiEdit" "$s"
  assert_contains "repair is additive: rm:* still present" "Bash(rm:*)" "$s"

  # --migrate-permissions: explicit narrowing.
  "$REPO/bin/init-project.sh" --migrate-permissions >/dev/null 2>&1
  s=$(cat "$proj/.claude/settings.json")
  assert_not_contains "migrate-permissions removed Bash(rm:*)" "Bash(rm:*)" "$s"

  cd "$REPO"
}

# ─── Flow 7: local / no-git ───────────────────────────────────────────
# The local-mode path: no git repo, no PR/CI vocabulary, pre-ship-check
# returns LOCAL_MODE.

flow_local_no_git() {
  local proj="$TMP_ROOT/local"
  mkdir -p "$proj"
  cd "$proj"
  # Intentionally no git init.

  "$REPO/bin/init-project.sh" >/dev/null 2>&1

  # detect_git_mode is a sourced function.
  local mode
  mode=$( source "$REPO/bin/lib/git-context.sh" && detect_git_mode )
  assert_eq "detect_git_mode == local" "local" "$mode"

  export NANOSTACK_STORE="$proj/.nanostack"
  "$REPO/bin/session.sh" init development >/dev/null
  "$REPO/bin/save-artifact.sh" plan '{"phase":"plan","summary":{"v":1}}' >/dev/null
  echo "hola" > notes.txt

  local out
  out=$( "$REPO/ship/bin/pre-ship-check.sh" 2>/dev/null || true )
  assert_eq "pre-ship-check emits LOCAL_MODE" "LOCAL_MODE" "$out"

  cd "$REPO"
  unset NANOSTACK_STORE
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Nanostack E2E user flows"
echo "========================"
echo "Tmp root: $TMP_ROOT"

flow install_isolated
flow fresh_git_project
flow bash_guard
flow write_guard
flow sprint_phase_gate
flow legacy_repair
flow local_no_git

echo ""
echo "========================"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}E2E summary: $PASS checks passed, 0 failed${NC}"
else
  printf "${RED}E2E summary: $FAIL failed${NC} / $TOTAL total"
  printf "\nFailed flows:%s" "$FAILED_FLOWS"
fi
[ "$SKIP" -gt 0 ] && printf " ${DIM}($SKIP skipped)${NC}"
echo ""

[ "$FAIL" -eq 0 ]
