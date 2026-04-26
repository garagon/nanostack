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
    "git push --force" \
    "cat credentials.json" \
    "jq . secrets.json" \
    "cat service-account.json" \
    "cat firebase-adminsdk.json" \
    "cat .env.local" \
    "cat .env.production"
  do
    assert_false "guard blocks: $cmd" "$guard" "$cmd"
  done

  # Allow list
  for cmd in \
    "git push --force-with-lease" \
    "git status" \
    "cat README.md" \
    "rm -rf ./docs" \
    "cat .env.example" \
    "cat .env.sample" \
    "cat .env.template" \
    "jq . tsconfig.json" \
    "jq . package.json"
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

  # Leaf-symlink case. After the macOS-fallback fix, this passes on
  # both GNU realpath (-m) and BSD realpath (plain) and on the pure-bash
  # readlink-based fallback when no realpath is usable.
  ln -sfn "/etc/passwd" "$proj/passwd-link"
  assert_false "write blocks: leaf symlink to /etc/passwd" \
    "$guard" "$proj/passwd-link"

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

# ─── Flow 8: phase registry ──────────────────────────────────────────
# bin/lib/phases.sh is the single source of truth. Lifecycle scripts
# read from it; this flow proves a registered custom phase saves and a
# missing registration is rejected with the right message, end-to-end
# from a real project directory.

flow_phase_registry() {
  local proj="$TMP_ROOT/phase-registry"
  mkdir -p "$proj/.nanostack"
  cd "$proj"
  git init -q
  export NANOSTACK_STORE="$proj/.nanostack"

  # No custom phases yet: rejection path.
  printf '%s' '{}' > .nanostack/config.json
  assert_false "save-artifact rejects unregistered phase" \
    "$REPO/bin/save-artifact.sh" audit-licenses \
    '{"phase":"audit-licenses","summary":{"flagged":[]},"context_checkpoint":{"summary":"ok"}}'
  local rej_out
  rej_out=$( "$REPO/bin/save-artifact.sh" audit-licenses \
    '{"phase":"audit-licenses","summary":{"flagged":[]},"context_checkpoint":{"summary":"ok"}}' 2>&1 || true )
  assert_true "rejection message says 'invalid phase'" \
    bash -c "echo '$rej_out' | grep -qF 'invalid phase'"

  # After registration: save and read.
  printf '%s' '{"custom_phases":["audit-licenses"]}' > .nanostack/config.json
  "$REPO/bin/save-artifact.sh" audit-licenses \
    '{"phase":"audit-licenses","summary":{"flagged":[],"counts":{"permissive":1}},"context_checkpoint":{"summary":"7 deps scanned","key_files":["package.json"]}}' \
    >/dev/null
  assert_true "registered custom phase artifact exists" \
    bash -c "ls $proj/.nanostack/audit-licenses/*.json 2>/dev/null | head -1"

  local found
  found=$( "$REPO/bin/find-artifact.sh" audit-licenses 30 2>/dev/null )
  assert_true "find-artifact returns the saved path" test -f "$found"

  # Library smoke from a real project: nano_all_phases includes the
  # registered custom phase; nano_phase_kind classifies it correctly.
  local kind
  kind=$( source "$REPO/bin/lib/phases.sh" && nano_phase_kind audit-licenses )
  assert_eq "nano_phase_kind == custom for registered phase" "custom" "$kind"

  # Resolver returns the custom-phase shape per the contract.
  local resolved
  resolved=$( "$REPO/bin/resolve.sh" audit-licenses 2>/dev/null )
  local resolved_kind
  resolved_kind=$( echo "$resolved" | jq -r '.phase_kind' )
  assert_eq "resolve.sh emits phase_kind=custom" "custom" "$resolved_kind"

  # Lifecycle round-trip with one custom artifact saved (PR 4): analytics
  # counts it, sprint-journal emits a section for it, default discard
  # --dry-run includes its file path.
  #
  # Reset the audit-licenses dir first. An earlier block in this same
  # flow may have saved a smoke artifact; save-artifact.sh names files
  # by per-second timestamp, so a second write inside the same second
  # silently overwrites the first and a write a second later doubles
  # the count. Either way breaks the strict equality below.
  rm -rf "$proj/.nanostack/audit-licenses"
  "$REPO/bin/save-artifact.sh" audit-licenses \
    '{"phase":"audit-licenses","summary":{"status":"OK","headline":"smoke audit"},"context_checkpoint":{"summary":"ok"}}' \
    >/dev/null
  local analytics_json
  analytics_json=$( "$REPO/bin/analytics.sh" --json )
  assert_true "analytics.sprints.custom.audit-licenses == 1" \
    bash -c "echo '$analytics_json' | jq -e '.sprints.\"custom\".\"audit-licenses\" == 1' >/dev/null"
  assert_true "analytics.sprints.total includes the custom count" \
    bash -c "echo '$analytics_json' | jq -e '.sprints.total >= 1' >/dev/null"
  local journal_path
  journal_path=$( "$REPO/bin/sprint-journal.sh" )
  assert_true "sprint-journal emits a /audit-licenses section" \
    bash -c "grep -qF '## /audit-licenses' '$journal_path'"
  assert_true "sprint-journal includes the custom artifact path" \
    bash -c "grep -qF 'Artifact:' '$journal_path'"
  local discard_out
  discard_out=$( "$REPO/bin/discard-sprint.sh" --dry-run )
  assert_true "default discard --dry-run includes the custom artifact" \
    bash -c "echo '$discard_out' | grep -qF 'audit-licenses'"

  # Conductor (PR 5): --phases inline JSON drives the sprint topology;
  # the custom skill's concurrency=read is honored during cmd_batch.
  mkdir -p .nanostack/skills/audit-licenses
  printf '%s\n' '---' 'name: audit-licenses' 'concurrency: read' 'depends_on: [build]' '---' \
    > .nanostack/skills/audit-licenses/SKILL.md
  "$REPO/conductor/bin/sprint.sh" start \
    --phases '[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"audit-licenses","depends_on":["build"]},{"name":"ship","depends_on":["audit-licenses"]}]' \
    >/dev/null
  local sprint_status
  sprint_status=$( "$REPO/conductor/bin/sprint.sh" status )
  assert_true "conductor sprint includes the custom phase from --phases" \
    bash -c "echo '$sprint_status' | jq -e '.phases | has(\"audit-licenses\")' >/dev/null"
  assert_true "conductor sprint has 5 phases (custom graph)" \
    bash -c "echo '$sprint_status' | jq -e '.phases | length == 5' >/dev/null"

  local batch_out
  batch_out=$( "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
  assert_true "conductor batch reads custom skill concurrency=read" \
    bash -c "echo '$batch_out' | grep -qE '\"phases\":\\[[^]]*\"audit-licenses\"[^]]*\\].*\"type\":\"read\"|\"type\":\"read\".*\"phases\":\\[[^]]*\"audit-licenses\"'"

  # Cycle in --phases must exit 2 (no sprint created).
  assert_false "conductor rejects a cycle in --phases" \
    "$REPO/conductor/bin/sprint.sh" start \
    --phases '[{"name":"think","depends_on":["plan"]},{"name":"plan","depends_on":["think"]}]'

  # Add a phase_graph so the resolver populates upstream_artifacts;
  # build appears as null (no artifact dir), plan appears as a path.
  printf '%s' '{"custom_phases":["audit-licenses"],"phase_graph":[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"audit-licenses","depends_on":["build","plan"]},{"name":"ship","depends_on":["audit-licenses"]}]}' > .nanostack/config.json
  "$REPO/bin/save-artifact.sh" plan \
    '{"phase":"plan","summary":{"goal":"x"},"context_checkpoint":{"summary":"y"}}' >/dev/null
  resolved=$( "$REPO/bin/resolve.sh" audit-licenses 2>/dev/null )
  assert_true "resolver: build dep renders as null" \
    bash -c "echo '$resolved' | jq -e '.upstream_artifacts.build == null' >/dev/null"
  assert_true "resolver: plan dep renders as a path" \
    bash -c "echo '$resolved' | jq -e '.upstream_artifacts.plan | type == \"string\"' >/dev/null"

  cd "$REPO"
  unset NANOSTACK_STORE
}



# ─── Flow 9: custom skill template copy ───────────────────────────
# After PR 3, copying examples/custom-skill-template/audit-licenses
# into a fake skills root must work without referencing the source
# folder. This flow exercises the spec's acceptance scenario:
#   1. cp -R the template into /tmp/skills/audit-licenses
#   2. cd into a sibling fake project
#   3. run the helper from its absolute path (smoke.sh proxies for
#      the helper since it covers all three stacks)
#   4. confirm the SKILL.md does not embed the repo example path

flow_custom_skill_template_copy() {
  local skills_root="$TMP_ROOT/skills"
  local proj="$TMP_ROOT/copy-test-proj"
  mkdir -p "$skills_root" "$proj"
  cd "$proj"
  git init -q

  cp -R "$REPO/examples/custom-skill-template/audit-licenses" "$skills_root/audit-licenses"

  assert_true "copied SKILL.md does not embed the repo example path" \
    bash -c "! grep -qE '\\./examples/custom-skill-template/' '$skills_root/audit-licenses/SKILL.md'"

  assert_true "copied SKILL.md uses NANOSTACK_ROOT and SKILL_DIR env vars" \
    bash -c "grep -qE 'NANOSTACK_ROOT=.*HOME' '$skills_root/audit-licenses/SKILL.md' && grep -qE 'SKILL_DIR=.*HOME' '$skills_root/audit-licenses/SKILL.md'"

  assert_true 'copied SKILL.md does NOT hardcode ~/.claude/skills/nanostack/bin paths' \
    bash -c "! grep -qE '~/\\.claude/skills/nanostack/bin/(resolve|save-artifact|find-artifact)\\.sh' '$skills_root/audit-licenses/SKILL.md'"

  assert_true "copied agents/openai.yaml is present" \
    test -f "$skills_root/audit-licenses/agents/openai.yaml"

  assert_true "copied bin/smoke.sh is executable" \
    test -x "$skills_root/audit-licenses/bin/smoke.sh"

  # Run the smoke check from the copied location. Three "ok" lines.
  local smoke_out
  smoke_out=$( "$skills_root/audit-licenses/bin/smoke.sh" 2>&1 )
  assert_true "copied skill smoke passes (node)" \
    bash -c "echo '$smoke_out' | grep -qE 'ok[[:space:]]+node manifest scans'"
  assert_true "copied skill smoke passes (python)" \
    bash -c "echo '$smoke_out' | grep -qE 'ok[[:space:]]+python manifest scans'"
  assert_true "copied skill smoke passes (go)" \
    bash -c "echo '$smoke_out' | grep -qE 'ok[[:space:]]+go manifest scans'"

  # Full user journey: register the phase, run the helper against a
  # real Node manifest, save the artifact, find it back, and verify
  # the resolver classifies the phase as custom. This is the path
  # that previously failed with "invalid phase" before the user
  # learned about .custom_phases.
  mkdir -p .nanostack
  printf '%s' '{"custom_phases":["audit-licenses"]}' > .nanostack/config.json
  export NANOSTACK_STORE="$proj/.nanostack"

  # Minimal manifest so audit.sh has something to read.
  printf '%s\n' '{"name":"copy-test","dependencies":{"lodash":"4.17.21"}}' > package.json

  # Resolver knows the phase now.
  local kind
  kind=$( "$REPO/bin/resolve.sh" audit-licenses 2>/dev/null | jq -r '.phase_kind' )
  assert_eq "registered custom phase resolves with phase_kind=custom" "custom" "$kind"

  # Run the helper from its copied location and save the artifact.
  local audit_json
  audit_json=$( "$skills_root/audit-licenses/bin/audit.sh" node 2>/dev/null )
  assert_true "audit.sh emits a JSON object with .counts" \
    bash -c "echo '$audit_json' | jq -e '.counts' >/dev/null"

  # Build a save-artifact-shaped JSON from the audit result.
  local save_json
  save_json=$( jq -n --argjson counts "$(echo "$audit_json" | jq '.counts')" \
    '{phase:"audit-licenses", summary:{flagged:[],counts:$counts}, context_checkpoint:{summary:"smoke save"}}' )
  assert_true "save-artifact accepts the registered custom phase" \
    "$REPO/bin/save-artifact.sh" audit-licenses "$save_json"

  # find-artifact returns the path we just saved.
  local found
  found=$( "$REPO/bin/find-artifact.sh" audit-licenses 30 2>/dev/null )
  assert_true "find-artifact returns the saved audit-licenses path" \
    test -f "$found"
  assert_true "saved artifact has the expected phase field" \
    bash -c "jq -e '.phase == \"audit-licenses\"' '$found' >/dev/null"

  # Fresh-shell simulation: extract each ```bash snippet from SKILL.md
  # and run it in its own bash -c (no inherited env, no exported vars
  # from a previous step). This reproduces what Claude Code does on
  # every Bash tool call. Each helper-invoking snippet must succeed
  # without relying on state from earlier blocks.
  local skill_md="$skills_root/audit-licenses/SKILL.md"
  local resolve_snippet
  resolve_snippet=$( awk '
    /^```bash$/ { capture=1; buf=""; next }
    /^```$/ && capture { if (buf ~ /resolve\.sh/) { print buf; capture=0; exit } capture=0; next }
    capture { buf = buf $0 "\n" }
  ' "$skill_md" )
  assert_true "fresh-shell snippet for /resolve runs (NANOSTACK_ROOT survives without prior export)" \
    env -i HOME="$HOME" PATH="$PATH" \
    bash -c "cd '$proj' && export NANOSTACK_STORE='$proj/.nanostack' && NANOSTACK_ROOT='$REPO' && $resolve_snippet >/dev/null 2>&1"

  local audit_snippet
  audit_snippet=$( awk '
    /^```bash$/ { capture=1; buf=""; next }
    /^```$/ && capture { if (buf ~ /audit\.sh/) { print buf; capture=0; exit } capture=0; next }
    capture { buf = buf $0 "\n" }
  ' "$skill_md" )
  assert_true "fresh-shell snippet for /audit runs (SKILL_DIR survives without prior export)" \
    env -i HOME="$HOME" PATH="$PATH" \
    bash -c "cd '$proj' && SKILL_DIR='$skills_root/audit-licenses' && $audit_snippet >/dev/null 2>&1"

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
flow phase_registry
flow custom_skill_template_copy

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
