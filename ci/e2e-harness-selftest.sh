#!/usr/bin/env bash
# e2e-harness-selftest.sh — Validates ci/lib/harness.sh itself.
#
# Harness Architecture vNext PR 1 (2026-05-28). A shared harness bug can
# affect every suite, so the library ships with this self-test first. It
# exercises the library by running small "child" harness scripts as
# separate processes and asserting on their output and exit codes:
# pass/fail counters, nh_capture under `set -e`, nh_assert_exit, --filter
# skip accounting, NANOSTACK_KEEP_TMP=1, and the /tmp temp-root policy.
#
# This suite uses the harness to test the harness; the assertions about
# the library's behavior run against child processes, not this process.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$REPO/ci/lib/harness.sh"
. "$HARNESS"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init harness-selftest nanostack-harness-selftest
nh_require_cmd bash

# Run a child harness script body in its own process. Captures combined
# output into CH_OUT and exit code into CH_RC. Extra leading args (e.g.
# env assignments) are passed through before `bash`.
CH_OUT=""; CH_RC=""
run_child() {
  local body="$1"; shift
  nh_capture CH_OUT CH_RC "$@" bash -c "set -u; . '$HARNESS'; $body"
}

# Cell: pass/fail counters and summary exit code.
cell_counters() {
  run_child 'nh_init c1; nh_pass a; nh_pass b; nh_fail c; nh_summary'
  nh_assert_eq       "mixed run exits 1"                "1" "$CH_RC"
  nh_assert_contains "summary reports 1 failed of 3"    "$CH_OUT" "1 failed of 3 total"
  run_child 'nh_init c2; nh_pass only; nh_summary'
  nh_assert_eq       "all-pass run exits 0"             "0" "$CH_RC"
  nh_assert_contains "summary reports 1 checks passed"  "$CH_OUT" "1 checks passed, 0 failed"
}

# Cell: nh_assert_eq / nh_assert_contains pass AND fail paths.
cell_basic_asserts() {
  run_child 'nh_init c; nh_assert_eq same 1 1; nh_assert_eq diff 1 2; nh_summary'
  nh_assert_contains "assert_eq fail counted" "$CH_OUT" "1 failed of 2 total"
  run_child 'nh_init c; nh_assert_contains has abc b; nh_assert_contains hasnot abc z; nh_summary'
  nh_assert_contains "assert_contains fail counted" "$CH_OUT" "1 failed of 2 total"
}

# Cell: nh_capture is safe under set -e and records stdout + rc.
cell_capture_errexit() {
  # `false` must NOT abort the child despite set -e; the suite continues
  # and records the pass after the capture.
  run_child 'set -e; nh_init c; nh_capture o r false; echo "CAP rc=$r"; nh_pass after-capture; nh_summary'
  nh_assert_eq       "capture under set -e exits 0"   "0" "$CH_RC"
  nh_assert_contains "capture recorded rc=1 from false" "$CH_OUT" "CAP rc=1"
  nh_assert_contains "suite continued after capture"  "$CH_OUT" "after-capture"
  # Captures stdout content and a non-1 rc.
  run_child 'nh_init c; nh_capture o r bash -c "echo hello; exit 3"; echo "OUT=[$o] RC=$r"; nh_summary'
  nh_assert_contains "capture grabs stdout"   "$CH_OUT" "OUT=[hello]"
  nh_assert_contains "capture grabs exit code" "$CH_OUT" "RC=3"
}

# Cell: nh_assert_exit pass and fail.
cell_assert_exit() {
  run_child 'nh_init c; nh_assert_exit "want 2" 2 bash -c "exit 2"; nh_assert_exit "want 0" 0 bash -c "exit 1"; nh_summary'
  nh_assert_contains "assert_exit pass+fail counted" "$CH_OUT" "1 failed of 2 total"
  nh_assert_contains "assert_exit prints observed exit" "$CH_OUT" "want 2 (exit 2)"
}

# Cell: --filter runs only matching cells and counts skips separately.
cell_filter() {
  run_child 'nh_init c; nh_set_filter bbb;
    fa() { nh_pass a; }; fb() { nh_pass b; }; fc() { nh_pass c; };
    nh_cell aaa fa; nh_cell bbb fb; nh_cell ccc fc; nh_summary'
  nh_assert_eq       "filtered run exits 0"            "0" "$CH_RC"
  nh_assert_contains "only matching cell ran"          "$CH_OUT" "1 checks passed, 0 failed (2 skipped)"
}

# Cell: NANOSTACK_KEEP_TMP=1 preserves the temp root; default removes it.
cell_keep_tmp() {
  run_child 'nh_init keepchild; echo "TMP=$NH_TMP"; nh_pass x; nh_summary' env NANOSTACK_KEEP_TMP=1
  local kept
  kept=$(printf '%s\n' "$CH_OUT" | sed -n 's/^TMP=//p' | head -1)
  nh_assert_true "KEEP_TMP=1 preserves tmp root" test -d "$kept"
  [ -n "$kept" ] && rm -rf "$kept"

  run_child 'nh_init nokeepchild; echo "TMP=$NH_TMP"; nh_pass x; nh_summary'
  local gone
  gone=$(printf '%s\n' "$CH_OUT" | sed -n 's/^TMP=//p' | head -1)
  nh_assert_false "default removes tmp root" test -d "$gone"
}

# Cell: a pre-init EXIT trap is chained (not clobbered), and nh_atexit
# cleanups run at exit.
cell_trap_chaining() {
  run_child 'trap "echo PREV_TRAP_RAN" EXIT; nh_init c; echo "TMP=$NH_TMP"; nh_summary'
  nh_assert_contains "pre-init EXIT trap still runs" "$CH_OUT" "PREV_TRAP_RAN"
  # Distinguish a real run from a broken `eval` of the quoted trap literal,
  # which would emit a "command not found" error that still contains the
  # marker text.
  nh_assert_not_contains "chained trap is executed, not eval'd as a literal" "$CH_OUT" "not found"
  local t
  t=$(printf '%s\n' "$CH_OUT" | sed -n 's/^TMP=//p' | head -1)
  nh_assert_false "harness temp cleanup still ran despite chained trap" test -d "$t"
  run_child 'nh_init c; nh_atexit "echo ATEXIT_RAN"; nh_summary'
  nh_assert_contains "nh_atexit cleanup runs on exit" "$CH_OUT" "ATEXIT_RAN"
  # A failing nh_atexit command under set -e must not flip the exit code
  # or skip mandatory temp cleanup.
  run_child 'set -e; nh_init c; nh_atexit false; echo "TMP=$NH_TMP"; nh_pass x; nh_summary'
  nh_assert_eq "failing nh_atexit keeps passing exit code" "0" "$CH_RC"
  local t2
  t2=$(printf '%s\n' "$CH_OUT" | sed -n 's/^TMP=//p' | head -1)
  nh_assert_false "failing nh_atexit still removed temp root" test -d "$t2"
}

# Cell: temp root is under /tmp, never $TMPDIR (/var/folders on macOS).
cell_tmp_policy() {
  run_child 'nh_init tmpchild; echo "TMP=$NH_TMP"; nh_summary'
  local t
  t=$(printf '%s\n' "$CH_OUT" | sed -n 's/^TMP=//p' | head -1)
  case "$t" in
    /tmp/*) nh_pass "temp root is under /tmp ($t)" ;;
    *)      nh_fail "temp root is under /tmp" "got: $t" ;;
  esac
}

nh_cell counters       cell_counters
nh_cell basic-asserts  cell_basic_asserts
nh_cell capture-errexit cell_capture_errexit
nh_cell assert-exit    cell_assert_exit
nh_cell filter         cell_filter
nh_cell keep-tmp       cell_keep_tmp
nh_cell trap-chaining  cell_trap_chaining
nh_cell tmp-policy     cell_tmp_policy

nh_summary
