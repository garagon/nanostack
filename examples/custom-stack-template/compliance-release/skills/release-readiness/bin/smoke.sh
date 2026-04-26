#!/usr/bin/env bash
# smoke.sh — release-readiness runtime sanity check.
#
# Sets up tmp projects with various upstream artifact configurations
# and asserts the composer's rollup logic:
#   1. all five upstreams OK -> rollup OK
#   2. one upstream WARN, rest OK -> rollup WARN
#   3. one upstream BLOCKED -> rollup BLOCKED
#   4. one upstream MISSING -> rollup BLOCKED (required upstream)
#   5. mixed (one WARN + one MISSING) -> rollup BLOCKED
#
# Each case writes raw artifacts under .nanostack/<phase>/ and runs
# summarize.sh against that store via NANOSTACK_STORE override.
set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUMMARIZE="$SKILL_DIR/bin/summarize.sh"

# Find the nanostack repo root by walking up from this skill's location.
# When the skill ships inside the repo (PR 2 dev), bin/find-artifact.sh
# lives a few directories up. When the skill is copied into
# ~/.claude/skills/license-audit, the user-set NANOSTACK_ROOT points
# at the nanostack install. The smoke test runs inside the repo so
# we can locate the repo root deterministically.
REPO_ROOT="$(cd "$SKILL_DIR" && cd ../../../../.. && pwd)"
if [ ! -x "$REPO_ROOT/bin/find-artifact.sh" ]; then
  # Fallback: caller may have set NANOSTACK_ROOT explicitly.
  REPO_ROOT="${NANOSTACK_ROOT:-$REPO_ROOT}"
fi
if [ ! -x "$REPO_ROOT/bin/find-artifact.sh" ]; then
  echo "FAIL: cannot locate bin/find-artifact.sh from $SKILL_DIR" >&2
  exit 1
fi

if [ ! -x "$SUMMARIZE" ]; then
  echo "FAIL: $SUMMARIZE is not executable" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for the smoke check" >&2
  exit 1
fi

tmp=$(mktemp -d /tmp/release-readiness-smoke.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fail=0

# Helper: write a phase artifact directly to disk so the smoke test
# does not depend on save-artifact.sh's project-scoping rules.
write_artifact() {
  local store="$1" phase="$2" status="$3"
  local dir="$store/$phase"
  mkdir -p "$dir"
  local ts
  ts=$(date -u +"%Y%m%d-%H%M%S")
  jq -n \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg ts "$ts" \
    --arg project "$(pwd)" \
    '{
      phase: $phase,
      status: "completed",
      project: $project,
      timestamp: ($ts | gsub("(?<a>[0-9]{4})(?<b>[0-9]{2})(?<c>[0-9]{2})-(?<d>[0-9]{2})(?<e>[0-9]{2})(?<f>[0-9]{2})"; "\(.a)-\(.b)-\(.c)T\(.d):\(.e):\(.f)Z")),
      summary: { status: $status, headline: "smoke artifact" },
      context_checkpoint: { summary: "smoke" }
    }' > "$dir/$ts.json"
}

run_case() {
  local label="$1" expected_rollup="$2"; shift 2
  # Remaining args: phase=status pairs.
  local proj="$tmp/$label"
  mkdir -p "$proj"
  cd "$proj"
  git init -q 2>/dev/null || true
  local store="$proj/.nanostack"
  mkdir -p "$store"
  for pair in "$@"; do
    local phase="${pair%%=*}"
    local status="${pair#*=}"
    write_artifact "$store" "$phase" "$status"
  done
  local out
  out=$(
    NANOSTACK_ROOT="$REPO_ROOT" \
    NANOSTACK_STORE="$store" \
    "$SUMMARIZE" 2>&1
  )
  cd "$tmp"
  local got
  got=$( echo "$out" | jq -r '.rollup_status' 2>/dev/null )
  if [ "$got" = "$expected_rollup" ]; then
    echo "  ok    $label: rollup is $expected_rollup"
  else
    echo "FAIL: $label expected rollup $expected_rollup, got '$got'"
    echo "$out"
    fail=1
  fi
}

# Case 1: all OK
run_case "all-ok" "OK" \
  review=OK qa=OK security=OK license-audit=OK privacy-check=OK

# Case 2: one WARN
run_case "one-warn" "WARN" \
  review=OK qa=OK security=OK license-audit=OK privacy-check=WARN

# Case 3: one BLOCKED
run_case "one-blocked" "BLOCKED" \
  review=OK qa=OK security=BLOCKED license-audit=OK privacy-check=OK

# Case 4: one MISSING (qa absent)
run_case "qa-missing" "BLOCKED" \
  review=OK security=OK license-audit=OK privacy-check=OK

# Case 5: WARN + MISSING -> still BLOCKED
run_case "mixed-warn-missing" "BLOCKED" \
  review=OK qa=WARN security=OK privacy-check=OK
# (license-audit deliberately omitted to simulate MISSING)

# Case 6: tampered artifact -> rollup BLOCKED, per-check TAMPERED.
# A release gate must not treat a modified-after-save artifact as
# clean evidence. The smoke writes a security artifact with an
# explicit (wrong) integrity hash so find-artifact.sh --verify fails.
proj="$tmp/tampered"
mkdir -p "$proj"
cd "$proj"
git init -q 2>/dev/null || true
store="$proj/.nanostack"
mkdir -p "$store"
write_artifact "$store" review OK
write_artifact "$store" qa OK
write_artifact "$store" license-audit OK
write_artifact "$store" "privacy-check" OK
sec_dir="$store/security"
mkdir -p "$sec_dir"
ts=$(date -u +"%Y%m%d-%H%M%S")
jq -n --arg phase "security" --arg ts "$ts" --arg project "$proj" '
  {
    phase: $phase,
    status: "completed",
    project: $project,
    timestamp: ($ts | gsub("(?<a>[0-9]{4})(?<b>[0-9]{2})(?<c>[0-9]{2})-(?<d>[0-9]{2})(?<e>[0-9]{2})(?<f>[0-9]{2})"; "\(.a)-\(.b)-\(.c)T\(.d):\(.e):\(.f)Z")),
    summary: { status: "OK", headline: "tampered case" },
    context_checkpoint: { summary: "smoke" },
    integrity: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  }' > "$sec_dir/$ts.json"
out=$(
  NANOSTACK_ROOT="$REPO_ROOT" \
  NANOSTACK_STORE="$store" \
  "$SUMMARIZE" 2>&1
)
cd "$tmp"
got=$( echo "$out" | jq -r '.rollup_status' 2>/dev/null )
sec_status=$( echo "$out" | jq -r '.checks[] | select(.phase == "security") | .status' 2>/dev/null )
if [ "$got" = "BLOCKED" ] && [ "$sec_status" = "TAMPERED" ]; then
  echo "  ok    tampered: per-check is TAMPERED, rollup is BLOCKED"
else
  echo "FAIL: tampered case wrong (rollup=$got, security=$sec_status)"
  echo "$out"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: release-readiness smoke passed (6 cases)"
fi
exit $fail
