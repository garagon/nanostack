#!/usr/bin/env bash
# e2e-lib-units.sh — bin/lib unit coverage, run in CI through the harness.
#
# Architecture review round (2026-06-11). The repo's fine-grained unit
# tests (save-artifact integrity, session lifecycle, budget/circuit,
# the phase registry, and the custom-phase resolver/conductor graph)
# lived only in a developer-local runner that never ran in CI, so a
# regression in bin/lib could ship green. This suite carries that exact
# coverage into the committed harness: same cases, same all-or-nothing
# semantics, now executed on every PR (and on macOS via the unit kind),
# so bin/lib drift fails the build.
#
# Each cell runs one original test body verbatim inside a throwaway git
# repo under the harness /tmp root (NANOSTACK_STORE points there), and
# counts as a single check whose pass/fail is the body's exit status —
# matching the local runner exactly. The developer-local runner stays
# the source for editing cases; this file is the CI-executed copy.
#
# Exit 0 = all cells pass, exit 1 = any cell failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init lib-units nano-lib-units
nh_require_cmd jq git python3

NANOSTACK_ROOT="$REPO"
BIN="$NANOSTACK_ROOT/bin"
GUARD="$NANOSTACK_ROOT/guard/bin"
CONDUCTOR="$NANOSTACK_ROOT/conductor/bin"

# Assertion helpers used inside the test bodies below. Kept identical to
# the developer-local runner so the bodies can be carried over verbatim.
assert_file_exists() { [ -f "$1" ] || { echo "ASSERT: file not found: $1"; return 1; }; }
assert_file_missing() { [ ! -f "$1" ] || { echo "ASSERT: file should not exist: $1"; return 1; }; }
assert_exit_0() { "$@" >/dev/null 2>&1; }
assert_exit_1() { ! "$@" >/dev/null 2>&1; }
assert_contains() { echo "$1" | grep -q "$2" || { echo "ASSERT: '$2' not found in output"; return 1; }; }
assert_json_field() { jq -e "$2" "$1" >/dev/null 2>&1 || { echo "ASSERT: $2 not found in $1"; return 1; }; }

# run_test <name> <body> — harness adapter for the local runner's API.
# A fresh git repo + .nanostack config + NANOSTACK_STORE is created per
# case under the harness temp root; the body runs in a subshell with cwd
# inside that workspace. The body inherits the local runner's semantics:
# no errexit/nounset, so only the body's final command determines the
# pass/fail (each case is one check). --filter skips are counted by the
# harness so floor enforcement stays consistent.
run_test() {
  nh_should_run "$1" || { _NH_SKIP=$((_NH_SKIP + 1)); return 0; }
  _NH_CELL="$1"
  local dir; dir="$(mktemp -d "$NH_TMP/case.XXXXXX")"
  local rc
  (
    set +e +u
    cd "$dir" || exit 99
    git init -q >/dev/null 2>&1
    mkdir -p .nanostack
    printf '%s' '{"schema_version":"1","project":"test","agents":["claude"],"custom_phases":[]}' > .nanostack/config.json
    export NANOSTACK_STORE="$dir/.nanostack"
    eval "$2"
  ) >"$dir/.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    nh_pass "$1"
  else
    nh_fail "$1" "body exited $rc"
    head -6 "$dir/.out" | sed 's/^/          /' >&2
  fi
  _NH_CELL=""
}

# ─── save-artifact.sh ──────────────────────────────────────

run_test "save-artifact: saves valid artifact" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"value\":\"test\"}}"
  assert_file_exists .nanostack/think/*.json
'

run_test "save-artifact: rejects invalid JSON" '
  assert_exit_1 "$BIN/save-artifact.sh" think "not json"
'

run_test "save-artifact: rejects missing phase field" '
  assert_exit_1 "$BIN/save-artifact.sh" think "{\"summary\":{\"v\":1}}"
'

run_test "save-artifact: rejects phase mismatch" '
  assert_exit_1 "$BIN/save-artifact.sh" think "{\"phase\":\"plan\",\"summary\":{\"v\":1}}"
'

run_test "save-artifact: injects timestamp and project" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}"
  ARTIFACT=$(ls .nanostack/think/*.json)
  assert_json_field "$ARTIFACT" ".timestamp"
  assert_json_field "$ARTIFACT" ".project"
  assert_json_field "$ARTIFACT" ".branch"
'

run_test "save-artifact: adds integrity checksum" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}"
  ARTIFACT=$(ls .nanostack/think/*.json)
  assert_json_field "$ARTIFACT" ".integrity"
'

run_test "save-artifact: redacts Stripe secret keys" '
  # Fixture assembled at runtime so the contiguous sk_live_ token never
  # appears in committed source (GitHub push protection). Do not re-join.
  KEY="sk_""live_abcdefghijklmnopqrstuvwxyz123456"
  RESULT=$("$BIN/save-artifact.sh" security "{\"phase\":\"security\",\"summary\":{\"v\":1},\"findings\":[{\"desc\":\"key: ${KEY}\"}],\"context_checkpoint\":{\"summary\":\"redact test\"}}" 2>&1)
  ARTIFACT=$(ls .nanostack/security/*.json)
  DESC=$(jq -r ".findings[0].desc" "$ARTIFACT")
  echo "$DESC" | grep -q "REDACTED"
'

run_test "save-artifact: redacts AWS keys" '
  # Split the same way as the Stripe fixture above (push protection).
  KEY="AKIA""IOSFODNN7EXAMPLE1"
  "$BIN/save-artifact.sh" security "{\"phase\":\"security\",\"summary\":{\"v\":1},\"findings\":[{\"desc\":\"key: ${KEY}\"}],\"context_checkpoint\":{\"summary\":\"redact test\"}}" 2>/dev/null
  ARTIFACT=$(ls .nanostack/security/*.json)
  DESC=$(jq -r ".findings[0].desc" "$ARTIFACT")
  echo "$DESC" | grep -q "REDACTED"
'

run_test "save-artifact: truncates findings over limit" '
  FINDINGS=$(python3 -c "import json; print(json.dumps([{\"id\":\"F-\"+str(i)} for i in range(60)]))")
  NANOSTACK_MAX_FINDINGS=10 "$BIN/save-artifact.sh" qa "{\"phase\":\"qa\",\"summary\":{\"v\":1},\"findings\":$FINDINGS,\"context_checkpoint\":{\"summary\":\"truncate test\"}}" 2>/dev/null
  ARTIFACT=$(ls .nanostack/qa/*.json)
  COUNT=$(jq ".findings | length" "$ARTIFACT")
  [ "$COUNT" -eq 11 ]
'

# ─── find-artifact.sh ──────────────────────────────────────

run_test "find-artifact: finds recent artifact" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}" >/dev/null
  "$BIN/find-artifact.sh" think 1
'

run_test "find-artifact: returns exit 1 when none found" '
  assert_exit_1 "$BIN/find-artifact.sh" think 1
'

run_test "find-artifact: --verify passes on valid artifact" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}" >/dev/null
  "$BIN/find-artifact.sh" think 1 --verify
'

run_test "find-artifact: --verify fails on tampered artifact" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}" >/dev/null
  ARTIFACT=$(ls .nanostack/think/*.json)
  jq ".summary.v = 999" "$ARTIFACT" > "${ARTIFACT}.tmp" && mv "${ARTIFACT}.tmp" "$ARTIFACT"
  assert_exit_1 "$BIN/find-artifact.sh" think 1 --verify
'

# ─── session.sh ────────────────────────────────────────────

run_test "session: init creates session.json" '
  "$BIN/session.sh" init development
  assert_file_exists .nanostack/session.json
'

run_test "session: init with --autopilot" '
  "$BIN/session.sh" init development --autopilot
  AUTOPILOT=$(jq -r ".autopilot" .nanostack/session.json)
  [ "$AUTOPILOT" = "true" ]
'

run_test "session: phase-start updates current_phase" '
  "$BIN/session.sh" init development
  "$BIN/session.sh" phase-start think
  PHASE=$(jq -r ".current_phase" .nanostack/session.json)
  [ "$PHASE" = "think" ]
'

run_test "session: phase-complete sets next_phase" '
  "$BIN/session.sh" init development
  "$BIN/session.sh" phase-start think
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}" >/dev/null
  "$BIN/session.sh" phase-complete think
  NEXT=$(jq -r ".next_phase" .nanostack/session.json)
  [ "$NEXT" = "plan" ]
'

run_test "session: phase-complete tracks duration" '
  "$BIN/session.sh" init development
  "$BIN/session.sh" phase-start think
  sleep 1
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}" >/dev/null
  "$BIN/session.sh" phase-complete think
  DURATION=$(jq -r ".phase_log[0].duration_seconds" .nanostack/session.json)
  [ "$DURATION" -ge 1 ]
'

run_test "session: resume detects active session" '
  "$BIN/session.sh" init development
  "$BIN/session.sh" phase-start think
  RESULT=$("$BIN/session.sh" resume)
  echo "$RESULT" | jq -e ".resumable == true"
'

run_test "session: archive moves to sessions/" '
  "$BIN/session.sh" init development
  "$BIN/session.sh" archive
  assert_file_missing .nanostack/session.json
  ls .nanostack/sessions/*.json >/dev/null
'

# ─── budget.sh ─────────────────────────────────────────────

run_test "budget: set persists config" '
  "$BIN/session.sh" init development
  "$BIN/budget.sh" set --max-usd 15 --model opus-4
  MAX=$(jq -r ".budget.max_usd" .nanostack/session.json)
  [ "$MAX" = "15" ]
'

run_test "budget: check returns continue under threshold" '
  "$BIN/session.sh" init development
  "$BIN/budget.sh" set --max-usd 15 --model opus-4
  RESULT=$("$BIN/budget.sh" check --input-tokens 50000 --output-tokens 10000)
  echo "$RESULT" | jq -e ".action == \"continue\""
'

run_test "budget: check returns stop over threshold" '
  "$BIN/session.sh" init development
  "$BIN/budget.sh" set --max-usd 15 --model opus-4
  RESULT=$("$BIN/budget.sh" check --input-tokens 800000 --output-tokens 200000)
  echo "$RESULT" | jq -e ".action == \"stop\""
'

# ─── circuit.sh ────────────────────────────────────────────

run_test "circuit: fail increments counter" '
  RESULT=$("$BIN/circuit.sh" fail --tag "test" --max 3)
  echo "$RESULT" | jq -e ".consecutive == 1"
'

run_test "circuit: 3 failures opens circuit" '
  "$BIN/circuit.sh" fail --tag "test" --max 3 >/dev/null
  "$BIN/circuit.sh" fail --tag "test" --max 3 >/dev/null
  RESULT=$("$BIN/circuit.sh" fail --tag "test" --max 3)
  echo "$RESULT" | jq -e ".state == \"open\""
'

run_test "circuit: new tag resets counter" '
  "$BIN/circuit.sh" fail --tag "old" --max 3 >/dev/null
  "$BIN/circuit.sh" fail --tag "old" --max 3 >/dev/null
  RESULT=$("$BIN/circuit.sh" fail --tag "new" --max 3)
  echo "$RESULT" | jq -e ".consecutive == 1"
'

run_test "circuit: success resets counter" '
  "$BIN/circuit.sh" fail --tag "test" --max 3 >/dev/null
  RESULT=$("$BIN/circuit.sh" success)
  echo "$RESULT" | jq -e ".consecutive == 0"
'

# ─── restore-context.sh ───────────────────────────────────

run_test "restore-context: reads checkpoints" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1},\"context_checkpoint\":{\"summary\":\"Test think.\",\"key_files\":[],\"decisions_made\":[],\"open_questions\":[]}}" >/dev/null
  RESULT=$("$BIN/restore-context.sh")
  echo "$RESULT" | grep -q "Test think"
'

run_test "restore-context: --json output" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1},\"context_checkpoint\":{\"summary\":\"Test.\",\"key_files\":[],\"decisions_made\":[],\"open_questions\":[]}}" >/dev/null
  RESULT=$("$BIN/restore-context.sh" --json)
  echo "$RESULT" | jq -e ".[0].has_checkpoint == true"
'

# ─── validate-dependencies.sh ─────────────────────────────

run_test "validate-deps: passes when deps exist" '
  "$BIN/save-artifact.sh" think "{\"phase\":\"think\",\"summary\":{\"v\":1}}" >/dev/null
  "$BIN/validate-dependencies.sh" plan
'

run_test "validate-deps: fails when deps missing" '
  assert_exit_1 "$BIN/validate-dependencies.sh" review
'

# ─── sprint.sh ─────────────────────────────────────────────

run_test "sprint: start creates sprint directory" '
  SPRINT_DIR=$("$CONDUCTOR/sprint.sh" start)
  [ -d "$SPRINT_DIR" ]
  [ -f "$SPRINT_DIR/sprint.json" ]
'

run_test "sprint: claim succeeds when deps met" '
  "$CONDUCTOR/sprint.sh" start >/dev/null
  RESULT=$("$CONDUCTOR/sprint.sh" claim think)
  [ "$RESULT" = "OK" ]
'

run_test "sprint: claim fails when deps not met" '
  "$CONDUCTOR/sprint.sh" start >/dev/null
  assert_exit_1 "$CONDUCTOR/sprint.sh" claim plan
'

run_test "sprint: batch groups parallel phases" '
  "$CONDUCTOR/sprint.sh" start >/dev/null
  "$CONDUCTOR/sprint.sh" claim think >/dev/null
  "$CONDUCTOR/sprint.sh" complete think >/dev/null
  "$CONDUCTOR/sprint.sh" claim plan >/dev/null
  "$CONDUCTOR/sprint.sh" complete plan >/dev/null
  "$CONDUCTOR/sprint.sh" claim build >/dev/null
  "$CONDUCTOR/sprint.sh" complete build >/dev/null
  RESULT=$("$CONDUCTOR/sprint.sh" batch)
  echo "$RESULT" | grep -q "review.*security.*qa"
'

# ─── guard rules ───────────────────────────────────────────

run_test "guard: blocks rm -rf /" '
  assert_exit_1 "$GUARD/check-dangerous.sh" "rm -rf /"
'

run_test "guard: blocks force push" '
  assert_exit_1 "$GUARD/check-dangerous.sh" "git push --force origin main"
'

run_test "guard: allows git status" '
  assert_exit_0 "$GUARD/check-dangerous.sh" "git status"
'

run_test "guard: blocks credential injection" '
  assert_exit_1 "$GUARD/check-dangerous.sh" "export AWS_SECRET_KEY=test123"
'

run_test "guard: blocks docker privileged" '
  assert_exit_1 "$GUARD/check-dangerous.sh" "docker run --privileged ubuntu"
'

run_test "guard: blocks sudo rm" '
  assert_exit_1 "$GUARD/check-dangerous.sh" "sudo rm -rf /var"
'

# ─── scope-drift.sh ───────────────────────────────────────

run_test "scope-drift: reports no plan when missing" '
  RESULT=$("$BIN/scope-drift.sh")
  echo "$RESULT" | jq -e ".status == \"no_plan\""
'

# ─── save-solution.sh ─────────────────────────────────────

run_test "save-solution: creates bug document" '
  RESULT=$("$BIN/save-solution.sh" bug "Test bug" "tag1,tag2")
  echo "$RESULT" | grep -q "created:"
'

run_test "save-solution: detects duplicate" '
  "$BIN/save-solution.sh" bug "Test bug" "tag1" >/dev/null
  RESULT=$("$BIN/save-solution.sh" bug "Test bug" "tag1")
  echo "$RESULT" | grep -q "exists:"
'

# ─── Phase registry (bin/lib/phases.sh) ───────────────────

run_test "phase-registry: nano_core_phases returns six core phases" '
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_core_phases)
  test "$out" = "think plan review security qa ship"
'

run_test "phase-registry: nano_all_phases falls back to core when no config" '
  unset NANOSTACK_STORE || true
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_all_phases)
  test "$out" = "think plan review security qa ship"
'

run_test "phase-registry: nano_all_phases adds registered custom phases" '
  printf %s "{\"custom_phases\":[\"audit-licenses\",\"performance\"]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_all_phases)
  echo "$out" | grep -qF "audit-licenses"
  echo "$out" | grep -qF "performance"
  echo "$out" | grep -qF "think"
'

run_test "phase-registry: invalid custom phase names are rejected" '
  printf %s "{\"custom_phases\":[\"BAD_NAME\",\"good-name\"]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_custom_phases 2>/dev/null)
  echo "$out" | grep -qF "good-name"
  ! echo "$out" | grep -qF "BAD_NAME"
'

run_test "phase-registry: custom phase cannot override a core name" '
  printf %s "{\"custom_phases\":[\"ship\",\"audit-licenses\"]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_custom_phases 2>/dev/null)
  echo "$out" | grep -qF "audit-licenses"
  ! echo "$out" | grep -qF "ship"
'

run_test "phase-registry: nano_phase_kind classifies core / custom / unknown" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  test "$(nano_phase_kind think)" = "core"
  test "$(nano_phase_kind audit-licenses)" = "custom"
  test "$(nano_phase_kind something-else 2>/dev/null)" = "unknown"
'

run_test "phase-registry: nano_phase_exists returns 0 for known phases" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  nano_phase_exists think
  nano_phase_exists audit-licenses
  ! nano_phase_exists nonexistent-phase
'

run_test "phase-registry: nano_phase_graph_json default mirrors conductor (think→plan→build→...→ship)" '
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json)
  # Seven nodes: think, plan, build, review, qa, security, ship.
  echo "$out" | jq -e ". | length == 7" >/dev/null
  echo "$out" | jq -e "any(.name == \"build\")" >/dev/null
  # build depends on plan; review/qa/security all depend on build;
  # ship depends on review, qa, security.
  echo "$out" | jq -e ".[] | select(.name == \"build\") | .depends_on == [\"plan\"]" >/dev/null
  for p in review qa security; do
    echo "$out" | jq -e ".[] | select(.name == \"$p\") | .depends_on == [\"build\"]" >/dev/null
  done
  echo "$out" | jq -e ".[] | select(.name == \"ship\") | .depends_on | sort == [\"qa\",\"review\",\"security\"]" >/dev/null
'

run_test "phase-registry: nano_phase_graph_json accepts a valid custom graph" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"],\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"audit-licenses\",\"depends_on\":[\"think\"]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json)
  echo "$out" | jq -e ". | length == 2" >/dev/null
  echo "$out" | jq -e ".[1].name == \"audit-licenses\"" >/dev/null
'

run_test "phase-registry: phase_graph with unknown phase name falls back to default" '
  printf %s "{\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"NOT_REGISTERED\",\"depends_on\":[\"think\"]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json 2>/dev/null)
  echo "$out" | jq -e ". | length == 7" >/dev/null
'

run_test "phase-registry: phase_graph with unregistered custom phase falls back to default" '
  printf %s "{\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"performance\",\"depends_on\":[\"think\"]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json 2>/dev/null)
  echo "$out" | jq -e ". | length == 7" >/dev/null
'

run_test "phase-registry: phase_graph with dangling depends_on falls back to default" '
  printf %s "{\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[\"plan\"]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json 2>/dev/null)
  echo "$out" | jq -e ". | length == 7" >/dev/null
'

run_test "phase-registry: phase_graph with invalid name regex falls back to default" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"],\"phase_graph\":[{\"name\":\"BAD_NAME\",\"depends_on\":[]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json 2>/dev/null)
  echo "$out" | jq -e ". | length == 7" >/dev/null
'

run_test "phase-registry: phase_graph with duplicate name falls back to default" '
  printf %s "{\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"think\",\"depends_on\":[]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json 2>/dev/null)
  echo "$out" | jq -e ". | length == 7" >/dev/null
'

run_test "phase-registry: phase_graph with cycle falls back to default" '
  printf %s "{\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[\"plan\"]},{\"name\":\"plan\",\"depends_on\":[\"think\"]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json 2>/dev/null)
  echo "$out" | jq -e ". | length == 7" >/dev/null
'

run_test "phase-registry: phase_graph with self-loop falls back to default" '
  printf %s "{\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[\"think\"]}]}" > .nanostack/config.json
  source "$NANOSTACK_ROOT/bin/lib/phases.sh"
  out=$(nano_phase_graph_json 2>/dev/null)
  echo "$out" | jq -e ". | length == 7" >/dev/null
'

run_test "phase-registry: save-artifact accepts a registered custom phase" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$BIN/save-artifact.sh" audit-licenses "{\"phase\":\"audit-licenses\",\"summary\":{\"flagged\":[]},\"context_checkpoint\":{\"summary\":\"ok\"}}" >/dev/null
  test -d .nanostack/audit-licenses
  ls .nanostack/audit-licenses/*.json 2>/dev/null | head -1 | grep -q .
'

run_test "phase-registry: save-artifact rejects unregistered custom phase" '
  echo "{}" > .nanostack/config.json
  out=$("$BIN/save-artifact.sh" audit-licenses "{\"phase\":\"audit-licenses\",\"summary\":{},\"context_checkpoint\":{}}" 2>&1) && exit 1
  echo "$out" | grep -qF "invalid phase"
'

# ─── Custom phase resolver (PR 2) ──────────────────────────

run_test "resolve: core phase keeps phase_kind=core" '
  out=$("$BIN/resolve.sh" review 2>/dev/null)
  echo "$out" | jq -e ".phase_kind == \"core\"" >/dev/null
  echo "$out" | jq -e ".phase == \"review\"" >/dev/null
'

run_test "resolve: unregistered custom phase exits 1" '
  out=$("$BIN/resolve.sh" performance 2>&1) && exit 1
  echo "$out" | grep -qF "unknown phase"
'

run_test "resolve: registered custom phase exits 0 with phase_kind=custom" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  out=$("$BIN/resolve.sh" audit-licenses 2>/dev/null)
  echo "$out" | jq -e ".phase_kind == \"custom\"" >/dev/null
  echo "$out" | jq -e ".phase == \"audit-licenses\"" >/dev/null
  echo "$out" | jq -e ".upstream_artifacts == {}" >/dev/null
  echo "$out" | jq -e ".solutions == []" >/dev/null
  echo "$out" | jq -e ".diarizations == []" >/dev/null
'

run_test "resolve: phase_graph drives custom upstream_artifacts" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"],\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"plan\",\"depends_on\":[\"think\"]},{\"name\":\"build\",\"depends_on\":[\"plan\"]},{\"name\":\"audit-licenses\",\"depends_on\":[\"build\",\"plan\"]},{\"name\":\"ship\",\"depends_on\":[\"audit-licenses\"]}]}" > .nanostack/config.json
  "$BIN/save-artifact.sh" plan "{\"phase\":\"plan\",\"summary\":{\"goal\":\"x\",\"planned_files\":[],\"plan_approval\":\"manual\"},\"context_checkpoint\":{\"summary\":\"y\"}}" >/dev/null
  out=$("$BIN/resolve.sh" audit-licenses 2>/dev/null)
  echo "$out" | jq -e ".upstream_artifacts.build == null" >/dev/null
  echo "$out" | jq -e ".upstream_artifacts.plan | type == \"string\"" >/dev/null
'

run_test "resolve: SKILL.md frontmatter inline-list deps fallback" '
  mkdir -p .nanostack/skills/audit-licenses
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  cat > .nanostack/skills/audit-licenses/SKILL.md <<EOF
---
name: audit-licenses
depends_on: [plan, ship]
---
EOF
  out=$("$BIN/resolve.sh" audit-licenses 2>/dev/null)
  # ship was declared but never produced; should be null in output.
  echo "$out" | jq -e ".upstream_artifacts.ship == null" >/dev/null
  echo "$out" | jq -e ".upstream_artifacts | has(\"plan\")" >/dev/null
'

run_test "resolve: SKILL.md frontmatter block-list deps fallback" '
  mkdir -p .nanostack/skills/audit-licenses
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  cat > .nanostack/skills/audit-licenses/SKILL.md <<EOF
---
name: audit-licenses
depends_on:
  - plan
  - ship
---
EOF
  out=$("$BIN/resolve.sh" audit-licenses 2>/dev/null)
  echo "$out" | jq -e ".upstream_artifacts | has(\"ship\")" >/dev/null
  echo "$out" | jq -e ".upstream_artifacts.ship == null" >/dev/null
'

run_test "analytics: --json includes custom + core_total + custom_total + total" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$BIN/save-artifact.sh" plan "{\"phase\":\"plan\",\"summary\":{\"goal\":\"x\",\"planned_files\":[],\"plan_approval\":\"manual\"},\"context_checkpoint\":{\"summary\":\"y\"}}" >/dev/null
  "$BIN/save-artifact.sh" audit-licenses "{\"phase\":\"audit-licenses\",\"summary\":{\"status\":\"OK\"},\"context_checkpoint\":{\"summary\":\"ok\"}}" >/dev/null
  out=$("$BIN/analytics.sh" --json)
  echo "$out" | jq -e ".sprints.plan == 1" >/dev/null
  echo "$out" | jq -e ".sprints.core_total == 1" >/dev/null
  echo "$out" | jq -e ".sprints.\"custom\".\"audit-licenses\" == 1" >/dev/null
  echo "$out" | jq -e ".sprints.custom_total == 1" >/dev/null
  echo "$out" | jq -e ".sprints.total == 2" >/dev/null
'

run_test "analytics: no custom phases registered keeps the historical shape" '
  echo "{}" > .nanostack/config.json
  "$BIN/save-artifact.sh" plan "{\"phase\":\"plan\",\"summary\":{\"goal\":\"x\",\"planned_files\":[],\"plan_approval\":\"manual\"},\"context_checkpoint\":{\"summary\":\"y\"}}" >/dev/null
  out=$("$BIN/analytics.sh" --json)
  # core fields unchanged
  echo "$out" | jq -e ".sprints.plan == 1" >/dev/null
  # total still equals core_total when no custom phases
  echo "$out" | jq -e ".sprints.total == .sprints.core_total" >/dev/null
  # custom is an empty object, custom_total is 0
  echo "$out" | jq -e ".sprints.custom == {}" >/dev/null
  echo "$out" | jq -e ".sprints.custom_total == 0" >/dev/null
'

run_test "sprint-journal: custom phase artifact emits a /<phase> section" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$BIN/save-artifact.sh" audit-licenses "{\"phase\":\"audit-licenses\",\"summary\":{\"status\":\"OK\",\"headline\":\"47 deps scanned\"},\"context_checkpoint\":{\"summary\":\"ok\"}}" >/dev/null
  journal=$("$BIN/sprint-journal.sh")
  test -f "$journal"
  grep -qF "## /audit-licenses" "$journal"
  grep -qF "**Status:** OK" "$journal"
  grep -qF "47 deps scanned" "$journal"
  grep -qF "**Artifact:**" "$journal"
'

run_test "sprint-journal: no custom artifact = no extra section" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$BIN/save-artifact.sh" plan "{\"phase\":\"plan\",\"summary\":{\"goal\":\"x\",\"planned_files\":[],\"plan_approval\":\"manual\"},\"context_checkpoint\":{\"summary\":\"y\"}}" >/dev/null
  journal=$("$BIN/sprint-journal.sh")
  ! grep -qF "## /audit-licenses" "$journal"
'

run_test "sprint-journal: custom artifact without status falls back to compact JSON" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$BIN/save-artifact.sh" audit-licenses "{\"phase\":\"audit-licenses\",\"summary\":{\"counts\":{\"permissive\":3}},\"context_checkpoint\":{\"summary\":\"ok\"}}" >/dev/null
  journal=$("$BIN/sprint-journal.sh")
  grep -qF "## /audit-licenses" "$journal"
  # The compact JSON dump should appear as a backticked summary line.
  grep -qE "Summary.*permissive" "$journal"
'

run_test "conductor: --phases inline JSON sets the sprint graph" '
  # Custom phase must be registered before the validator accepts it.
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$NANOSTACK_ROOT/conductor/bin/sprint.sh" start --phases "[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"plan\",\"depends_on\":[\"think\"]},{\"name\":\"build\",\"depends_on\":[\"plan\"]},{\"name\":\"audit-licenses\",\"depends_on\":[\"build\"]},{\"name\":\"ship\",\"depends_on\":[\"audit-licenses\"]}]" >/dev/null
  status_json=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" status)
  echo "$status_json" | jq -e ".phases | has(\"audit-licenses\")" >/dev/null
  echo "$status_json" | jq -e ".phases | has(\"think\")" >/dev/null
  echo "$status_json" | jq -e ".phases | length == 5" >/dev/null
'

run_test "conductor: --phases reads JSON from file" '
  echo "{}" > .nanostack/config.json
  graph_file=$(mktemp /tmp/cond-graph.XXXXXX.json)
  echo "[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"plan\",\"depends_on\":[\"think\"]},{\"name\":\"build\",\"depends_on\":[\"plan\"]},{\"name\":\"ship\",\"depends_on\":[\"build\"]}]" > "$graph_file"
  "$NANOSTACK_ROOT/conductor/bin/sprint.sh" start --phases "$graph_file" >/dev/null
  status_json=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" status)
  echo "$status_json" | jq -e ".phases | length == 4" >/dev/null
  echo "$status_json" | jq -e ".phases.think" >/dev/null
  rm -f "$graph_file"
'

run_test "conductor: phase_graph from .nanostack/config.json drives the sprint" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"],\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"audit-licenses\",\"depends_on\":[\"think\"]},{\"name\":\"ship\",\"depends_on\":[\"audit-licenses\"]}]}" > .nanostack/config.json
  "$NANOSTACK_ROOT/conductor/bin/sprint.sh" start >/dev/null
  status_json=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" status)
  echo "$status_json" | jq -e ".phases | length == 3" >/dev/null
  echo "$status_json" | jq -e ".phases | has(\"audit-licenses\")" >/dev/null
'

run_test "conductor: cycle in --phases is rejected (exit 2)" '
  out=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" start --phases "[{\"name\":\"think\",\"depends_on\":[\"plan\"]},{\"name\":\"plan\",\"depends_on\":[\"think\"]}]" 2>&1) && exit 1
  echo "$out" | grep -qF "invalid phase graph"
'

run_test "conductor: duplicate name in --phases is rejected (exit 2)" '
  out=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" start --phases "[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"think\",\"depends_on\":[]}]" 2>&1) && exit 1
  echo "$out" | grep -qF "invalid phase graph"
'

run_test "conductor: batch topologically sorts a misordered DAG" '
  # Custom graph in the wrong array order. cmd_batch must still emit
  # batches in dependency order (think before plan, plan before build,
  # etc.).
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  mkdir -p .nanostack/skills/audit-licenses
  printf "%s\n" "---" "name: audit-licenses" "concurrency: read" "depends_on: [build]" "---" \
    > .nanostack/skills/audit-licenses/SKILL.md
  "$NANOSTACK_ROOT/conductor/bin/sprint.sh" start \
    --phases "[{\"name\":\"ship\",\"depends_on\":[\"audit-licenses\"]},{\"name\":\"audit-licenses\",\"depends_on\":[\"build\"]},{\"name\":\"build\",\"depends_on\":[\"plan\"]},{\"name\":\"plan\",\"depends_on\":[\"think\"]},{\"name\":\"think\",\"depends_on\":[]}]" \
    >/dev/null
  out=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" batch)
  # First batch must contain think; ship cannot appear before
  # audit-licenses.
  first_phase=$(echo "$out" | head -1 | jq -r ".phases[0]")
  test "$first_phase" = "think"
  # Build must come before audit-licenses; audit-licenses before ship.
  build_line=$(echo "$out" | grep -nF "build" | head -1 | cut -d: -f1)
  audit_line=$(echo "$out" | grep -nF "audit-licenses" | head -1 | cut -d: -f1)
  ship_line=$(echo "$out" | grep -nF "\"ship\"" | head -1 | cut -d: -f1)
  test "$build_line" -lt "$audit_line"
  test "$audit_line" -lt "$ship_line"
'

run_test "conductor: invalid config.phase_graph aborts (fail-closed, no sprint created)" '
  # Cycle in config must abort — silent fallback to the default
  # graph would mask the real bug.
  printf %s "{\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[\"plan\"]},{\"name\":\"plan\",\"depends_on\":[\"think\"]}]}" > .nanostack/config.json
  if "$NANOSTACK_ROOT/conductor/bin/sprint.sh" start >/tmp/cs5-out 2>&1; then exit 1; fi
  grep -qF "invalid phase_graph" /tmp/cs5-out
  # status returns 0 with {"status":"no_sprint"} when no sprint
  # exists; assert the JSON content rather than the exit code.
  status_json=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" status 2>/dev/null)
  echo "$status_json" | jq -e ".status == \"no_sprint\"" >/dev/null
'

run_test "conductor: batch reads custom skill concurrency from configured skill_roots" '
  mkdir -p .nanostack/skills/audit-licenses
  cat > .nanostack/skills/audit-licenses/SKILL.md <<EOF
---
name: audit-licenses
concurrency: read
depends_on: [build]
---
EOF
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$NANOSTACK_ROOT/conductor/bin/sprint.sh" start --phases "[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"plan\",\"depends_on\":[\"think\"]},{\"name\":\"build\",\"depends_on\":[\"plan\"]},{\"name\":\"audit-licenses\",\"depends_on\":[\"build\"]},{\"name\":\"ship\",\"depends_on\":[\"audit-licenses\"]}]" >/dev/null
  out=$("$NANOSTACK_ROOT/conductor/bin/sprint.sh" batch 2>&1)
  # audit-licenses must appear in a read-typed batch.
  echo "$out" | grep -qE "\"phases\":\\[\"audit-licenses\"\\].*\"type\":\"read\"" || \
    echo "$out" | grep -qE "\"type\":\"read\".*\"phases\":\\[\"audit-licenses\"\\]"
'

run_test "discard-sprint: default --dry-run includes registered custom phase artifacts" '
  printf %s "{\"custom_phases\":[\"audit-licenses\"]}" > .nanostack/config.json
  "$BIN/save-artifact.sh" plan "{\"phase\":\"plan\",\"summary\":{\"goal\":\"x\",\"planned_files\":[],\"plan_approval\":\"manual\"},\"context_checkpoint\":{\"summary\":\"y\"}}" >/dev/null
  "$BIN/save-artifact.sh" audit-licenses "{\"phase\":\"audit-licenses\",\"summary\":{\"status\":\"OK\"},\"context_checkpoint\":{\"summary\":\"ok\"}}" >/dev/null
  out=$("$BIN/discard-sprint.sh" --dry-run)
  echo "$out" | grep -qF "audit-licenses"
  echo "$out" | grep -qF "plan"
'

run_test "resolve: phase_graph depends_on:[] wins over SKILL.md depends_on" '
  # The two cases (phase missing from graph) versus (phase listed in
  # graph with empty deps) must stay distinct. Otherwise SKILL.md
  # silently re-introduces deps the user explicitly removed.
  mkdir -p .nanostack/skills/audit-licenses
  cat > .nanostack/skills/audit-licenses/SKILL.md <<EOF
---
name: audit-licenses
depends_on: [plan, ship]
---
EOF
  printf %s "{\"custom_phases\":[\"audit-licenses\"],\"phase_graph\":[{\"name\":\"think\",\"depends_on\":[]},{\"name\":\"audit-licenses\",\"depends_on\":[]}]}" > .nanostack/config.json
  out=$("$BIN/resolve.sh" audit-licenses 2>/dev/null)
  echo "$out" | jq -e ".upstream_artifacts == {}" >/dev/null
'


nh_summary
