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
