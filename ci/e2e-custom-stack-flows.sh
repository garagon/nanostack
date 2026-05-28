#!/usr/bin/env bash
# e2e-custom-stack-flows.sh — Custom Stack Framework v1, end-to-end.
#
# Runs the full new-user journey on a real /tmp project: scaffold a custom
# skill, validate it, run its helper, save/find/resolve an artifact, sprint
# journal, analytics, discard, conductor sprint + batch, agents/openai.yaml,
# store resolution (git root / subdir / no-git / spaces), and guard
# concurrency (read blocks, write allows, built-in still blocks, bundled
# precedence, no-shadow).
#
# Migrated onto ci/lib/harness.sh + ci/lib/fixtures.sh (Harness vNext
# PR 2). Same cells, same check count (40). Git projects come from
# nf_new_git_project; the create-skill / conductor / guard flows and the
# minimal current_phase-only sessions (which are themselves under test)
# stay explicit. Cells 1-12 are a sequential journey over one project;
# cells 13-22 build their own. Supports --filter <pattern>.
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"
. "$REPO/ci/lib/fixtures.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init custom-stack nanostack-cs-flows
nh_require_cmd git jq node

# Shared project for the sequential journey (cells 1-12).
PROJ=$(nf_new_git_project project)
cd "$PROJ"

# Cell 1: scaffold a new custom skill via bin/create-skill.sh.
cell_scaffold() {
  cd "$PROJ"
  "$REPO/bin/create-skill.sh" license-audit --concurrency read --depends-on build >/dev/null
  nh_assert_true "skill directory exists" test -d ".nanostack/skills/license-audit"
  nh_assert_true "phase registered in config" \
    bash -c 'jq -e ".custom_phases | index(\"license-audit\")" .nanostack/config.json >/dev/null'
}

# Cell 2: bin/check-custom-skill.sh passes on the scaffolded skill.
cell_validate() {
  cd "$PROJ"
  local out; out=$( "$REPO/bin/check-custom-skill.sh" .nanostack/skills/license-audit 2>&1 )
  nh_assert_true "check-custom-skill ends with OK summary" \
    bash -c "printf '%s\n' '$out' | tail -1 | grep -qE '^OK:'"
}

# Cell 3: helper script runs from its copied location.
cell_helper_runs() {
  cd "$PROJ"
  printf '%s\n' '{"name":"e2e","dependencies":{"lodash":"4.17.21"}}' > package.json
  local audit_json; audit_json=$( ".nanostack/skills/license-audit/bin/audit.sh" node 2>/dev/null )
  nh_assert_true "helper emits .counts" bash -c "echo '$audit_json' | jq -e '.counts' >/dev/null"
}

# Cell 4: save + find artifact.
cell_save_find() {
  cd "$PROJ"
  "$REPO/bin/save-artifact.sh" license-audit \
    '{"phase":"license-audit","summary":{"status":"OK","headline":"e2e smoke"},"context_checkpoint":{"summary":"saved"}}' >/dev/null
  local found; found=$( "$REPO/bin/find-artifact.sh" license-audit 30 2>/dev/null )
  nh_assert_true "find-artifact returns a file" test -f "$found"
  nh_assert_true "saved artifact has phase=license-audit" \
    bash -c "jq -e '.phase == \"license-audit\"' '$found' >/dev/null"
}

# Cell 5: resolver classifies the phase as custom.
cell_resolve_kind() {
  cd "$PROJ"
  local resolved; resolved=$( "$REPO/bin/resolve.sh" license-audit 2>/dev/null )
  nh_assert_eq "phase_kind == custom" "custom" "$( echo "$resolved" | jq -r '.phase_kind' )"
}

# Cell 6: sprint journal includes a /<phase> section.
cell_journal() {
  cd "$PROJ"
  local journal; journal=$( "$REPO/bin/sprint-journal.sh" )
  nh_assert_true "journal file exists" test -f "$journal"
  nh_assert_true "journal includes /license-audit" bash -c "grep -qF '## /license-audit' '$journal'"
  nh_assert_true "journal mentions e2e smoke headline" bash -c "grep -qF 'e2e smoke' '$journal'"
}

# Cell 7: analytics --json includes the custom count.
cell_analytics() {
  cd "$PROJ"
  local analytics; analytics=$( "$REPO/bin/analytics.sh" --json )
  nh_assert_true "analytics.sprints.custom.license-audit >= 1" \
    bash -c "echo '$analytics' | jq -e '.sprints.\"custom\".\"license-audit\" >= 1' >/dev/null"
  nh_assert_true "analytics.sprints.total >= 1" \
    bash -c "echo '$analytics' | jq -e '.sprints.total >= 1' >/dev/null"
}

# Cell 8: default discard --dry-run lists the custom artifact.
cell_discard() {
  cd "$PROJ"
  local discard_out; discard_out=$( "$REPO/bin/discard-sprint.sh" --dry-run )
  nh_assert_true "dry-run includes license-audit" bash -c "echo '$discard_out' | grep -qF 'license-audit'"
}

# Cell 9: conductor sprint includes the custom phase via --phases.
cell_conductor_sprint() {
  cd "$PROJ"
  "$REPO/conductor/bin/sprint.sh" start \
    --phases '[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"license-audit","depends_on":["build"]},{"name":"ship","depends_on":["license-audit"]}]' \
    >/dev/null
  local sprint_status; sprint_status=$( "$REPO/conductor/bin/sprint.sh" status )
  nh_assert_true "conductor.phases has license-audit" \
    bash -c "echo '$sprint_status' | jq -e '.phases | has(\"license-audit\")' >/dev/null"
  nh_assert_true "conductor sprint has 5 phases" \
    bash -c "echo '$sprint_status' | jq -e '.phases | length == 5' >/dev/null"
}

# Cell 10: cmd_batch reads the custom skill's concurrency.
cell_conductor_batch() {
  cd "$PROJ"
  local batch_out; batch_out=$( "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
  nh_assert_true "license-audit appears in a type=read batch" \
    bash -c "echo '$batch_out' | grep -qE '\"phases\":\\[[^]]*\"license-audit\"[^]]*\\].*\"type\":\"read\"|\"type\":\"read\".*\"phases\":\\[[^]]*\"license-audit\"'"
}

# Cell 11: agents/openai.yaml is present with the three discovery keys.
cell_openai_yaml() {
  cd "$PROJ"
  local root="${NANOSTACK_STORE:-$PROJ/.nanostack}/skills"
  [ -d "$root/license-audit/agents" ] || root="$PROJ/.nanostack/skills"
  nh_assert_true "openai.yaml exists" test -f "$root/license-audit/agents/openai.yaml"
  nh_assert_true "openai.yaml has display_name + short_description + default_prompt" \
    bash -c "grep -qE '^[[:space:]]+display_name:' '$root/license-audit/agents/openai.yaml' && grep -qE '^[[:space:]]+short_description:' '$root/license-audit/agents/openai.yaml' && grep -qE '^[[:space:]]+default_prompt:' '$root/license-audit/agents/openai.yaml'"
}

# Cell 12: copied skill has no repo-relative example paths.
cell_no_example_leak() {
  cd "$PROJ"
  nh_assert_true "SKILL.md has no ./examples/custom-skill-template/ leak" \
    bash -c "! grep -qE '\\./examples/custom-skill-template/' .nanostack/skills/license-audit/SKILL.md"
}

# Cell 13: create-skill resolves the store from a subdirectory.
cell_store_subdir() {
  local sub; sub=$(nf_new_git_project subdir-project)
  mkdir -p "$sub/src/feature"
  cd "$sub/src/feature"
  "$REPO/bin/create-skill.sh" subdir-skill --concurrency read >/dev/null
  nh_assert_true "skill landed in repo root, not in src/feature" \
    test -f "$sub/.nanostack/skills/subdir-skill/SKILL.md"
  nh_assert_true "no rogue .nanostack inside src/feature" \
    bash -c "! test -d '$sub/src/feature/.nanostack'"
  local out; out=$( "$REPO/bin/check-custom-skill.sh" "$sub/.nanostack/skills/subdir-skill" 2>&1 )
  nh_assert_true "check-custom-skill passes from a subdir scaffold" \
    bash -c "echo '$out' | tail -1 | grep -qE '^OK:'"
  "$REPO/conductor/bin/sprint.sh" start \
    --phases '[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"subdir-skill","depends_on":["build"]},{"name":"ship","depends_on":["subdir-skill"]}]' \
    >/dev/null
  local sub_batch; sub_batch=$( "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
  nh_assert_true "subdir conductor reads SKILL.md (no 'no SKILL.md' warning)" \
    bash -c "! echo '$sub_batch' | grep -qF 'no SKILL.md found'"
  nh_assert_true "subdir conductor schedules subdir-skill as type=read" \
    bash -c "echo '$sub_batch' | grep -qE '\"phases\":\\[[^]]*\"subdir-skill\"[^]]*\\].*\"type\":\"read\"|\"type\":\"read\".*\"phases\":\\[[^]]*\"subdir-skill\"'"
}

# Cell 14: create-skill resolves the store outside git (fake HOME).
cell_store_nogit() {
  local nh np; nh="$NH_TMP/nogit-home"; np="$NH_TMP/nogit-project"
  mkdir -p "$nh" "$np"
  cd "$np"
  HOME="$nh" "$REPO/bin/create-skill.sh" nogit-skill --concurrency read >/dev/null
  nh_assert_true "skill landed in fake-HOME store, not cwd" \
    test -f "$nh/.nanostack/skills/nogit-skill/SKILL.md"
  nh_assert_true "no rogue .nanostack inside the cwd" bash -c "! test -d '$np/.nanostack'"
  local out; out=$( HOME="$nh" "$REPO/bin/check-custom-skill.sh" "$nh/.nanostack/skills/nogit-skill" 2>&1 )
  nh_assert_true "check-custom-skill passes outside git" \
    bash -c "echo '$out' | tail -1 | grep -qE '^OK:'"
  HOME="$nh" "$REPO/conductor/bin/sprint.sh" start \
    --phases '[{"name":"think","depends_on":[]},{"name":"build","depends_on":["think"]},{"name":"nogit-skill","depends_on":["build"]},{"name":"ship","depends_on":["nogit-skill"]}]' \
    >/dev/null
  local nogit_batch; nogit_batch=$( HOME="$nh" "$REPO/conductor/bin/sprint.sh" batch 2>&1 )
  nh_assert_true "no-git conductor reads SKILL.md (no 'no SKILL.md' warning)" \
    bash -c "! echo '$nogit_batch' | grep -qF 'no SKILL.md found'"
  nh_assert_true "no-git conductor schedules nogit-skill as type=read" \
    bash -c "echo '$nogit_batch' | grep -qE '\"phases\":\\[[^]]*\"nogit-skill\"[^]]*\\].*\"type\":\"read\"|\"type\":\"read\".*\"phases\":\\[[^]]*\"nogit-skill\"'"
}

# Cell 15: validator rejects a mismatched frontmatter name.
cell_validator_name_mismatch() {
  local dh dp; dh="$NH_TMP/drift-home"; dp="$NH_TMP/drift-project"
  mkdir -p "$dh" "$dp"
  cd "$dp"
  HOME="$dh" "$REPO/bin/create-skill.sh" license-audit >/dev/null
  local skill="$dh/.nanostack/skills/license-audit"
  sed 's/^name:.*/name: audit-licenses/' "$skill/SKILL.md" > "$skill/SKILL.md.tmp"
  mv "$skill/SKILL.md.tmp" "$skill/SKILL.md"
  nh_assert_false "check-custom-skill rejects mismatched frontmatter name" \
    env HOME="$dh" "$REPO/bin/check-custom-skill.sh" "$skill"
}

# Build a guard fixture: a git project with the license-audit custom phase
# (concurrency: read) registered via create-skill, and a current_phase
# session. Sets GUARD_PROJ / GUARD_STORE / GUARD_HOME so each guard cell is
# self-contained (works standalone under --filter).
make_guard_project() {
  local name="$1"
  GUARD_HOME="$NH_TMP/$name-home"
  GUARD_PROJ=$(nf_new_git_project "$name")
  cd "$GUARD_PROJ"  # create-skill resolves the store from the git root of cwd
  HOME="$GUARD_HOME" "$REPO/bin/create-skill.sh" license-audit --concurrency read >/dev/null
  GUARD_STORE="$GUARD_PROJ/.nanostack"
  [ -d "$GUARD_STORE/skills/license-audit" ] || GUARD_STORE="$GUARD_HOME/.nanostack"
  echo '{"current_phase":"license-audit"}' > "$GUARD_STORE/session.json"
}

# Cell 16: guard blocks writes during a read-only custom phase (incl. the
# in-project bypass: ./ prefix + absolute in-project path).
cell_guard_custom_read() {
  make_guard_project guard-read
  cd "$GUARD_PROJ"
  local c
  for c in "touch should-not-pass" "touch ./should-not-pass" "touch $GUARD_PROJ/should-not-pass"; do
    nh_assert_exit "blocks: $c" 1 env NANOSTACK_STORE="$GUARD_STORE" HOME="$GUARD_HOME" "$REPO/guard/bin/check-dangerous.sh" "$c"
  done
}

# Cell 17: switching the same phase to concurrency: write lifts the block.
cell_guard_custom_write() {
  make_guard_project guard-write
  local t="$GUARD_STORE/skills/license-audit/SKILL.md"
  sed 's/^concurrency: read$/concurrency: write/' "$t" > "$t.tmp"; mv "$t.tmp" "$t"
  local outdir; outdir=$(mktemp -d /tmp/guard-outside.XXXXXX)
  nh_assert_exit "custom write phase does not block on concurrency (exit 0)" 0 \
    env NANOSTACK_STORE="$GUARD_STORE" HOME="$GUARD_HOME" "$REPO/guard/bin/check-dangerous.sh" "touch $outdir/x"
  rm -rf "$outdir"
}

# Cell 18: built-in read phases keep working unchanged.
cell_guard_builtin() {
  make_guard_project guard-builtin
  echo '{"current_phase":"review"}' > "$GUARD_STORE/session.json"
  nh_assert_exit "built-in review phase blocks write (exit 1)" 1 \
    env NANOSTACK_STORE="$GUARD_STORE" HOME="$GUARD_HOME" "$REPO/guard/bin/check-dangerous.sh" "touch should-not-pass"
}

# Cell 19: guard finds repo-bundled non-core skills (feature, doctor).
cell_guard_bundled() {
  local bp; bp=$(nf_new_git_project bundled-project)
  nf_new_store "$bp" >/dev/null
  cd "$bp"
  local b
  for b in feature doctor; do
    echo "{\"current_phase\":\"$b\"}" > "$bp/.nanostack/session.json"
    nh_assert_exit "bundled $b phase blocks write" 1 \
      env NANOSTACK_STORE="$bp/.nanostack" "$REPO/guard/bin/check-dangerous.sh" "touch should-not-pass"
  done
}

# Cell 20: a registered custom phase that reuses a bundled name wins.
cell_guard_precedence() {
  local pp; pp=$(nf_new_git_project precedence-project)
  mkdir -p "$pp/.nanostack/skills/feature"
  printf '%s\n' '{"custom_phases":["feature"]}' > "$pp/.nanostack/config.json"
  printf '%s\n' '---' 'name: feature' 'description: user-registered feature override' 'concurrency: write' '---' 'body' \
    > "$pp/.nanostack/skills/feature/SKILL.md"
  echo '{"current_phase":"feature"}' > "$pp/.nanostack/session.json"
  local outdir; outdir=$(mktemp -d /tmp/precedence-out.XXXXXX)
  nh_assert_exit "custom feature (write) shadows bundled feature (read)" 0 \
    env NANOSTACK_STORE="$pp/.nanostack" "$REPO/guard/bin/check-dangerous.sh" "touch $outdir/x"
  rm -rf "$outdir"
}

# Cell 21: an unrelated user-installed skill does not shadow a bundled phase.
cell_guard_no_shadow() {
  local sh sp; sh="$NH_TMP/shadow-home"; sp=$(nf_new_git_project shadow-project)
  nf_new_store "$sp" >/dev/null
  mkdir -p "$sh/.claude/skills/feature"
  printf '%s\n' '---' 'name: feature' 'description: unrelated user-installed skill (no registration)' 'concurrency: write' '---' 'body' \
    > "$sh/.claude/skills/feature/SKILL.md"
  cd "$sp"
  echo '{"current_phase":"feature"}' > "$sp/.nanostack/session.json"
  nh_assert_exit "bundled feature still wins when no registered custom" 1 \
    env HOME="$sh" NANOSTACK_STORE="$sp/.nanostack" "$REPO/guard/bin/check-dangerous.sh" "touch x"
}

# Cell 22: a store path containing a space must not break the guard.
cell_guard_space_path() {
  local stmp sh sp; stmp=$(mktemp -d /tmp/nanostack-space.XXXXXX)
  sh="$stmp/home with space"; sp="$stmp/nogit"
  mkdir -p "$sh" "$sp"
  cd "$sp"
  HOME="$sh" "$REPO/bin/create-skill.sh" license-audit --concurrency read >/dev/null
  local store="$sh/.nanostack"
  echo '{"current_phase":"license-audit"}' > "$store/session.json"
  nh_assert_exit "store path with space still blocks (exit 1)" 1 \
    env NANOSTACK_STORE="$store" HOME="$sh" "$REPO/guard/bin/check-dangerous.sh" "touch should-not-pass"
  rm -rf "$stmp"
}


nh_cell scaffold              cell_scaffold
nh_cell validate             cell_validate
nh_cell helper-runs          cell_helper_runs
nh_cell save-find            cell_save_find
nh_cell resolve-kind         cell_resolve_kind
nh_cell journal              cell_journal
nh_cell analytics            cell_analytics
nh_cell discard              cell_discard
nh_cell conductor-sprint     cell_conductor_sprint
nh_cell conductor-batch      cell_conductor_batch
nh_cell openai-yaml          cell_openai_yaml
nh_cell no-example-leak      cell_no_example_leak
nh_cell store-subdir         cell_store_subdir
nh_cell store-nogit          cell_store_nogit
nh_cell validator-name-mismatch cell_validator_name_mismatch
nh_cell guard-custom-read    cell_guard_custom_read
nh_cell guard-custom-write   cell_guard_custom_write
nh_cell guard-builtin        cell_guard_builtin
nh_cell guard-bundled        cell_guard_bundled
nh_cell guard-precedence     cell_guard_precedence
nh_cell guard-no-shadow      cell_guard_no_shadow
nh_cell guard-space-path     cell_guard_space_path

nh_summary
