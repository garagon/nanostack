#!/usr/bin/env bash
# e2e-adapter-freshness.sh — Adapter schema + freshness contract.
#
# PR 6 of the 2026-05-10 architecture audit. Locks bin/check-adapters.sh
# end-to-end against a tmp adapters/ directory so the live repo
# adapters never need to be mutated to exercise the failure paths.
#
# Spec acceptance, verbatim:
#   "A malformed adapter JSON fails lint."
#   "A README-listed adapter missing from adapters/ fails lint."
#   "A stale adapter beyond threshold fails scheduled/manual verification."
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d /tmp/nanostack-adapter-freshness.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

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

# Run check-adapters.sh against a fake repo root so the live adapters
# directory stays untouched.
run_check_in() {
  local root="$1"
  shift
  (cd "$root" && bash bin/check-adapters.sh "$@" 2>&1; echo "RC=$?")
}

# Build a tmp repo root that has bin/check-adapters.sh + adapters/
# pointing at our test fixtures. The README in the tmp root mentions
# the adapter set we want to lock against.
new_repo() {
  local name="$1"
  local root="$TMP_ROOT/$name"
  mkdir -p "$root/bin" "$root/adapters"
  cp "$REPO/bin/check-adapters.sh" "$root/bin/"
  chmod +x "$root/bin/check-adapters.sh"
  echo "$root"
}

write_adapter() {
  local root="$1" name="$2" last_verified="$3" extra_jq="${4:-.}"
  local body
  body=$(jq -n --arg host "$name" --arg lv "$last_verified" \
    '{host: $host, schema_version: "1", last_verified: $lv,
      verification: {method: "ci", evidence: "test"},
      skill_discovery: "native",
      bash_guard: "enforced",
      write_guard: "enforced",
      phase_gate: "enforced",
      install_target: ".claude/settings.json",
      doctor_checks: ["hooks"]
    }')
  echo "$body" | jq "$extra_jq" > "$root/adapters/${name}.json"
}

echo "Adapter Freshness E2E"
echo "====================="
echo "Tmp root: $TMP_ROOT"
echo

NOW_ISO=$(date -u +%Y-%m-%d)

# Cell 1: a fresh, complete adapter set passes.
echo "[1] fresh adapter set passes"
root=$(new_repo "cell1")
cat > "$root/README.md" <<'EOF'
README mentions `claude` and `codex` as verified adapters.
EOF
write_adapter "$root" claude "$NOW_ISO"
write_adapter "$root" codex  "$NOW_ISO"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "fresh set exits 0" "0" "$rc"

# Cell 2: a malformed adapter (missing required field) fails.
echo "[2] missing required field fails"
root=$(new_repo "cell2")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO" 'del(.bash_guard)'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "missing bash_guard exits 1" "1" "$rc"
echo "$out" | grep -q "missing bash_guard" && \
  assert_eq "missing field reported" "yes" "yes" || \
  assert_eq "missing field reported" "yes" "no"

# Cell 3: enum violation (skill_discovery value not in enum) fails.
echo "[3] enum violation fails"
root=$(new_repo "cell3")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO" '.skill_discovery = "bogus"'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "enum violation exits 1" "1" "$rc"

# Cell 4: README-listed adapter missing from adapters/ fails.
echo "[4] README-listed adapter missing from adapters/ fails"
root=$(new_repo "cell4")
cat > "$root/README.md" <<'EOF'
README mentions `claude` and `cursor` as verified adapters.
EOF
write_adapter "$root" claude "$NOW_ISO"
# cursor.json deliberately not written
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "missing README-listed adapter exits 1" "1" "$rc"
echo "$out" | grep -q "no adapters/cursor.json" && \
  assert_eq "missing adapter reported" "yes" "yes" || \
  assert_eq "missing adapter reported" "yes" "no"

# Cell 5: stale adapter beyond fail threshold (60 days) on a
# README-listed host fails.
echo "[5] stale README-listed adapter fails after 60 days"
root=$(new_repo "cell5")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
# 90 days ago
stale_date=$(date -u -v-90d +%Y-%m-%d 2>/dev/null || date -u --date='90 days ago' +%Y-%m-%d)
write_adapter "$root" claude "$stale_date"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "stale README-listed adapter exits 1" "1" "$rc"
echo "$out" | grep -q "days old" && \
  assert_eq "stale message reported" "yes" "yes" || \
  assert_eq "stale message reported" "yes" "no"

# Cell 6: a stale adapter that is NOT README-listed warns but does
# not fail.
echo "[6] stale non-README-listed adapter warns, does not fail"
root=$(new_repo "cell6")
cat > "$root/README.md" <<'EOF'
README mentions `claude` only.
EOF
write_adapter "$root" claude "$NOW_ISO"
write_adapter "$root" experimental "$stale_date"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
# experimental is not a known host; the host enum check fails first.
# That is expected: an unknown host should not silently pass either.
# Use cursor (a known host) that is not listed in the README instead.
root=$(new_repo "cell6b")
cat > "$root/README.md" <<'EOF'
README mentions `claude` only.
EOF
write_adapter "$root" claude "$NOW_ISO"
write_adapter "$root" cursor "$stale_date"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "stale non-listed adapter does NOT fail (rc 0)" "0" "$rc"
echo "$out" | grep -q "WARN" && \
  assert_eq "warn label present" "yes" "yes" || \
  assert_eq "warn label present" "yes" "no"

# Cell 7: NANOSTACK_ALLOW_STALE_ADAPTERS=1 downgrades the fail to a
# warning so a maintainer can re-run on an old branch.
echo "[7] NANOSTACK_ALLOW_STALE_ADAPTERS=1 downgrades fail to warn"
root=$(new_repo "cell7")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$stale_date"
out=$(cd "$root" && NANOSTACK_ALLOW_STALE_ADAPTERS=1 bash bin/check-adapters.sh 2>&1; echo "RC=$?")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "override exits 0" "0" "$rc"
echo "$out" | grep -q "override active" && \
  assert_eq "override message present" "yes" "yes" || \
  assert_eq "override message present" "yes" "no"

# Cell 7a: documented capability values from
# reference/host-adapter-schema.md (detectable, hooked, host_dependent)
# must be accepted, not rejected. Codex flagged the enum drift on
# the PR 6 first review pass.
echo "[7a] documented capability enum is honored"
root=$(new_repo "cell7a-enum")
cat > "$root/README.md" <<'EOF'
README mentions `claude` only.
EOF
# Use the full enum across three different capabilities.
write_adapter "$root" claude "$NOW_ISO" '
  .bash_guard = "detectable"
  | .write_guard = "hooked"
  | .phase_gate = "host_dependent"
'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "documented capability enum passes (rc 0)" "0" "$rc"

# Cell 7b: empty string for a required capability is treated as a
# failure even though the key exists. Codex flagged the empty-bypass
# on the PR 6 first review pass.
echo "[7b] empty capability value fails (does not silently pass)"
root=$(new_repo "cell7b-empty")
cat > "$root/README.md" <<'EOF'
README mentions `claude` only.
EOF
write_adapter "$root" claude "$NOW_ISO" '.bash_guard = ""'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "empty bash_guard fails (rc 1)" "1" "$rc"
echo "$out" | grep -q "bash_guard is empty" && \
  assert_eq "empty-field message present" "yes" "yes" || \
  assert_eq "empty-field message present" "yes" "no"

# Cell 7c: missing verification block fails the schema check.
# Codex caught the truncated required-field list on the PR 6 first
# review pass.
echo "[7c] missing verification block fails"
root=$(new_repo "cell7c-no-verification")
cat > "$root/README.md" <<'EOF'
README mentions `claude` only.
EOF
write_adapter "$root" claude "$NOW_ISO" 'del(.verification)'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "missing verification exits 1" "1" "$rc"
echo "$out" | grep -q "missing verification" && \
  assert_eq "missing-verification message present" "yes" "yes" || \
  assert_eq "missing-verification message present" "yes" "no"

# Cell 7d: unparseable last_verified surfaces a clear error and still
# completes the run (does not silent-exit under set -e). Codex P3
# from the PR 6 first review pass.
echo "[7d] unparseable last_verified is reported (no silent exit)"
root=$(new_repo "cell7d-bad-date")
cat > "$root/README.md" <<'EOF'
README mentions `claude` only.
EOF
write_adapter "$root" claude "not-a-date"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "unparseable date exits 1" "1" "$rc"
echo "$out" | grep -q "does not parse as a date" && \
  assert_eq "unparseable-date message present" "yes" "yes" || \
  assert_eq "unparseable-date message present" "yes" "no"

# Cell 7e: host field must match the filename basename. A
# mislabeled file (cursor.json with host=claude) used to pass and
# would also satisfy the README missing-file check. Codex flagged
# the duplicated-adapter hole on the PR 6 second review pass.
echo "[7e] host field must match filename"
root=$(new_repo "cell7e-mislabel")
cat > "$root/README.md" <<'EOF'
README mentions `cursor`.
EOF
# Filename is cursor.json but host is "claude" — a mislabel.
write_adapter "$root" cursor "$NOW_ISO" '.host = "claude"'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "mislabeled host exits 1" "1" "$rc"
echo "$out" | grep -q "does not match filename" && \
  assert_eq "mislabel message present" "yes" "yes" || \
  assert_eq "mislabel message present" "yes" "no"

# Cell 7f: README path anchors at the repo root, not the caller's
# cwd. A script invoked from outside the repo used to compute an
# empty README_LISTED, which silently downgraded the fail-after-60
# policy to a warn. Codex caught the cwd-dependent path on the PR 6
# third review pass.
echo "[7f] check-adapters.sh reads README from the repo root, not cwd"
root=$(new_repo "cell7f-cwd")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
stale=$(date -u -v-90d +%Y-%m-%d 2>/dev/null || date -u --date='90 days ago' +%Y-%m-%d)
write_adapter "$root" claude "$stale"
# Run from a totally unrelated cwd; the README at $root must still
# be the one consulted.
elsewhere=$(mktemp -d "$TMP_ROOT/elsewhere.XXXX")
out=$(cd "$elsewhere" && bash "$root/bin/check-adapters.sh" 2>&1; echo "RC=$?")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "stale README-listed adapter still fails from a foreign cwd" "1" "$rc"

# Cell 7g: doctor_checks must be string[]. Non-string entries
# (numbers, objects) would break downstream doctor/setup code that
# uses each entry as a check name. Codex caught the missing
# element check on the PR 6 third review pass.
echo "[7g] doctor_checks rejects non-string entries"
root=$(new_repo "cell7g-doctor-types")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO" '.doctor_checks = [123]'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "non-string doctor_checks fails (rc 1)" "1" "$rc"
echo "$out" | grep -q "must be a non-empty array of strings" && \
  assert_eq "doctor_checks message present" "yes" "yes" || \
  assert_eq "doctor_checks message present" "yes" "no"

# Cell 7h: a filter that matches no adapter file is a failure, not a
# silent empty pass. Codex flagged the typo-passes-silently hole on
# the PR 6 fourth review pass.
echo "[7h] filter with no match fails (does not silently pass)"
root=$(new_repo "cell7h-typo-filter")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO"
out=$(cd "$root" && bash bin/check-adapters.sh codxe 2>&1; echo "RC=$?")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "filter 'codxe' (typo) exits 1" "1" "$rc"
echo "$out" | grep -q "filter matched nothing" && \
  assert_eq "filter-typo message present" "yes" "yes" || \
  assert_eq "filter-typo message present" "yes" "no"

# Cell 7i: schema_version must be in the supported set. An adapter
# declaring schema_version=2 (forward-incompatible) used to pass.
# Codex caught the missing version check on the PR 6 fourth review
# pass.
echo "[7i] schema_version is validated against the supported set"
root=$(new_repo "cell7i-schema-version")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO" '.schema_version = "2"'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "schema_version=2 exits 1" "1" "$rc"
echo "$out" | grep -q "schema_version=2 not in supported set" && \
  assert_eq "schema-version message present" "yes" "yes" || \
  assert_eq "schema-version message present" "yes" "no"

# Cell 7j: future last_verified must fail, not silently suppress
# freshness warnings. A typo like 2099-01-01 used to make an
# adapter look perpetually fresh; Codex caught the negative-age
# bypass on the PR 6 fifth review pass.
echo "[7j] future last_verified fails (does not bypass freshness)"
root=$(new_repo "cell7j-future")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "2099-01-01"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "future last_verified exits 1" "1" "$rc"
echo "$out" | grep -q "is in the future" && \
  assert_eq "future-date message present" "yes" "yes" || \
  assert_eq "future-date message present" "yes" "no"

# Cell 7k: a malformed verification block (string instead of object)
# must be reported as a typed failure, not crash jq under set -e.
# Codex caught the unguarded read on the PR 6 fifth review pass.
echo "[7k] verification as a non-object reports a typed failure"
root=$(new_repo "cell7k-verification-shape")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO" '.verification = "should be an object"'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "non-object verification exits 1" "1" "$rc"
echo "$out" | grep -q "verification is not an object" && \
  assert_eq "verification-shape message present" "yes" "yes" || \
  assert_eq "verification-shape message present" "yes" "no"

# Cell 7l: a JSON file whose root is not an object (e.g. an array)
# is reported as a typed failure, not a crash. Codex caught the
# silent crash on the PR 6 sixth review pass: `[]` used to pass
# the `jq -e .` check and then break the next field read.
echo "[7l] non-object JSON root reports a typed failure"
root=$(new_repo "cell7l-array-root")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
echo "[]" > "$root/adapters/claude.json"
out=$(cd "$root" && bash bin/check-adapters.sh --json 2>&1; echo "RC=$?")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "array root exits 1" "1" "$rc"
echo "$out" | grep -q "root is not a JSON object" && \
  assert_eq "non-object-root message present" "yes" "yes" || \
  assert_eq "non-object-root message present" "yes" "no"
# --json should still produce a parseable summary even on this kind
# of failure.
json_only=$(echo "$out" | sed '/^RC=/d')
echo "$json_only" | jq -e '.summary.fail >= 1' >/dev/null 2>&1 && \
  assert_eq "--json still parseable on root-type failure" "yes" "yes" || \
  assert_eq "--json still parseable on root-type failure" "yes" "no"

# Cell 7m: wrong scalar type (install_target: 123) is reported.
# Codex caught the type hole on the PR 6 sixth review pass.
echo "[7m] wrong scalar type for required field is reported"
root=$(new_repo "cell7m-scalar-type")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO" '.install_target = 123'
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "install_target as int exits 1" "1" "$rc"
echo "$out" | grep -q "install_target is not a string" && \
  assert_eq "scalar-type message present" "yes" "yes" || \
  assert_eq "scalar-type message present" "yes" "no"

# Cell 7n: non-ISO last_verified values (e.g. "yesterday" or
# "04/25/2026") must be rejected. GNU `date -d` on Ubuntu accepts
# these forms, which would let a malformed value pass the freshness
# gate on CI. Codex caught the permissive parse on the PR 6 seventh
# review pass.
echo "[7n] non-ISO last_verified is rejected"
root=$(new_repo "cell7n-non-iso")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "yesterday"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "'yesterday' exits 1" "1" "$rc"
echo "$out" | grep -q "does not parse as a date" && \
  assert_eq "non-ISO message present" "yes" "yes" || \
  assert_eq "non-ISO message present" "yes" "no"
write_adapter "$root" claude "04/25/2026"
out=$(run_check_in "$root")
rc=$(echo "$out" | sed -n 's/^RC=\(.*\)/\1/p' | tail -1)
assert_eq "'04/25/2026' exits 1" "1" "$rc"

# Cell 8: --json output emits a parseable summary object.
echo "[8] --json output is parseable"
root=$(new_repo "cell8")
cat > "$root/README.md" <<'EOF'
README mentions `claude`.
EOF
write_adapter "$root" claude "$NOW_ISO"
out=$(cd "$root" && bash bin/check-adapters.sh --json)
if echo "$out" | jq -e '.summary.fail == 0' >/dev/null 2>&1; then
  parsed="yes"
else
  parsed="no"
fi
assert_eq "--json output parses with summary.fail = 0" "yes" "$parsed"

cd "$TMP_ROOT"

echo
echo "====================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Adapter Freshness E2E: %d checks passed, 0 failed${NC}\n" "$PASS"
  exit 0
else
  printf "${RED}Adapter Freshness E2E: %d failed of %d total${NC}\n" "$FAIL" "$TOTAL"
  exit 1
fi
