#!/usr/bin/env bash
# e2e-artifact-trust.sh — Artifact Trust v2 contract.
#
# Locks the shared trust model introduced in PR 2 of the 2026-05-10
# architecture audit. Covers the four canonical artifact states across
# three consumer surfaces:
#
#   - bin/lib/artifact-trust.sh  (the helper itself)
#   - bin/find-artifact.sh       (--verify and --require-integrity)
#   - bin/resolve.sh             (upstream_status field)
#
# The harness writes artifacts by hand so each trust state is exercised
# in isolation, then runs the public CLI surfaces and asserts the
# observable outputs. Save-artifact.sh always writes .integrity, so
# integrity_missing only happens for legacy artifacts or after an
# attacker strips the field; both paths are tested here.
set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d /tmp/nanostack-artifact-trust.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

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

# Write a json artifact under <store>/<phase>/<ts>.json in one of three
# trust states. The body is fixed so the canonical hash is reproducible.
mk_artifact() {
  local store="$1" phase="$2" mode="$3" ts="$4" project="$5"
  mkdir -p "$store/$phase"
  local body
  body=$(printf '{"phase":"%s","project":"%s","summary":"x"}' "$phase" "$project")
  case "$mode" in
    verified)
      local h
      h=$(printf '%s' "$body" | jq -Sc 'del(.integrity)' | shasum -a 256 | cut -d' ' -f1)
      printf '%s' "$body" | jq --arg h "$h" '. + {integrity:$h}' > "$store/$phase/$ts.json"
      ;;
    missing)
      printf '%s' "$body" > "$store/$phase/$ts.json"
      ;;
    mismatch)
      printf '%s' "$body" | jq '. + {integrity:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}' > "$store/$phase/$ts.json"
      ;;
  esac
}

echo "Artifact Trust v2 E2E"
echo "====================="
echo "Tmp root: $TMP_ROOT"
echo

PROJ="$TMP_ROOT/project"
STORE="$PROJ/.nanostack"
mkdir -p "$PROJ" "$STORE"
cd "$PROJ"
git init -q

# Cell 1: nano_artifact_trust returns each of the four statuses.
echo "[1] nano_artifact_trust returns the four canonical statuses"
mk_artifact "$STORE" trust verified  2026-05-10T01-00-00 "$PROJ"
mk_artifact "$STORE" trust missing   2026-05-10T01-01-00 "$PROJ"
mk_artifact "$STORE" trust mismatch  2026-05-10T01-02-00 "$PROJ"
ok_status=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$STORE/trust/2026-05-10T01-00-00.json'")
miss_status=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$STORE/trust/2026-05-10T01-01-00.json'")
bad_status=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$STORE/trust/2026-05-10T01-02-00.json'")
none_status=$(bash -c "source '$REPO/bin/lib/artifact-trust.sh'; nano_artifact_trust '$STORE/trust/does-not-exist.json' || true")
assert_eq "verified artifact"           "verified"           "$ok_status"
assert_eq "integrity_missing artifact"  "integrity_missing"  "$miss_status"
assert_eq "integrity_mismatch artifact" "integrity_mismatch" "$bad_status"
assert_eq "not_found artifact"          "not_found"          "$none_status"

# Cell 2: find-artifact.sh without --verify returns the newest artifact
# regardless of trust state. This preserves the historical default.
echo "[2] find-artifact.sh default returns newest regardless of trust"
NANOSTACK_STORE="$STORE" out=$( NANOSTACK_STORE="$STORE" "$REPO/bin/find-artifact.sh" trust 30 2>/dev/null || true )
assert_eq "default returns the newest (mismatch) artifact" "2026-05-10T01-02-00.json" "$(basename "${out:-}")"

# Cell 3: find-artifact.sh --verify keeps the legacy lenient contract:
# integrity_missing passes, integrity_mismatch fails.
echo "[3] find-artifact.sh --verify is lenient on missing integrity"
PROJ2="$TMP_ROOT/project2"
STORE2="$PROJ2/.nanostack"
mkdir -p "$PROJ2" "$STORE2"
cd "$PROJ2"
git init -q
mk_artifact "$STORE2" review verified 2026-05-10T02-00-00 "$PROJ2"
set +e
out=$( NANOSTACK_STORE="$STORE2" "$REPO/bin/find-artifact.sh" review 30 --verify 2>&1 )
rc=$?
set -e
assert_eq "verified passes --verify (rc 0)" "0" "$rc"
assert_eq "verified path returned"          "2026-05-10T02-00-00.json" "$(basename "${out:-}")"
mk_artifact "$STORE2" review missing 2026-05-10T02-01-00 "$PROJ2"
set +e
out=$( NANOSTACK_STORE="$STORE2" "$REPO/bin/find-artifact.sh" review 30 --verify 2>&1 )
rc=$?
set -e
assert_eq "integrity_missing passes --verify (rc 0)" "0" "$rc"
assert_eq "newest missing-integrity path returned"   "2026-05-10T02-01-00.json" "$(basename "${out:-}")"
mk_artifact "$STORE2" review mismatch 2026-05-10T02-02-00 "$PROJ2"
set +e
out=$( NANOSTACK_STORE="$STORE2" "$REPO/bin/find-artifact.sh" review 30 --verify 2>&1 )
rc=$?
set -e
assert_eq "integrity_mismatch fails --verify (rc 1)" "1" "$rc"
echo "$out" | grep -qE '^INTEGRITY FAILED:' && \
  assert_eq "stderr labelled INTEGRITY FAILED" "yes" "yes" || \
  assert_eq "stderr labelled INTEGRITY FAILED" "yes" "no"

# Cell 4: find-artifact.sh --require-integrity is strict: integrity_missing
# also fails, with a distinct stderr category.
echo "[4] find-artifact.sh --require-integrity is strict on missing + mismatch"
PROJ3="$TMP_ROOT/project3"
STORE3="$PROJ3/.nanostack"
mkdir -p "$PROJ3" "$STORE3"
cd "$PROJ3"
git init -q
mk_artifact "$STORE3" qa verified 2026-05-10T03-00-00 "$PROJ3"
set +e
out=$( NANOSTACK_STORE="$STORE3" "$REPO/bin/find-artifact.sh" qa 30 --require-integrity 2>&1 )
rc=$?
set -e
assert_eq "verified passes --require-integrity (rc 0)" "0" "$rc"
mk_artifact "$STORE3" qa missing 2026-05-10T03-01-00 "$PROJ3"
set +e
out=$( NANOSTACK_STORE="$STORE3" "$REPO/bin/find-artifact.sh" qa 30 --require-integrity 2>&1 )
rc=$?
set -e
assert_eq "integrity_missing fails --require-integrity (rc 1)" "1" "$rc"
echo "$out" | grep -qE '^INTEGRITY MISSING:' && \
  assert_eq "stderr labelled INTEGRITY MISSING" "yes" "yes" || \
  assert_eq "stderr labelled INTEGRITY MISSING" "yes" "no"
mk_artifact "$STORE3" qa mismatch 2026-05-10T03-02-00 "$PROJ3"
set +e
out=$( NANOSTACK_STORE="$STORE3" "$REPO/bin/find-artifact.sh" qa 30 --require-integrity 2>&1 )
rc=$?
set -e
assert_eq "integrity_mismatch fails --require-integrity (rc 1)" "1" "$rc"

# Cell 5: resolve.sh exposes upstream_status for every declared upstream.
# /ship pulls review, security, qa — one of each trust state.
echo "[5] resolve.sh upstream_status reports every declared upstream"
PROJ4="$TMP_ROOT/project4"
STORE4="$PROJ4/.nanostack"
mkdir -p "$PROJ4" "$STORE4"
cd "$PROJ4"
git init -q
mk_artifact "$STORE4" review   verified 2026-05-10T04-00-00 "$PROJ4"
mk_artifact "$STORE4" security missing  2026-05-10T04-00-00 "$PROJ4"
mk_artifact "$STORE4" qa       mismatch 2026-05-10T04-00-00 "$PROJ4"
resolved=$( NANOSTACK_STORE="$STORE4" "$REPO/bin/resolve.sh" ship 2>/dev/null )
status_review=$( echo "$resolved"   | jq -r '.upstream_status.review // ""' )
status_security=$( echo "$resolved" | jq -r '.upstream_status.security // ""' )
status_qa=$( echo "$resolved"       | jq -r '.upstream_status.qa // ""' )
assert_eq "upstream_status.review == verified"            "verified"           "$status_review"
assert_eq "upstream_status.security == integrity_missing" "integrity_missing"  "$status_security"
assert_eq "upstream_status.qa == integrity_mismatch"      "integrity_mismatch" "$status_qa"

# Cell 6: upstream_artifacts shape stays backward compatible. Verified
# and integrity_missing artifacts include their path so legacy stores
# load; mismatched artifacts are omitted (current --verify behavior).
echo "[6] upstream_artifacts shape: verified + missing-integrity load, mismatch omitted"
has_review=$( echo "$resolved"   | jq -e '.upstream_artifacts.review != null' >/dev/null 2>&1 && echo yes || echo no )
has_security=$( echo "$resolved" | jq -e '.upstream_artifacts.security != null' >/dev/null 2>&1 && echo yes || echo no )
has_qa=$( echo "$resolved"       | jq -e '.upstream_artifacts.qa != null' >/dev/null 2>&1 && echo yes || echo no )
assert_eq "verified artifact loads"          "yes" "$has_review"
assert_eq "integrity_missing artifact loads" "yes" "$has_security"
assert_eq "integrity_mismatch artifact omitted from upstream_artifacts" "no" "$has_qa"

# Cell 7: missing upstream (never saved) is reported as "missing".
echo "[7] never-saved upstream reports status=missing"
PROJ5="$TMP_ROOT/project5"
STORE5="$PROJ5/.nanostack"
mkdir -p "$PROJ5" "$STORE5"
cd "$PROJ5"
git init -q
mk_artifact "$STORE5" review verified 2026-05-10T05-00-00 "$PROJ5"
# security and qa are deliberately not created
resolved=$( NANOSTACK_STORE="$STORE5" "$REPO/bin/resolve.sh" ship 2>/dev/null )
status_security=$( echo "$resolved" | jq -r '.upstream_status.security // ""' )
status_qa=$( echo "$resolved"       | jq -r '.upstream_status.qa // ""' )
assert_eq "missing security reports status=missing" "missing" "$status_security"
assert_eq "missing qa reports status=missing"       "missing" "$status_qa"

# Cell 8a: find-artifact.sh parses flags even when max-age is omitted.
# Codex caught this on the PR 2 first pass: `find-artifact.sh plan
# --require-integrity` (the documented optional-age form) used to
# assign the flag string to MAX_AGE and the strict gate silently
# no-oped. Locked here so the regression cannot return.
echo "[8a] find-artifact.sh detects flags in the max-age slot"
PROJ_FLAG="$TMP_ROOT/project-flag"
STORE_FLAG="$PROJ_FLAG/.nanostack"
mkdir -p "$PROJ_FLAG" "$STORE_FLAG"
cd "$PROJ_FLAG"
git init -q
mk_artifact "$STORE_FLAG" plan missing 2026-05-10T08-00-00 "$PROJ_FLAG"
set +e
out=$( NANOSTACK_STORE="$STORE_FLAG" "$REPO/bin/find-artifact.sh" plan --require-integrity 2>&1 )
rc=$?
set -e
assert_eq "no max-age + --require-integrity fails on missing (rc 1)" "1" "$rc"
echo "$out" | grep -qE '^INTEGRITY MISSING:' && \
  assert_eq "no max-age + --require-integrity emits INTEGRITY MISSING" "yes" "yes" || \
  assert_eq "no max-age + --require-integrity emits INTEGRITY MISSING" "yes" "no"
set +e
out=$( NANOSTACK_STORE="$STORE_FLAG" "$REPO/bin/find-artifact.sh" plan --verify 2>&1 )
rc=$?
set -e
assert_eq "no max-age + --verify is lenient (rc 0)" "0" "$rc"

# Cell 8: custom phases also get upstream_status. The custom dep graph
# resolves through phase_graph or SKILL.md frontmatter, same as before.
echo "[8] custom phase upstream_status follows the dep graph"
PROJ6="$TMP_ROOT/project6"
STORE6="$PROJ6/.nanostack"
mkdir -p "$PROJ6" "$STORE6/skills/license-audit"
cd "$PROJ6"
git init -q
cat > "$STORE6/config.json" <<'EOF'
{
  "custom_phases": ["license-audit"],
  "phase_graph": [
    {"name":"think","depends_on":[]},
    {"name":"plan","depends_on":["think"]},
    {"name":"build","depends_on":["plan"]},
    {"name":"license-audit","depends_on":["build","review"]},
    {"name":"review","depends_on":["build"]},
    {"name":"ship","depends_on":["license-audit"]}
  ]
}
EOF
cat > "$STORE6/skills/license-audit/SKILL.md" <<'EOF'
---
name: license-audit
description: license check
concurrency: read
---
body
EOF
mk_artifact "$STORE6" review verified 2026-05-10T06-00-00 "$PROJ6"
# build has no artifact directory; it should resolve to not_applicable
resolved=$( NANOSTACK_STORE="$STORE6" "$REPO/bin/resolve.sh" license-audit 2>/dev/null )
status_review=$(  echo "$resolved" | jq -r '.upstream_status.review // ""' )
status_build=$(   echo "$resolved" | jq -r '.upstream_status.build // ""' )
phase_kind=$(     echo "$resolved" | jq -r '.phase_kind // ""' )
assert_eq "custom phase_kind = custom"                 "custom"          "$phase_kind"
assert_eq "custom upstream_status.review = verified"   "verified"        "$status_review"
assert_eq "custom upstream_status.build = not_applicable" "not_applicable" "$status_build"

cd "$TMP_ROOT"

echo
echo "====================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Artifact Trust v2 E2E: %d checks passed, 0 failed${NC}\n" "$PASS"
  exit 0
else
  printf "${RED}Artifact Trust v2 E2E: %d failed of %d total${NC}\n" "$FAIL" "$TOTAL"
  exit 1
fi
