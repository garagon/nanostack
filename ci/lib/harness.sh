#!/usr/bin/env bash
# harness.sh — Shared test-harness core for nanostack CI suites.
#
# Harness Architecture vNext PR 1 (2026-05-28). Before this library every
# large suite owned its own PASS/FAIL counters, ANSI colors, assert_*
# helpers, set +e/-e capture blocks, and /tmp mktemp rationale. That
# duplication drifted (some used set -e, some not; some emitted totals
# differently) and made every set -e capture bug easy to reintroduce.
# This is the single tested primitive new suites source instead.
#
# Properties:
#   - Bash 3.2 compatible (no associative arrays, no `local -n`).
#   - Safe under `set -e` AND `set -u`: assertions never abort the suite
#     on failure (they count and continue), and command-running helpers
#     save/restore the caller's errexit state around the call.
#   - No external dependencies beyond what the suite itself needs.
#   - Temp roots live under /tmp, never $TMPDIR. On macOS $TMPDIR is
#     /var/folders/..., and the write guard correctly denies paths under
#     /var/, which would turn "write allowed" assertions into false
#     failures unrelated to what the suite is testing.
#   - Functions are namespaced `nh_` to avoid collisions with suite code.
#
# Public API:
#   nh_init <suite_id> [tmp_prefix]      init counters + /tmp root ($NH_TMP)
#   nh_atexit <command>                  register extra cleanup (runs at EXIT
#                                        before the temp root is removed)
#   nh_set_filter <pattern>              only run cells whose id matches
#   nh_require_cmd <cmd>...              hard-fail if a command is missing
#   nh_pass <label>                      record a pass
#   nh_fail <label> [detail]             record a fail
#   nh_assert_eq <label> <exp> <act>
#   nh_assert_true <label> <command>...
#   nh_assert_false <label> <command>...
#   nh_assert_contains <label> <hay> <needle>
#   nh_assert_not_contains <label> <hay> <needle>
#   nh_assert_file_contains <label> <file> <needle>
#   nh_assert_file_not_contains <label> <file> <needle>
#   nh_assert_jq_file <label> <file> <jq_expr>
#   nh_assert_exit <label> <expected_rc> <command>...
#   nh_capture <out_var> <rc_var> <command>...   stdout+stderr & rc, set -e safe
#   nh_cell <cell_id> <function_name>            run a cell unless filtered out
#   nh_should_run <cell_id>                       0 if it would run under filter
#   nh_summary                                    print totals; rc 1 if any fail
#
# Local helpers:
#   NANOSTACK_KEEP_TMP=1  keep the temp root after exit for inspection.
#   NO_COLOR / non-tty    suppress ANSI color.

# Idempotent: safe to source more than once in a process.
if [ "${_NH_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NH_LOADED=1

_NH_SUITE=""
_NH_CELL=""
_NH_PASS=0
_NH_FAIL=0
_NH_SKIP=0
_NH_FILTER="${NH_FILTER:-}"
_NH_PREV_EXIT_TRAP=""
_NH_ATEXIT=""
NH_TMP=""

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  _NH_GREEN=""; _NH_RED=""; _NH_DIM=""; _NH_NC=""
else
  _NH_GREEN=$'\033[0;32m'; _NH_RED=$'\033[0;31m'; _NH_DIM=$'\033[0;90m'; _NH_NC=$'\033[0m'
fi

# True (0) if errexit is currently on. Used to restore it after a helper
# deliberately runs a command that may fail.
_nh_errexit_on() { case "$-" in *e*) return 0 ;; *) return 1 ;; esac }

nh_init() {
  _NH_SUITE="${1:?nh_init requires a suite id}"
  local prefix="${2:-nanostack-$_NH_SUITE}"
  _NH_PASS=0; _NH_FAIL=0; _NH_SKIP=0
  NH_TMP="$(mktemp -d "/tmp/${prefix}.XXXXXX")"
  # Chain rather than clobber: capture any EXIT trap that existed before
  # nh_init so a suite that registered teardown earlier still runs. For
  # cleanup registered AFTER nh_init, suites must use nh_atexit (a raw
  # `trap ... EXIT` after this point would replace the harness cleanup).
  _NH_PREV_EXIT_TRAP="$(trap -p EXIT 2>/dev/null || true)"
  trap '_nh_cleanup' EXIT
  echo "${_NH_SUITE} harness"
  echo "tmp root: $NH_TMP"
  echo
}

# Register a command to run at EXIT (before the temp root is removed), so
# suites needing extra teardown do not have to overwrite the harness trap.
nh_atexit() {
  _NH_ATEXIT="${_NH_ATEXIT}${1}
"
}

_nh_cleanup() {
  # Preserve the exiting status: the EXIT trap must not change the script's
  # final exit code, and no individual cleanup step may abort the rest
  # (mandatory temp removal + trap chaining must always run). errexit is
  # disabled for the whole trap; we are on the exit path.
  local _rc=$?
  set +e
  # 1. Suite-registered cleanups run first (they may reference NH_TMP). Run
  #    them in a contained eval so a failing teardown cannot skip the
  #    mandatory steps below.
  [ -n "${_NH_ATEXIT:-}" ] && eval "$_NH_ATEXIT"
  # 2. Temp root.
  if [ "${NANOSTACK_KEEP_TMP:-0}" = "1" ]; then
    printf '%s[harness] NANOSTACK_KEEP_TMP=1 — kept tmp root: %s%s\n' "$_NH_DIM" "$NH_TMP" "$_NH_NC" >&2
  elif [ -n "$NH_TMP" ]; then
    rm -rf "$NH_TMP"
  fi
  # 3. Chain any EXIT trap that pre-existed nh_init. `trap -p` emits a
  #    re-installable, shell-quoted statement: trap -- 'ACTION' EXIT. To
  #    actually RUN the action we strip the `trap -- '` prefix and the
  #    `' EXIT` suffix (only when that exact shape matches) and eval the
  #    unquoted action.
  case "${_NH_PREV_EXIT_TRAP:-}" in
    "trap -- '"*"' EXIT")
      local _p="$_NH_PREV_EXIT_TRAP"
      _p="${_p#trap -- \'}"
      _p="${_p%\' EXIT}"
      eval "$_p"
      ;;
  esac
  return "$_rc"
}

nh_set_filter() { _NH_FILTER="$1"; }

nh_require_cmd() {
  local missing="" c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="${missing:+$missing }$c"
  done
  if [ -n "$missing" ]; then
    printf '%sMISSING REQUIRED: %s (suite %s cannot run)%s\n' "$_NH_RED" "$missing" "$_NH_SUITE" "$_NH_NC" >&2
    exit 1
  fi
}

nh_pass() {
  _NH_PASS=$((_NH_PASS + 1))
  printf '    %sOK%s    %s\n' "$_NH_GREEN" "$_NH_NC" "$1"
}

nh_fail() {
  _NH_FAIL=$((_NH_FAIL + 1))
  printf '    %sFAIL%s  %s\n' "$_NH_RED" "$_NH_NC" "$1"
  [ -n "${2:-}" ] && printf '          %s%s%s\n' "$_NH_DIM" "$2" "$_NH_NC"
  printf '          %ssuite=%s cell=%s tmp=%s%s\n' \
    "$_NH_DIM" "$_NH_SUITE" "${_NH_CELL:-<none>}" "$NH_TMP" "$_NH_NC"
}

nh_assert_eq() {
  if [ "$2" = "$3" ]; then
    nh_pass "$1"
  else
    nh_fail "$1" "expected: $2 | actual: $3"
  fi
}

# Run a command, expect exit 0. errexit-safe.
nh_assert_true() {
  local label="$1"; shift
  local rc restore=0
  _nh_errexit_on && restore=1
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  [ "$restore" = "1" ] && set -e
  if [ "$rc" -eq 0 ]; then nh_pass "$label"; else nh_fail "$label" "command failed (rc $rc): $*"; fi
}

# Run a command, expect non-zero exit. errexit-safe.
nh_assert_false() {
  local label="$1"; shift
  local rc restore=0
  _nh_errexit_on && restore=1
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  [ "$restore" = "1" ] && set -e
  if [ "$rc" -ne 0 ]; then nh_pass "$label"; else nh_fail "$label" "command unexpectedly succeeded: $*"; fi
}

nh_assert_contains() {
  case "$2" in
    *"$3"*) nh_pass "$1" ;;
    *)      nh_fail "$1" "missing substring: $3" ;;
  esac
}

nh_assert_not_contains() {
  case "$2" in
    *"$3"*) nh_fail "$1" "unexpected substring: $3" ;;
    *)      nh_pass "$1" ;;
  esac
}

nh_assert_file_contains() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2" 2>/dev/null; then
    nh_pass "$1"
  else
    nh_fail "$1" "file does not contain: $3 ($2)"
  fi
}

nh_assert_file_not_contains() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2" 2>/dev/null; then
    nh_fail "$1" "file unexpectedly contains: $3 ($2)"
  else
    nh_pass "$1"
  fi
}

nh_assert_jq_file() {
  if jq -e "$3" "$2" >/dev/null 2>&1; then
    nh_pass "$1"
  else
    nh_fail "$1" "jq expr failed: $3 ($2)"
  fi
}

# Run a command, assert its exit code equals an expected value. errexit-safe.
nh_assert_exit() {
  local label="$1" expected="$2"; shift 2
  local rc restore=0
  _nh_errexit_on && restore=1
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  [ "$restore" = "1" ] && set -e
  if [ "$rc" = "$expected" ]; then
    nh_pass "$label (exit $rc)"
  else
    nh_fail "$label" "exit $rc, expected $expected: $*"
  fi
}

# Capture combined stdout+stderr and exit code of a command into two named
# variables without aborting under errexit. Uses printf -v so arbitrary
# (multi-line, special-char) output is assigned safely.
nh_capture() {
  local _ov="$1" _rv="$2"; shift 2
  local _out _rc restore=0
  _nh_errexit_on && restore=1
  set +e
  _out=$("$@" 2>&1)
  _rc=$?
  [ "$restore" = "1" ] && set -e
  printf -v "$_ov" '%s' "$_out"
  printf -v "$_rv" '%s' "$_rc"
  return 0
}

nh_should_run() {
  [ -z "$_NH_FILTER" ] && return 0
  case "$1" in
    *"$_NH_FILTER"*) return 0 ;;
    *)               return 1 ;;
  esac
}

# Run a cell (a function) unless a --filter pattern excludes its id.
# Skips are counted separately from pass/fail.
nh_cell() {
  local cell_id="$1" fn="$2"
  if ! nh_should_run "$cell_id"; then
    _NH_SKIP=$((_NH_SKIP + 1))
    return 0
  fi
  _NH_CELL="$cell_id"
  printf '%s[%s]%s\n' "$_NH_DIM" "$cell_id" "$_NH_NC"
  "$fn"
  _NH_CELL=""
}

nh_summary() {
  local total=$((_NH_PASS + _NH_FAIL))
  echo
  echo "====================="
  if [ "$_NH_FAIL" -eq 0 ]; then
    printf '%s%s: %d checks passed, 0 failed%s' "$_NH_GREEN" "$_NH_SUITE" "$_NH_PASS" "$_NH_NC"
    [ "$_NH_SKIP" -gt 0 ] && printf ' (%d skipped)' "$_NH_SKIP"
    printf '\n'
    return 0
  else
    printf '%s%s: %d failed of %d total%s' "$_NH_RED" "$_NH_SUITE" "$_NH_FAIL" "$total" "$_NH_NC"
    [ "$_NH_SKIP" -gt 0 ] && printf ' (%d skipped)' "$_NH_SKIP"
    printf '\n'
    return 1
  fi
}
