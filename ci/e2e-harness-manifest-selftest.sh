#!/usr/bin/env bash
# e2e-harness-manifest-selftest.sh — Sabotage tests for the manifest check.
#
# Harness Architecture vNext PR 3 (2026-05-28). Proves ci/check-harness-
# manifest.sh fails closed on every drift direction. Each cell builds a
# minimal fake repo root (its own ci/, .github/workflows/, manifest, and a
# copy of the real checker) so the checker resolves ROOT to the fake tree,
# then sabotages one thing and asserts a non-zero exit plus the matching
# message. A baseline cell proves a consistent tree passes.
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

nh_init harness-manifest-selftest nanostack-manifest-selftest
nh_require_cmd jq

CHECK="$REPO/ci/check-harness-manifest.sh"

# Build a minimal, internally-consistent fake root. Echoes its path.
build_fake_root() {
  local root="$NH_TMP/$1"
  mkdir -p "$root/ci" "$root/.github/workflows"
  cp "$CHECK" "$root/ci/check-harness-manifest.sh"
  : > "$root/ci/e2e-foo.sh"
  cat > "$root/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: ci/e2e-foo.sh
EOF
  cat > "$root/ci/harnesses.json" <<'EOF'
{
  "schema_version": 1,
  "suites": [
    {"id":"foo","path":"ci/e2e-foo.sh","kind":"runtime-e2e","tier":"opt-in","surface":["x"],"deps":["bash"],"expected_checks":1,"timeout_minutes":1,"workflow":".github/workflows/e2e.yml","job":"e2e-foo"},
    {"id":"checker","path":"ci/check-harness-manifest.sh","kind":"static-contract","tier":"local","surface":["x"],"deps":["bash","jq"],"expected_checks":0,"timeout_minutes":1}
  ]
}
EOF
  printf '%s' "$root"
}

run_check() {  # echoes combined output; sets RC
  local root="$1"
  CK_OUT=$(bash "$root/ci/check-harness-manifest.sh" 2>&1); RC=$?
}

CK_OUT=""; RC=""

cell_baseline() {
  local r; r=$(build_fake_root baseline)
  run_check "$r"
  nh_assert_eq "consistent tree passes (rc 0)" "0" "$RC"
}

cell_unregistered() {
  local r; r=$(build_fake_root unregistered)
  : > "$r/ci/e2e-bar.sh"   # on disk but not in the manifest
  run_check "$r"
  nh_assert_eq "unregistered e2e-*.sh fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the unregistered path" "$CK_OUT" "unregistered harness"
}

cell_missing_path() {
  local r; r=$(build_fake_root missing-path)
  rm -f "$r/ci/e2e-foo.sh"   # manifest references it, file gone
  run_check "$r"
  nh_assert_eq "manifest path that does not exist fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the missing path" "$CK_OUT" "path does not exist"
}

cell_missing_metadata() {
  local r; r=$(build_fake_root missing-meta)
  jq 'del(.suites[0].kind)' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "missing required field fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the missing field" "$CK_OUT" "missing string field: kind"
}

cell_bad_enum() {
  local r; r=$(build_fake_root bad-enum)
  jq '.suites[0].kind="bogus"' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "kind not in enum fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the bad enum" "$CK_OUT" "not in enum"
}

cell_missing_job() {
  local r; r=$(build_fake_root missing-job)
  jq '.suites[0].job="does-not-exist"' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "manifest job missing from workflow fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the missing job" "$CK_OUT" "not found in"
}

cell_workflow_dead_path() {
  local r; r=$(build_fake_root dead-path)
  # A workflow job that runs a harness that does not exist on disk.
  printf '      - run: ci/e2e-ghost.sh\n' >> "$r/.github/workflows/e2e.yml"
  run_check "$r"
  nh_assert_eq "workflow run-line to a deleted harness fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the dead workflow path" "$CK_OUT" "does not exist: ci/e2e-ghost.sh"
}

cell_dead_path_yaml() {
  local r; r=$(build_fake_root dead-path-yaml)
  # Same drift but in a .yaml (not .yml) workflow: GitHub loads both.
  cat > "$r/.github/workflows/extra.yaml" <<'EOF'
name: extra
on:
  pull_request:
jobs:
  extra-job:
    runs-on: ubuntu-latest
    steps:
      - run: ci/check-ghost.sh
EOF
  run_check "$r"
  nh_assert_eq ".yaml workflow run-line to a deleted harness fails (rc 1)" "1" "$RC"
  nh_assert_contains "scans .yaml workflows too" "$CK_OUT" "does not exist: ci/check-ghost.sh"
}

cell_event_key_not_job() {
  local r; r=$(build_fake_root event-key)
  # Point the suite's job at an `on:` event key (workflow_dispatch). It is
  # NOT a job, so this must fail rather than matching the event key.
  jq '.suites[0].job="workflow_dispatch"' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  # Make the workflow have a workflow_dispatch trigger at on: level.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
EOF
  run_check "$r"
  nh_assert_eq "an on: event key is not accepted as a job (rc 1)" "1" "$RC"
  nh_assert_contains "reports the event key is not a job" "$CK_OUT" "not found in"
}

cell_job_exists_but_idle() {
  local r; r=$(build_fake_root job-idle)
  # The job key exists but no longer runs the harness (run step removed).
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: echo nothing
EOF
  run_check "$r"
  nh_assert_eq "job that exists but does not run the harness fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the job does not run the path" "$CK_OUT" "does not run ci/e2e-foo.sh"
}

cell_path_in_comment_only() {
  local r; r=$(build_fake_root path-comment)
  # The job mentions the harness path only in a comment, never runs it.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      # ci/e2e-foo.sh used to run here
      - run: echo nothing
EOF
  run_check "$r"
  nh_assert_eq "harness path only in a comment fails (rc 1)" "1" "$RC"
  nh_assert_contains "comment reference does not count as a run" "$CK_OUT" "does not run ci/e2e-foo.sh"
}

cell_chmod_only() {
  local r; r=$(build_fake_root chmod-only)
  # The job only chmods the harness; it never executes it.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: chmod +x ci/e2e-foo.sh
EOF
  run_check "$r"
  nh_assert_eq "chmod-only mention does not count as running (rc 1)" "1" "$RC"
  nh_assert_contains "chmod prep is not an invocation" "$CK_OUT" "does not run ci/e2e-foo.sh"
}

cell_syntax_check_only() {
  local r; r=$(build_fake_root syntax-only)
  # The job only syntax-checks the harness (bash -n), never runs it.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: bash -n ci/e2e-foo.sh
EOF
  run_check "$r"
  nh_assert_eq "bash -n syntax check does not count as running (rc 1)" "1" "$RC"
  nh_assert_contains "syntax check is not an invocation" "$CK_OUT" "does not run ci/e2e-foo.sh"
}

cell_runner_dry_run() {
  local r; r=$(build_fake_root runner-dryrun)
  # The job invokes the runner for this suite but only in --dry-run mode.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: ci/run-harness.sh --suite foo --dry-run
EOF
  run_check "$r"
  nh_assert_eq "runner --dry-run does not count as running (rc 1)" "1" "$RC"
  nh_assert_contains "non-executing runner mode is rejected" "$CK_OUT" "does not run ci/e2e-foo.sh"
}

cell_runner_executes() {
  local r; r=$(build_fake_root runner-exec)
  # A real runner invocation (no non-executing flag) DOES count.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: ci/run-harness.sh --suite foo
EOF
  run_check "$r"
  nh_assert_eq "real runner --suite invocation counts (rc 0)" "0" "$RC"
}

cell_noncov_missing_wiring() {
  local r; r=$(build_fake_root noncov)
  # An opt-in suite that drops both workflow and job must fail: only local
  # suites may be un-wired.
  jq 'del(.suites[0].workflow) | del(.suites[0].job)' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "opt-in suite without workflow/job fails (rc 1)" "1" "$RC"
  nh_assert_contains "non-local suite must be CI-wired" "$CK_OUT" "must declare workflow and job"
}

cell_local_may_omit_wiring() {
  local r; r=$(build_fake_root local-omit)
  # A local-tier suite may legitimately omit workflow/job.
  jq '.suites[0].tier="local" | del(.suites[0].workflow) | del(.suites[0].job)' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "local suite without workflow/job passes (rc 0)" "0" "$RC"
}

cell_pr_tier_dispatch_workflow() {
  local r; r=$(build_fake_root pr-dispatch)
  # foo is tier=pr but the fake e2e.yml is workflow_dispatch-only.
  jq '.suites[0].tier="pr"' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "tier=pr on a workflow_dispatch-only workflow fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the trigger/tier mismatch" "$CK_OUT" "no pull_request trigger"
}

cell_pr_tier_missing_push() {
  local r; r=$(build_fake_root pr-no-push)
  # tier=pr but the workflow only triggers on pull_request (no push).
  jq '.suites[0].tier="pr"' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  pull_request:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: ci/e2e-foo.sh
EOF
  run_check "$r"
  nh_assert_eq "tier=pr with pull_request but no push fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the missing push trigger" "$CK_OUT" "no push trigger"
}

cell_optin_tier_pr_workflow() {
  local r; r=$(build_fake_root optin-pr)
  # foo stays opt-in but the workflow is changed to pull_request-triggered.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  pull_request:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: ci/e2e-foo.sh
EOF
  run_check "$r"
  nh_assert_eq "tier=opt-in on a pull_request workflow fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports opt-in has a non-manual trigger" "$CK_OUT" "non-manual trigger 'pull_request'"
}

cell_tests_e2e_unregistered() {
  local r; r=$(build_fake_root tests-e2e)
  mkdir -p "$r/tests"; : > "$r/tests/e2e-extra.sh"   # exists but not registered
  run_check "$r"
  nh_assert_eq "unregistered tests/e2e-*.sh fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the unregistered tests harness" "$CK_OUT" "tests/e2e-extra.sh exists but is not registered"
}

cell_optin_schedule_trigger() {
  local r; r=$(build_fake_root optin-schedule)
  # opt-in workflow gains an automatic (schedule) trigger -> no longer manual-only.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
  schedule:
    - cron: "0 0 * * *"
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: ci/e2e-foo.sh
EOF
  run_check "$r"
  nh_assert_eq "opt-in workflow with a schedule trigger fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the non-manual trigger" "$CK_OUT" "non-manual trigger 'schedule'"
}

cell_optin_workflow_call() {
  local r; r=$(build_fake_root optin-call)
  # opt-in via a reusable workflow_call-only workflow is manual-only -> OK.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_call:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - run: ci/e2e-foo.sh
EOF
  run_check "$r"
  nh_assert_eq "opt-in via workflow_call-only passes (rc 0)" "0" "$RC"
}

cell_local_with_wiring() {
  local r; r=$(build_fake_root local-wired)
  # A local-tier suite must NOT be CI-wired.
  jq '.suites[0].tier="local"' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "local suite that is CI-wired fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports local must not be CI-wired" "$CK_OUT" "must not be CI-wired"
}

cell_path_as_data_not_run() {
  local r; r=$(build_fake_root path-data)
  # The path appears only as data in a with: block, never in a run: step.
  cat > "$r/.github/workflows/e2e.yml" <<'EOF'
name: e2e
on:
  workflow_dispatch:
jobs:
  e2e-foo:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/upload-artifact@v4
        with:
          path: ci/e2e-foo.sh
EOF
  run_check "$r"
  nh_assert_eq "path as with: data (no run) fails (rc 1)" "1" "$RC"
  nh_assert_contains "data reference is not a run" "$CK_OUT" "does not run ci/e2e-foo.sh"
}

cell_duplicate_id() {
  local r; r=$(build_fake_root dup-id)
  jq '.suites += [.suites[0]]' "$r/ci/harnesses.json" > "$r/ci/harnesses.json.tmp"
  mv "$r/ci/harnesses.json.tmp" "$r/ci/harnesses.json"
  run_check "$r"
  nh_assert_eq "duplicate suite id fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports the duplicate id" "$CK_OUT" "duplicate suite id"
}

cell_tests_run_unregistered() {
  local r; r=$(build_fake_root tests-run)
  mkdir -p "$r/tests"; : > "$r/tests/run.sh"   # exists but not in manifest
  run_check "$r"
  nh_assert_eq "unregistered tests/run.sh fails (rc 1)" "1" "$RC"
  nh_assert_contains "reports tests/run.sh" "$CK_OUT" "tests/run.sh exists but is not registered"
}

nh_cell baseline                 cell_baseline
nh_cell unregistered             cell_unregistered
nh_cell missing-path             cell_missing_path
nh_cell missing-metadata         cell_missing_metadata
nh_cell bad-enum                 cell_bad_enum
nh_cell missing-job              cell_missing_job
nh_cell workflow-dead-path       cell_workflow_dead_path
nh_cell dead-path-yaml           cell_dead_path_yaml
nh_cell event-key-not-job        cell_event_key_not_job
nh_cell job-exists-but-idle      cell_job_exists_but_idle
nh_cell path-in-comment-only     cell_path_in_comment_only
nh_cell chmod-only               cell_chmod_only
nh_cell syntax-check-only        cell_syntax_check_only
nh_cell runner-dry-run           cell_runner_dry_run
nh_cell runner-executes          cell_runner_executes
nh_cell noncov-missing-wiring    cell_noncov_missing_wiring
nh_cell local-may-omit-wiring    cell_local_may_omit_wiring
nh_cell pr-tier-dispatch         cell_pr_tier_dispatch_workflow
nh_cell pr-tier-missing-push     cell_pr_tier_missing_push
nh_cell optin-tier-pr            cell_optin_tier_pr_workflow
nh_cell tests-e2e-unregistered   cell_tests_e2e_unregistered
nh_cell optin-schedule           cell_optin_schedule_trigger
nh_cell optin-workflow-call      cell_optin_workflow_call
nh_cell local-with-wiring        cell_local_with_wiring
nh_cell path-as-data             cell_path_as_data_not_run
nh_cell duplicate-id             cell_duplicate_id
nh_cell tests-run-unregistered   cell_tests_run_unregistered

nh_summary
