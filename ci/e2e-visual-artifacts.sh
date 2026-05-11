#!/usr/bin/env bash
# e2e-visual-artifacts.sh — Visual Artifacts v1 PR 1 contract.
#
# Locks bin/render-artifact.sh + bin/lib/html-escape.sh +
# bin/lib/visual-render.sh end-to-end against the contract in
# reference/visual-artifact-contract.md.
#
# Scope (PR 1):
#   - /plan render succeeds on a valid artifact
#   - manifest schema (schema_version, kind, format, source_artifacts,
#     output_path, renderer)
#   - malicious artifact text is escaped, no raw <script>/<img>
#   - CSP and required data-* attributes present in HTML
#   - --strict rejects integrity_missing (exit 3)
#   - --strict rejects integrity_mismatch (exit 3)
#   - integrity_mismatch fails even without --strict (exit 3)
#   - --out outside the visual root fails (exit 4)
#   - --interactive is reserved (exit 2)
#   - journal/stack are reserved (exit 2)
#   - --manifest-only writes only the manifest
#   - --latest resolution via find-artifact.sh
#   - phase mismatch on explicit path fails (exit 1)

set -e
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d /tmp/nanostack-visual-artifacts.XXXXXX)
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
  if "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s (expected failure)\n" "$name"
  else
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  fi
}

assert_exit() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s (exit %s)\n" "$name" "$actual"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s (expected exit %s, got %s)\n" "$name" "$expected" "$actual"
  fi
}

assert_contains() {
  local name="$1"; local file="$2"; local needle="$3"
  if grep -qF "$needle" "$file"; then
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  else
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s (needle not in %s)\n" "$name" "$file"
    printf "          ${DIM}needle: %s${NC}\n" "$needle"
  fi
}

assert_not_contains() {
  local name="$1"; local file="$2"; local needle="$3"
  if grep -qF "$needle" "$file"; then
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  %s (forbidden needle present in %s)\n" "$name" "$file"
    printf "          ${DIM}needle: %s${NC}\n" "$needle"
  else
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    %s\n" "$name"
  fi
}

setup_project() {
  local dir="$1"
  mkdir -p "$dir"
  (cd "$dir" && git init -q && git config user.email t@t && git config user.name t && \
   echo init > a.txt && git add a.txt && git commit -qm init)
}

save_valid_plan() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" plan '{
    "phase": "plan",
    "summary": {
      "goal": "Visual artifacts v1",
      "scope": "small",
      "planned_files": ["bin/render-artifact.sh", "bin/lib/html-escape.sh"],
      "plan_approval": "manual",
      "risks": ["Renderer escapes incomplete"],
      "out_of_scope": ["Interactive mode"]
    },
    "context_checkpoint": {
      "summary": "Local HTML view",
      "key_files": ["bin/render-artifact.sh"],
      "decisions_made": ["JSON canonical"],
      "open_questions": []
    }
  }' >/dev/null
}

save_malicious_plan() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" plan '{
    "phase": "plan",
    "summary": {
      "goal": "<script>alert(1)</script>",
      "scope": "small",
      "planned_files": ["src/<img src=x onerror=alert(1)>.ts"],
      "plan_approval": "manual",
      "risks": ["\" onclick=\"alert(1)"]
    },
    "context_checkpoint": {
      "summary": "<b>bold?</b>",
      "key_files": [],
      "decisions_made": [],
      "open_questions": []
    }
  }' >/dev/null
}

printf "\n${GREEN}=== Visual Artifacts v1 PR 1 contract ===${NC}\n\n"

# ─── Cell 1: happy path /plan render ────────────────────────
printf "  ${DIM}Cell 1: happy path /plan render${NC}\n"
PROJ="$TMP_ROOT/cell1"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
set +e
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest 2>/dev/null)
RC=$?
set -e
assert_exit "render plan --latest succeeds" 0 test "$RC" = 0
assert_true "html file exists" test -f "$HTML"
assert_contains "doctype" "$HTML" "<!doctype html>"
assert_contains "viewport meta" "$HTML" "viewport"
assert_contains "CSP header" "$HTML" "default-src 'none'"
assert_contains "data-nanostack-visual attr" "$HTML" 'data-nanostack-visual="1"'
assert_contains "data-phase attr" "$HTML" 'data-phase="plan"'
assert_contains "trust badge data-trust=verified" "$HTML" 'data-trust="verified"'
assert_contains "trust badge text 'verified'" "$HTML" '>verified<'
assert_contains "goal rendered" "$HTML" "Visual artifacts v1"
assert_contains "planned file rendered" "$HTML" "bin/render-artifact.sh"
assert_contains "risk rendered" "$HTML" "Renderer escapes incomplete"
assert_contains "context summary rendered" "$HTML" "Local HTML view"
assert_contains "provenance footer" "$HTML" 'data-testid="visual-provenance"'
assert_contains "source artifact path attr" "$HTML" 'data-testid="source-artifact-path"'
assert_contains "manifest path attr" "$HTML" 'data-testid="visual-manifest-path"'

# Manifest schema checks.
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*.manifest.json 2>/dev/null | head -1)
assert_true "manifest file exists" test -f "$MFST"
assert_true "manifest schema_version == 1" sh -c "[ \"\$(jq -r .schema_version '$MFST')\" = '1' ]"
assert_true "manifest kind == phase" sh -c "[ \"\$(jq -r .kind '$MFST')\" = 'phase' ]"
assert_true "manifest format == html" sh -c "[ \"\$(jq -r .format '$MFST')\" = 'html' ]"
assert_true "manifest phase == plan" sh -c "[ \"\$(jq -r .phase '$MFST')\" = 'plan' ]"
assert_true "manifest custom_phase == false" sh -c "[ \"\$(jq -r .custom_phase '$MFST')\" = 'false' ]"
assert_true "manifest source_artifacts length >= 1" sh -c "[ \"\$(jq -r '.source_artifacts | length' '$MFST')\" -ge 1 ]"
assert_true "manifest source trust == verified" sh -c "[ \"\$(jq -r '.source_artifacts[0].trust' '$MFST')\" = 'verified' ]"
assert_true "manifest renderer.version present" sh -c "[ -n \"\$(jq -r '.renderer.version' '$MFST')\" ]"
assert_true "manifest output_path absolute" sh -c "[ \"\$(jq -r .output_path '$MFST')\" = '$HTML' ]"

# ─── Cell 2: XSS / escape contract ──────────────────────────
printf "\n  ${DIM}Cell 2: XSS / escape contract${NC}\n"
PROJ="$TMP_ROOT/cell2"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_malicious_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest)
assert_not_contains "no raw <script>alert(" "$HTML" "<script>alert("
assert_not_contains "no raw <img src=x onerror" "$HTML" "<img src=x onerror"
assert_contains "escaped &lt;script&gt;" "$HTML" "&lt;script&gt;"
assert_contains "escaped &lt;img" "$HTML" "&lt;img"
assert_contains "escaped &quot;" "$HTML" "&quot;"

# ─── Cell 3: --strict integrity_missing rejection ───────────
printf "\n  ${DIM}Cell 3: --strict integrity_missing rejection${NC}\n"
PROJ="$TMP_ROOT/cell3"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
# Strip .integrity
jq 'del(.integrity)' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "render --strict on integrity_missing exits 3" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --strict"
# Without --strict it should render with the unverified badge
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest 2>/dev/null)
assert_contains "integrity_missing badge unverified" "$HTML" 'data-trust="integrity_missing"'
assert_contains "badge text unverified" "$HTML" '>unverified<'

# ─── Cell 4: integrity_mismatch always fails ────────────────
printf "\n  ${DIM}Cell 4: integrity_mismatch always fails (exit 3)${NC}\n"
PROJ="$TMP_ROOT/cell4"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
# Mutate .summary.goal after save (keeps .integrity but breaks hash)
jq '.summary.goal = "Tampered!"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "render plain on integrity_mismatch exits 3" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"
assert_exit "render --strict on integrity_mismatch exits 3" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --strict"

# ─── Cell 5: --out path safety ──────────────────────────────
printf "\n  ${DIM}Cell 5: --out path safety${NC}\n"
PROJ="$TMP_ROOT/cell5"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "--out outside visual root exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out /tmp/outside.html"
assert_exit "--out relative path exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out foo.html"
# PR 1 pass 2 regression: --out with .. that escapes visual/ through a
# missing segment must be rejected even though every "existing
# ancestor" lies inside the visual root.
assert_exit "--out with .. escape exits 4 (PR 1 pass 2 regression)" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$NANOSTACK_STORE/visual/new/../../outside.html'"
# Confirm the escape did NOT leave a file behind outside visual/.
assert_true "no escaped file at .nanostack/outside.html" sh -c "[ ! -f '$NANOSTACK_STORE/outside.html' ]"
# Inside the visual root should work.
INSIDE="$NANOSTACK_STORE/visual/plan/explicit.html"
mkdir -p "$(dirname "$INSIDE")"
assert_exit "--out inside visual root succeeds" 0 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$INSIDE'"
assert_true "explicit out file exists" test -f "$INSIDE"

# ─── Cell 6: reserved features exit 2 ───────────────────────
printf "\n  ${DIM}Cell 6: reserved features exit 2${NC}\n"
PROJ="$TMP_ROOT/cell6"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "--interactive reserved (exit 2)" 2 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --interactive"
assert_exit "journal reserved (exit 2)" 2 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today"
assert_exit "stack reserved (exit 2)" 2 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack mystack"

# ─── Cell 7: --manifest-only ────────────────────────────────
printf "\n  ${DIM}Cell 7: --manifest-only${NC}\n"
PROJ="$TMP_ROOT/cell7"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
MFST_OUT=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --manifest-only)
assert_true "manifest path printed" sh -c "[ -n '$MFST_OUT' ]"
assert_true "manifest file exists" test -f "$MFST_OUT"
# No HTML should be written in --manifest-only mode.
HTML_COUNT=$(find "$NANOSTACK_STORE/visual/plan" -maxdepth 1 -name "*.html" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no html written under manifest-only" sh -c "[ '$HTML_COUNT' = '0' ]"

# ─── Cell 8: phase mismatch / reserved-PR-2 phases ──────────
printf "\n  ${DIM}Cell 8: phase mismatch and reserved-PR-2 phases${NC}\n"
PROJ="$TMP_ROOT/cell8"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
# Passing an explicit /plan artifact as if it were /review must fail
# because the requested phase is reserved for PR 2.
assert_exit "render review (PR 2) exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' review --latest"
# Edit the .phase field to 'review' and request as 'plan' -> mismatch.
TMPPLAN="$TMP_ROOT/mixed.json"
jq '.phase = "review"' "$PLAN_PATH" > "$TMPPLAN"
assert_exit "explicit path with mismatched .phase exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan '$TMPPLAN'"

# ─── Cell 9a: --out works on fresh store (PR 1 pass 1 regression) ─
printf "\n  ${DIM}Cell 9a: --out on fresh store (PR 1 pass 1 regression)${NC}\n"
PROJ="$TMP_ROOT/cell9a"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Visual root does not yet exist; --out under it must still succeed.
[ ! -d "$NANOSTACK_STORE/visual" ] && PASS=$((PASS+1)) || PASS=$PASS
TARGET="$NANOSTACK_STORE/visual/plan/custom.html"
set +e
(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out "$TARGET" >/dev/null 2>&1)
RC=$?
set -e
assert_exit "--out on fresh store succeeds" 0 test "$RC" = 0
assert_true "custom output file exists" test -f "$TARGET"

# ─── Cell 9b: legacy --from-session plan still renders ──────
# (PR 1 pass 1 regression)
printf "\n  ${DIM}Cell 9b: legacy plan renders without crashing${NC}\n"
PROJ="$TMP_ROOT/cell9b"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" --from-session plan "legacy summary" >/dev/null 2>&1)
set +e
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest 2>/dev/null)
RC=$?
set -e
assert_exit "legacy plan renders (exit 0)" 0 test "$RC" = 0
assert_true "legacy plan html exists" test -f "$HTML"
assert_contains "legacy plan shows schema warning" "$HTML" 'data-testid="schema-warning"'
assert_contains "legacy plan still renders trust badge" "$HTML" 'data-trust="integrity_missing"'
assert_contains "legacy plan still emits summary card" "$HTML" "Goal"

# Same path, but the renderer must coerce a string .summary safely.
PROJ2="$TMP_ROOT/cell9c"
setup_project "$PROJ2"
export NANOSTACK_STORE="$PROJ2/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Write an artifact with .summary = "string" via save-artifact's
# structured form but with shape that the validator will reject. The
# renderer must still produce HTML.
BAD="$NANOSTACK_STORE/plan/bad.json"
mkdir -p "$(dirname "$BAD")"
cat > "$BAD" <<'JSON'
{"phase":"plan","summary":"all-as-string-summary","context_checkpoint":"also-a-string","timestamp":"2026-05-11T00:00:00Z","project":"x","branch":"y"}
JSON
set +e
HTML=$(cd "$PROJ2" && "$REPO/bin/render-artifact.sh" plan "$BAD" 2>/dev/null)
RC=$?
set -e
assert_exit "string-summary artifact still renders" 0 test "$RC" = 0
assert_contains "string-summary html has schema warning" "$HTML" 'data-testid="schema-warning"'

# ─── Cell 9d: relative NANOSTACK_STORE -> absolute manifest paths ─
# PR 1 pass 3 regression: a relative store override must still
# produce an absolute output_path in the manifest.
printf "\n  ${DIM}Cell 9d: relative store -> absolute manifest (PR 1 pass 3 regression)${NC}\n"
PROJ="$TMP_ROOT/cell9d"
setup_project "$PROJ"
cd "$PROJ"
export NANOSTACK_STORE=".nano-rel"
mkdir -p "$NANOSTACK_STORE"
save_valid_plan "$NANOSTACK_STORE"
HTML=$("$REPO/bin/render-artifact.sh" plan --latest)
cd "$REPO"
# Stdout path must be absolute.
case "$HTML" in
  /*)
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    stdout path is absolute\n"
    ;;
  *)
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  stdout path is relative: %s\n" "$HTML"
    ;;
esac
# Manifest output_path must be absolute and equal the stdout path.
MFST_REL=$(ls "$PROJ/$NANOSTACK_STORE/visual/manifests/"*.manifest.json | head -1)
MFST_OUT=$(jq -r .output_path "$MFST_REL")
case "$MFST_OUT" in
  /*)
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    manifest output_path is absolute\n"
    ;;
  *)
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  manifest output_path is relative: %s\n" "$MFST_OUT"
    ;;
esac
# Source path must be absolute too.
SRC_OUT=$(jq -r '.source_artifacts[0].path' "$MFST_REL")
case "$SRC_OUT" in
  /*)
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    manifest source path is absolute\n"
    ;;
  *)
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  manifest source path is relative: %s\n" "$SRC_OUT"
    ;;
esac
unset NANOSTACK_STORE

# ─── Cell 9: symlinked visual root rejected ─────────────────
printf "\n  ${DIM}Cell 9: symlinked visual root rejected${NC}\n"
PROJ="$TMP_ROOT/cell9"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
mkdir -p "$TMP_ROOT/cell9-elsewhere"
ln -s "$TMP_ROOT/cell9-elsewhere" "$NANOSTACK_STORE/visual"
assert_exit "symlinked visual root exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"

# ─── Summary ────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
printf "\n  %s/%s checks passed\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf "${RED}=== %s checks failed ===${NC}\n" "$FAIL"
  exit 1
fi
printf "${GREEN}=== all checks passed ===${NC}\n"
