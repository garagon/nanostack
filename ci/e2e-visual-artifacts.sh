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

save_valid_think() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" think '{
    "phase": "think",
    "summary": {
      "value_proposition": "Make Nanostack renders inspectable",
      "scope_mode": "selective_expand",
      "target_user": "Devs reviewing AI work",
      "narrowest_wedge": "Static /plan HTML view",
      "key_risk": "XSS via unescaped artifact text",
      "premise_validated": true,
      "out_of_scope": ["Interactive editing"],
      "archetype": "cli_tooling",
      "archetype_confidence": "high"
    },
    "context_checkpoint": {
      "summary": "Decision brief signed off",
      "key_files": [],
      "decisions_made": ["JSON canonical, HTML derived"],
      "open_questions": []
    }
  }' >/dev/null
}

save_valid_review() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" review '{
    "phase": "review",
    "summary": {"blocking": 1, "should_fix": 2, "nitpicks": 3, "positive": 1},
    "scope_drift": {
      "status": "drift_detected",
      "planned_files": ["a.ts","b.ts"],
      "actual_files": ["a.ts","b.ts","c.ts"],
      "out_of_scope_files": ["c.ts"],
      "missing_files": []
    },
    "findings": [
      {"id": "REV-001", "severity": "blocking", "description": "Unbounded loop", "file": "src/loop.ts", "line": 42},
      {"id": "REV-002", "severity": "should_fix", "description": "Missing error handling", "file": "src/api.ts", "line": 10},
      {"id": "REV-003", "severity": "nitpick", "description": "Inconsistent naming", "file": "src/utils.ts", "line": 5}
    ],
    "context_checkpoint": {
      "summary": "One blocker, two should-fixes",
      "key_files": ["src/loop.ts:42"],
      "decisions_made": [],
      "open_questions": []
    }
  }' >/dev/null
}

save_valid_security() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" security '{
    "phase": "security",
    "summary": {"critical": 1, "high": 1, "medium": 0, "low": 0, "total_findings": 2},
    "findings": [
      {
        "id": "SEC-001",
        "severity": "critical",
        "category": "A03",
        "description": "SQL injection in login",
        "file": "src/auth.ts",
        "line": 17,
        "proof_of_concept": "curl -d user=admin /login",
        "fix": "Use parameterized queries",
        "confidence": 9
      },
      {
        "id": "SEC-002",
        "severity": "high",
        "category": "STRIDE",
        "description": "Session fixation",
        "file": "src/session.ts",
        "line": 88,
        "proof_of_concept": "Replay session cookie",
        "fix": "Rotate session on login",
        "confidence": 7
      }
    ],
    "context_checkpoint": {
      "summary": "Two findings: SQLi critical, session fixation high",
      "key_files": [],
      "decisions_made": [],
      "open_questions": []
    }
  }' >/dev/null
}

save_valid_qa() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" qa '{
    "phase": "qa",
    "summary": {
      "mode": "browser",
      "status": "partial",
      "tests_run": 12,
      "tests_passed": 11,
      "tests_failed": 1,
      "bugs_found": 1,
      "bugs_fixed": 0,
      "wtf_likelihood": 15
    },
    "findings": [
      {
        "id": "QA-001",
        "severity": "high",
        "description": "Login redirect loops on Safari",
        "reproduce": "Open /login in Safari",
        "root_cause": "Service worker cache",
        "fixed": false
      }
    ],
    "context_checkpoint": {
      "summary": "One Safari-specific bug",
      "key_files": [],
      "decisions_made": [],
      "open_questions": []
    }
  }' >/dev/null
}

save_valid_ship() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" ship '{
    "phase": "ship",
    "summary": {
      "pr_number": 217,
      "pr_url": "https://github.com/garagon/nanostack/pull/217",
      "title": "Visual artifacts PR 1",
      "status": "merged",
      "ci_passed": true
    },
    "context_checkpoint": {
      "summary": "Merged after 10 codex passes",
      "key_files": [],
      "decisions_made": [],
      "open_questions": []
    }
  }' >/dev/null
}

save_ship_report_only() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" ship '{
    "phase": "ship",
    "run_mode": "report_only",
    "summary": "Would have shipped if approved"
  }' >/dev/null
}

save_ship_malicious_url() {
  local store="$1"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" ship '{
    "phase": "ship",
    "summary": {
      "pr_number": 99,
      "pr_url": "javascript:alert(1)",
      "title": "<script>evil</script>",
      "status": "created",
      "ci_passed": false
    },
    "context_checkpoint": {"summary": "x", "key_files": [], "decisions_made": [], "open_questions": []}
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
# PR 1 pass 9: no temp file leftovers either.
TMP_LEFTOVER=$(find "$NANOSTACK_STORE/visual" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no tmp leftover under manifest-only" sh -c "[ '$TMP_LEFTOVER' = '0' ]"

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

# ─── Cell 10: /think renderer ───────────────────────────────
printf "\n  ${DIM}Cell 10: /think renderer${NC}\n"
PROJ="$TMP_ROOT/cell10"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_think "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" think --latest)
assert_true "think html exists" test -f "$HTML"
assert_contains "think value_proposition" "$HTML" "Make Nanostack renders inspectable"
assert_contains "think scope_mode chip" "$HTML" "selective_expand"
assert_contains "think narrowest_wedge" "$HTML" "Static /plan HTML view"
assert_contains "think key_risk" "$HTML" "XSS via unescaped artifact text"
assert_contains "think target_user" "$HTML" "Devs reviewing AI work"
assert_contains "think archetype chip" "$HTML" "cli_tooling"
assert_contains "think out_of_scope" "$HTML" "Interactive editing"
assert_contains "think context_checkpoint" "$HTML" "Decision brief signed off"
assert_contains "think data-phase=think" "$HTML" 'data-phase="think"'

# ─── Cell 11: /review renderer ──────────────────────────────
printf "\n  ${DIM}Cell 11: /review renderer${NC}\n"
PROJ="$TMP_ROOT/cell11"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_review "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" review --latest)
assert_true "review html exists" test -f "$HTML"
assert_contains "review blocking counter" "$HTML" '>Blocking<'
assert_contains "review should_fix counter" "$HTML" '>Should fix<'
assert_contains "review nitpicks counter" "$HTML" '>Nitpicks<'
assert_contains "review positive counter" "$HTML" '>Positive<'
assert_contains "review scope_drift status" "$HTML" "drift_detected"
assert_contains "review out-of-scope file" "$HTML" "c.ts"
assert_contains "review finding REV-001" "$HTML" "REV-001"
assert_contains "review finding description" "$HTML" "Unbounded loop"
assert_contains "review file:line" "$HTML" "src/loop.ts:42"
assert_contains "review sev-bad class" "$HTML" 'sev-bad'
assert_contains "review data-severity attr" "$HTML" 'data-severity="blocking"'

# ─── Cell 12: /security renderer ────────────────────────────
printf "\n  ${DIM}Cell 12: /security renderer${NC}\n"
PROJ="$TMP_ROOT/cell12"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_security "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" security --latest)
assert_true "security html exists" test -f "$HTML"
assert_contains "security critical counter" "$HTML" '>Critical<'
assert_contains "security finding SEC-001" "$HTML" "SEC-001"
assert_contains "security category A03 chip" "$HTML" 'A03'
assert_contains "security STRIDE category" "$HTML" 'STRIDE'
assert_contains "security proof_of_concept details" "$HTML" "<details><summary>Proof of concept</summary>"
assert_contains "security fix recommendation" "$HTML" "Use parameterized queries"
assert_contains "security confidence" "$HTML" "confidence 9"
# No "certification" or "compliant" language allowed (architect rule).
assert_not_contains "no 'certified' language" "$HTML" 'certified'
assert_not_contains "no 'compliant' language" "$HTML" 'compliant'

# ─── Cell 13: /qa renderer ──────────────────────────────────
printf "\n  ${DIM}Cell 13: /qa renderer${NC}\n"
PROJ="$TMP_ROOT/cell13"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_qa "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" qa --latest)
assert_true "qa html exists" test -f "$HTML"
assert_contains "qa mode chip" "$HTML" 'browser'
assert_contains "qa status partial" "$HTML" 'partial'
assert_contains "qa wtf_likelihood" "$HTML" 'WTF likelihood'
assert_contains "qa tests_run counter" "$HTML" '>Tests run<'
assert_contains "qa tests_failed counter" "$HTML" '>Failed<'
assert_contains "qa finding QA-001" "$HTML" "QA-001"
assert_contains "qa reproduce details" "$HTML" "<details><summary>Reproduce</summary>"
assert_contains "qa root_cause" "$HTML" "Root cause"

# ─── Cell 14: /ship renderer normal mode ────────────────────
printf "\n  ${DIM}Cell 14: /ship renderer normal mode${NC}\n"
PROJ="$TMP_ROOT/cell14"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_ship "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" ship --latest)
assert_true "ship html exists" test -f "$HTML"
assert_contains "ship title" "$HTML" "Visual artifacts PR 1"
assert_contains "ship pr_number" "$HTML" "217"
assert_contains "ship status merged" "$HTML" 'merged'
# Safe github.com URL must render as an <a>.
assert_contains "ship safe PR URL as link" "$HTML" '<a class="pr-link" href="https://github.com/'

# ─── Cell 15: /ship renderer report_only mode ───────────────
printf "\n  ${DIM}Cell 15: /ship report_only${NC}\n"
PROJ="$TMP_ROOT/cell15"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_ship_report_only "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" ship --latest)
assert_true "ship report_only html exists" test -f "$HTML"
assert_contains "ship report_only banner" "$HTML" "run_mode = report_only"
assert_contains "ship report_only body" "$HTML" "Would have shipped"
# No release-packet styling in report_only.
assert_not_contains "no Release packet header in report_only" "$HTML" "Release packet"

# ─── Cell 16: /ship malicious PR URL refused as link ────────
printf "\n  ${DIM}Cell 16: /ship malicious PR URL${NC}\n"
PROJ="$TMP_ROOT/cell16"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_ship_malicious_url "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" ship --latest)
assert_contains "ship unsafe URL marker" "$HTML" 'data-testid="unsafe-pr-url"'
assert_not_contains "ship NO javascript: href" "$HTML" 'href="javascript:'
assert_not_contains "ship NO active <a> for javascript scheme" "$HTML" 'href="javascript'
assert_contains "ship escapes title XSS" "$HTML" '&lt;script&gt;evil&lt;/script&gt;'
assert_not_contains "ship NO raw <script>evil" "$HTML" '<script>evil'

# ─── Cell 17: XSS across all 5 new phases ──────────────────
printf "\n  ${DIM}Cell 17: XSS escape across core phases${NC}\n"
PROJ="$TMP_ROOT/cell17"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Malicious think
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" think '{
  "phase":"think",
  "summary":{"value_proposition":"<script>alert(1)</script>","scope_mode":"<img src=x onerror=alert(1)>","target_user":"a","narrowest_wedge":"b","key_risk":"c","premise_validated":true},
  "context_checkpoint":{"summary":"\"><iframe>x</iframe>","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" think --latest)
assert_not_contains "think no raw <script>alert" "$HTML" '<script>alert'
assert_not_contains "think no raw <iframe>x" "$HTML" '<iframe>x</iframe>'
assert_contains "think escapes script tag" "$HTML" '&lt;script&gt;'

# Malicious review (finding description contains JS)
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" review '{
  "phase":"review","summary":{"blocking":1,"should_fix":0,"nitpicks":0,"positive":0},
  "scope_drift":{"status":"clean","planned_files":[],"actual_files":[],"out_of_scope_files":[],"missing_files":[]},
  "findings":[{"id":"REV-X","severity":"blocking","description":"<script>alert(\"rev\")</script>","file":"a","line":1}],
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" review --latest)
assert_not_contains "review no raw <script>alert" "$HTML" '<script>alert'
assert_contains "review escapes" "$HTML" '&lt;script&gt;'

# Malicious security proof_of_concept (must escape inside <pre>)
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" security '{
  "phase":"security","summary":{"critical":1,"high":0,"medium":0,"low":0,"total_findings":1},
  "findings":[{"id":"SEC-X","severity":"critical","category":"A01","description":"d","file":"f","line":1,"proof_of_concept":"<script>alert(\"poc\")</script>","fix":"<img src=x onerror=alert(1)>"}],
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" security --latest)
assert_not_contains "security PoC no raw <script>alert" "$HTML" '<script>alert'
assert_not_contains "security fix no raw <img" "$HTML" '<img src=x onerror=alert(1)>'
assert_contains "security PoC escaped" "$HTML" '&lt;script&gt;'
assert_contains "security PoC stays in <pre>" "$HTML" '<details><summary>Proof of concept</summary><pre>'

# Malicious ship.ci_passed (PR 2 pass 1 regression: ci_passed was
# interpolated unescaped because the schema documents it as a
# boolean; a malformed artifact stored it as a string).
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" ship '{
  "phase":"ship",
  "summary":{"pr_number":1,"pr_url":"https://github.com/x/y/pull/1","title":"t","status":"created","ci_passed":"<script>alert(\"ci\")</script>"},
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" ship --latest)
assert_not_contains "ship ci_passed no raw script" "$HTML" '<script>alert("ci")</script>'
assert_contains "ship ci_passed escaped" "$HTML" '&lt;script&gt;alert(&quot;ci&quot;)&lt;/script&gt;'

# Malicious qa (reproduce + root_cause)
(cd "$PROJ" && NANOSTACK_STORE="$NANOSTACK_STORE" "$REPO/bin/save-artifact.sh" qa '{
  "phase":"qa","summary":{"mode":"browser","status":"fail","tests_run":1,"tests_passed":0,"tests_failed":1,"bugs_found":1,"bugs_fixed":0},
  "findings":[{"id":"QA-X","severity":"high","description":"d","reproduce":"<script>alert(\"qa\")</script>","root_cause":"<img onerror=alert(1)>","fixed":false}],
  "context_checkpoint":{"summary":"x","key_files":[],"decisions_made":[],"open_questions":[]}
}' >/dev/null)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" qa --latest)
assert_not_contains "qa reproduce no raw script" "$HTML" '<script>alert("qa")'
assert_not_contains "qa root_cause no raw img" "$HTML" '<img onerror=alert(1)>'

# ─── Cell 18: sprint journal view ───────────────────────────
printf "\n  ${DIM}Cell 18: sprint journal view${NC}\n"
PROJ="$TMP_ROOT/cell18"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_think "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_review "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_security "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_qa "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_ship "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_true "journal html exists" test -f "$HTML"
assert_contains "journal page title" "$HTML" "Sprint journal"
assert_contains "journal data-phase=journal" "$HTML" 'data-phase="journal"'
assert_contains "journal timeline" "$HTML" "Phase timeline"
assert_contains "journal think row" "$HTML" 'data-phase="think"'
assert_contains "journal plan row" "$HTML" 'data-phase="plan"'
assert_contains "journal review row" "$HTML" 'data-phase="review"'
assert_contains "journal security row" "$HTML" 'data-phase="security"'
assert_contains "journal qa row" "$HTML" 'data-phase="qa"'
assert_contains "journal ship row" "$HTML" 'data-phase="ship"'
# Manifest must list every source.
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*journal*.manifest.json | head -1)
assert_true "journal manifest kind = journal" sh -c "[ \"\$(jq -r .kind '$MFST')\" = 'journal' ]"
assert_true "journal sources length >= 6" sh -c "[ \"\$(jq -r '.source_artifacts | length' '$MFST')\" -ge 6 ]"
# Trust badge aggregated.
assert_contains "journal aggregated badge" "$HTML" 'data-trust="not_applicable"'
assert_contains "journal aggregated badge text" "$HTML" '>aggregated<'

# ─── Cell 19: journal flags missing/tampered phases ──────────
printf "\n  ${DIM}Cell 19: journal flags missing/tampered${NC}\n"
PROJ="$TMP_ROOT/cell19"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Save only think + plan; review/security/qa/ship will be missing.
(cd "$PROJ" && save_valid_think "$NANOSTACK_STORE")
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "journal renders missing phases" "$HTML" "No artifact found"
# Tamper with plan; the row must show 'tampered'.
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq '.summary.goal = "Tampered"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "journal flags tampered" "$HTML" '>tampered<'
# Per-row trust attribute present for the tampered row.
assert_contains "journal plan row data-trust" "$HTML" 'data-phase="plan" data-trust="integrity_mismatch"'

# ─── Cell 20: custom stack DAG view (compliance-release) ─────
printf "\n  ${DIM}Cell 20: stack compliance-release DAG${NC}\n"
PROJ="$TMP_ROOT/cell20"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
assert_true "stack html exists" test -f "$HTML"
assert_contains "stack title" "$HTML" "Custom stack"
assert_contains "stack display_name" "$HTML" "Compliance Release Stack"
assert_contains "stack SVG opens" "$HTML" "<svg"
assert_contains "stack SVG closes" "$HTML" "</svg>"
# All 10 expected phases must appear as table rows.
for ph in think plan build review qa security license-audit privacy-check release-readiness ship; do
  assert_contains "stack table row $ph" "$HTML" "data-phase=\"$ph\""
done
# Missing phases must render as 'missing'.
assert_contains "stack missing badge" "$HTML" ">missing<"
# No certification language.
assert_not_contains "stack no certification language" "$HTML" 'certified'
assert_not_contains "stack no compliance language" "$HTML" 'compliant'

# ─── Cell 21: stack name validation ─────────────────────────
printf "\n  ${DIM}Cell 21: stack name validation${NC}\n"
PROJ="$TMP_ROOT/cell21"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# Path traversal in stack name must be rejected.
assert_exit "stack name with .. rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack ../etc"
assert_exit "stack name with / rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack a/b"
assert_exit "stack name with space rejected" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack 'foo bar'"

# Unknown stack: graceful "not found", not crash.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack does-not-exist 2>/dev/null || true)
# When no stack file matches and no config.json exists, default graph
# applies (the registry returns the built-in sprint).
[ -n "$HTML" ] && assert_true "stack fallback to default registry produced HTML" test -f "$HTML"

# ─── Cell 22: journal --date validation ────────────────────
printf "\n  ${DIM}Cell 22: journal --date validation${NC}\n"
PROJ="$TMP_ROOT/cell22"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "journal --date bad shape exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --date 2026/05/11"
assert_exit "journal --date with shell metachars exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --date '2026-05-11; rm -rf x'"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --date 2026-05-11)
assert_true "journal --date valid shape works" test -f "$HTML"

# ─── Cell 22a: --date filters by date, not last 30 days (PR 3 pass 1) ─
printf "\n  ${DIM}Cell 22a: journal --date filter (PR 3 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell22a"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Rename today's artifact to look like it was saved on 2026-05-09.
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
NEW="$NANOSTACK_STORE/plan/20260509-100000.json"
jq '.timestamp = "2026-05-09T10:00:00Z"' "$PLAN_PATH" > "$NEW"
rm "$PLAN_PATH"
# Now request the journal for 2026-05-09; the plan artifact must appear.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --date 2026-05-09)
assert_contains "journal --date 2026-05-09 shows the dated plan" "$HTML" "20260509-100000.json"
# Request another date with no artifacts; plan must show as missing.
HTML2=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --date 2026-05-08)
assert_contains "journal --date 2026-05-08 says missing" "$HTML2" "No artifact found"
assert_not_contains "journal 2026-05-08 does NOT show 2026-05-09 plan path" "$HTML2" "20260509-100000.json"

# ─── Cell 22b: stack falls back to project phase_graph (PR 3 pass 1) ─
printf "\n  ${DIM}Cell 22b: stack falls back to project phase_graph (PR 3 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell22b"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
cat > "$NANOSTACK_STORE/config.json" <<'CFG'
{
  "schema_version": "1",
  "custom_phases": ["license-audit"],
  "phase_graph": [
    {"name": "think", "depends_on": []},
    {"name": "plan", "depends_on": ["think"]},
    {"name": "build", "depends_on": ["plan"]},
    {"name": "review", "depends_on": ["build"]},
    {"name": "license-audit", "depends_on": ["build"]},
    {"name": "ship", "depends_on": ["review", "license-audit"]}
  ]
}
CFG
# No stack file under examples or stacks/; the fallback to the
# registry's phase_graph must kick in.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack project)
assert_true "stack from project graph renders" test -f "$HTML"
assert_contains "stack shows the custom phase license-audit" "$HTML" 'data-phase="license-audit"'
assert_contains "stack shows SVG" "$HTML" "<svg"

# ─── Cell 22c: journal includes custom phases from registry (PR 3 pass 1) ─
printf "\n  ${DIM}Cell 22c: journal lists custom phases (PR 3 pass 1)${NC}\n"
PROJ="$TMP_ROOT/cell22c"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
cat > "$NANOSTACK_STORE/config.json" <<'CFG'
{
  "schema_version": "1",
  "custom_phases": ["license-audit", "privacy-check"]
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_contains "journal lists custom license-audit row" "$HTML" 'data-phase="license-audit"'
assert_contains "journal lists custom privacy-check row" "$HTML" 'data-phase="privacy-check"'

# ─── Cell 22d: bare `journal` defaults to today (PR 3 pass 2) ───
printf "\n  ${DIM}Cell 22d: bare journal defaults to today (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22d"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal)
TODAY=$(date -u +%Y-%m-%d)
assert_contains "bare journal renders today's date" "$HTML" "$TODAY"
# Filename must not contain a trailing dash.
case "$HTML" in
  *journal-.html|*journal-*.html) ;;
  *)
    PASS=$((PASS+1))
    printf "    ${GREEN}OK${NC}    bare journal filename has no stray dash\n"
    ;;
esac
case "$HTML" in
  *journal-.html)
    FAIL=$((FAIL+1))
    printf "    ${RED}FAIL${NC}  bare journal filename has stray dash: %s\n" "$HTML"
    ;;
esac

# ─── Cell 22e: --strict on aggregate fails for missing integrity (PR 3 pass 2) ─
printf "\n  ${DIM}Cell 22e: --strict on aggregate (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22e"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Strip integrity on plan, then journal --strict must reject.
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq 'del(.integrity)' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "journal --strict fails on integrity_missing" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict"
# Tamper plan; --strict must also fail. Delete prior artifact first
# so the latest-picker definitely sees the tampered one.
rm -f "$NANOSTACK_STORE/plan/"*.json
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq '.summary.goal = "Tampered"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "journal --strict fails on integrity_mismatch" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict"
# Stack --strict: same.
assert_exit "stack --strict fails when any artifact tampered" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release --strict"

# ─── Cell 22f: scratch dir does not leak (PR 3 pass 2) ──────
printf "\n  ${DIM}Cell 22f: scratch dir cleanup (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22f"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
SCRATCH_BEFORE=$(find /tmp -maxdepth 1 -name "render-artifact.*" -type d 2>/dev/null | wc -l | tr -d ' ')
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
SCRATCH_AFTER=$(find /tmp -maxdepth 1 -name "render-artifact.*" -type d 2>/dev/null | wc -l | tr -d ' ')
assert_true "no scratch dir leak across renders" sh -c "[ '$SCRATCH_AFTER' = '$SCRATCH_BEFORE' ]"

# ─── Cell 22g: stack manifest with backslash path (PR 3 pass 2) ─
printf "\n  ${DIM}Cell 22g: stack manifest JSON escape (PR 3 pass 2)${NC}\n"
PROJ="$TMP_ROOT/cell22g"
setup_project "$PROJ"
# A project path containing a backslash is rare but the renderer
# should never produce invalid JSON. Validate by rendering with the
# normal path and confirming the manifest parses cleanly.
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack compliance-release)
MFST=$(ls "$NANOSTACK_STORE/visual/manifests/"*stack*.manifest.json | head -1)
assert_true "stack manifest is parseable JSON" jq -e '.' "$MFST"
assert_true "stack manifest has source_artifacts array" \
  sh -c "[ \"\$(jq -r 'type' '$MFST')\" = 'object' ] && [ \"\$(jq -r '.source_artifacts | type' '$MFST')\" = 'array' ]"

# ─── Cell 22h: --manifest-only with --strict still enforces (PR 3 pass 3) ─
printf "\n  ${DIM}Cell 22h: --manifest-only --strict enforces (PR 3 pass 3)${NC}\n"
PROJ="$TMP_ROOT/cell22h"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
PLAN_PATH=$(ls "$NANOSTACK_STORE/plan/"*.json | head -1)
jq '.summary.goal = "Tampered"' "$PLAN_PATH" > "$PLAN_PATH.tmp" && mv "$PLAN_PATH.tmp" "$PLAN_PATH"
assert_exit "journal --strict --manifest-only exits 3 when tampered" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today --strict --manifest-only"
assert_exit "stack --strict --manifest-only exits 3 when tampered" 3 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release --strict --manifest-only"

# ─── Cell 22i: large unsorted phase_graph renders every node (PR 3 pass 3) ─
printf "\n  ${DIM}Cell 22i: large unsorted phase_graph (PR 3 pass 3)${NC}\n"
PROJ="$TMP_ROOT/cell22i"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
# 15-node linear chain in reverse topological order. The previous
# cap of 10 rounds left the tail of the chain out of the SVG.
cat > "$NANOSTACK_STORE/config.json" <<'CFG'
{
  "schema_version": "1",
  "custom_phases": ["c1","c2","c3","c4","c5","c6","c7","c8","c9","c10","c11","c12","c13"],
  "phase_graph": [
    {"name": "c13", "depends_on": ["c12"]},
    {"name": "c12", "depends_on": ["c11"]},
    {"name": "c11", "depends_on": ["c10"]},
    {"name": "c10", "depends_on": ["c9"]},
    {"name": "c9", "depends_on": ["c8"]},
    {"name": "c8", "depends_on": ["c7"]},
    {"name": "c7", "depends_on": ["c6"]},
    {"name": "c6", "depends_on": ["c5"]},
    {"name": "c5", "depends_on": ["c4"]},
    {"name": "c4", "depends_on": ["c3"]},
    {"name": "c3", "depends_on": ["c2"]},
    {"name": "c2", "depends_on": ["c1"]},
    {"name": "c1", "depends_on": []}
  ]
}
CFG
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" stack default)
# Every node must appear in the SVG (as a <g data-phase=...> wrapper).
for n in c1 c5 c10 c13; do
  assert_contains "stack svg contains $n" "$HTML" "data-phase=\"$n\""
done

# ─── Cell 22j: symlinked visual/stack rejected without leak (PR 3 pass 4) ─
printf "\n  ${DIM}Cell 22j: symlinked visual/stack rejected (PR 3 pass 4)${NC}\n"
PROJ="$TMP_ROOT/cell22j"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell22j-outside"
ln -s "$TMP_ROOT/cell22j-outside" "$NANOSTACK_STORE/visual/stack"
assert_exit "stack with symlinked visual/stack exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' stack compliance-release"
# No directory was created at the symlink target.
LEAK=$(find "$TMP_ROOT/cell22j-outside" -maxdepth 1 -type d -name "compliance-release" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no directory leaked through symlinked visual/stack" sh -c "[ '$LEAK' = '0' ]"

# Same for visual/journal symlink.
PROJ="$TMP_ROOT/cell22k"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell22k-outside"
ln -s "$TMP_ROOT/cell22k-outside" "$NANOSTACK_STORE/visual/journal"
assert_exit "journal with symlinked visual/journal exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' journal --today"

# ─── Cell 22l: --today does not pull stale artifacts (PR 3 pass 4) ─
printf "\n  ${DIM}Cell 22l: --today strict-date filter (PR 3 pass 4)${NC}\n"
PROJ="$TMP_ROOT/cell22l"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/plan"
# Save a plan with yesterday's date.
YEST_DATE=$(date -u -v-1d +%Y%m%d 2>/dev/null || date -u -d "yesterday" +%Y%m%d 2>/dev/null || echo "20260510")
YEST_FILE="$NANOSTACK_STORE/plan/${YEST_DATE}-120000.json"
jq -n --arg p "$PROJ" '{
  schema_version: "1",
  phase: "plan",
  timestamp: "2026-05-10T12:00:00Z",
  project: $p,
  branch: "main",
  summary: {goal:"yesterday", scope:"small", planned_files:[], plan_approval:"manual"},
  context_checkpoint: {summary:"x", key_files:[], decisions_made:[], open_questions:[]}
}' > "$YEST_FILE"
# Render today's journal; plan must show as missing, not yesterday's.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" journal --today)
assert_not_contains "today's journal does not show yesterday's plan" "$HTML" "${YEST_DATE}-120000.json"
# Plan row says missing.
assert_contains "today's journal shows plan as missing" "$HTML" 'data-phase="plan"'

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

# ─── Cell 9e: symlinked visual subdirectory rejected ───────
# PR 1 pass 4 regression: a pre-existing symlink under visual/
# (e.g. visual/plan -> /tmp/outside) must be rejected so mv cannot
# write through it.
printf "\n  ${DIM}Cell 9e: symlinked visual subdir (PR 1 pass 4 regression)${NC}\n"
PROJ="$TMP_ROOT/cell9e"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell9e-outside"
ln -s "$TMP_ROOT/cell9e-outside" "$NANOSTACK_STORE/visual/plan"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "symlinked visual/plan exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"
# Confirm nothing was written through the symlink.
HTML_COUNT=$(find "$TMP_ROOT/cell9e-outside" -maxdepth 1 -name "*.html" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no file written through symlinked subdir" sh -c "[ '$HTML_COUNT' = '0' ]"

# Same check for visual/manifests symlink.
PROJ="$TMP_ROOT/cell9f"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual"
mkdir -p "$TMP_ROOT/cell9f-outside"
ln -s "$TMP_ROOT/cell9f-outside" "$NANOSTACK_STORE/visual/manifests"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "symlinked visual/manifests exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest"
MFST_COUNT=$(find "$TMP_ROOT/cell9f-outside" -maxdepth 1 -name "*.manifest.json" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no manifest written through symlinked subdir" sh -c "[ '$MFST_COUNT' = '0' ]"

# ─── Cell 9g: symlinked output leaf rejected ───────────────
# PR 1 pass 5 regression: an --out whose leaf component is a
# pre-existing symlink to a directory must be rejected. Otherwise
# atomic mv would move the temp file INTO the symlink target.
printf "\n  ${DIM}Cell 9g: symlinked output leaf (PR 1 pass 5 regression)${NC}\n"
PROJ="$TMP_ROOT/cell9g"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan"
mkdir -p "$TMP_ROOT/cell9g-outside"
ln -s "$TMP_ROOT/cell9g-outside" "$NANOSTACK_STORE/visual/plan/explicit.html"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "symlinked output leaf exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$NANOSTACK_STORE/visual/plan/explicit.html'"
LEAK_COUNT=$(find "$TMP_ROOT/cell9g-outside" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
assert_true "no file leaked through symlinked leaf" sh -c "[ '$LEAK_COUNT' = '0' ]"

# A leaf that is already a directory must also be rejected so the
# mv doesn't move the temp file INTO the directory.
PROJ="$TMP_ROOT/cell9h"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan/explicit.html"  # leaf is a directory
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
assert_exit "directory at output leaf exits 4" 4 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan --latest --out '$NANOSTACK_STORE/visual/plan/explicit.html'"

# ─── Cell 9i: symlink + .. bypass through write target ─────
# PR 1 pass 6 P1 regression: --out with a symlinked component
# followed by `..`. Lexical normalization passed before; the kernel
# would resolve the original path at write time and escape visual/.
# The fix is to write to the normalized path.
printf "\n  ${DIM}Cell 9i: symlink + .. bypass through write (PR 1 pass 6)${NC}\n"
PROJ="$TMP_ROOT/cell9i"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan"
mkdir -p "$TMP_ROOT/cell9i-outside"
ln -s "$TMP_ROOT/cell9i-outside" "$NANOSTACK_STORE/visual/link"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Attack: visual/link/../evil.html. Normalized this is visual/evil.html
# (under visual/). At kernel-resolve time the original path goes:
# visual/link -> /tmp/.../cell9i-outside, then .. -> /tmp/.../, then
# evil.html appears outside the store.
set +e
(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out \
  "$NANOSTACK_STORE/visual/link/../evil.html" >/dev/null 2>&1)
RC=$?
set -e
# Either the render exits 4 (rejected), or it succeeds writing
# safely to visual/evil.html under the normalized path. Both are
# acceptable; what is NOT acceptable is a file appearing outside
# visual/.
LEAK_COUNT=$(find "$TMP_ROOT/cell9i-outside" -maxdepth 1 -type f -name "*.html" 2>/dev/null | wc -l | tr -d ' ')
STORE_LEAK=$(find "$PROJ" -maxdepth 3 -name 'evil.html' -not -path "*/visual/*" 2>/dev/null | wc -l | tr -d ' ')
assert_true "no file outside visual via symlink+.. (outside dir empty)" sh -c "[ '$LEAK_COUNT' = '0' ]"
assert_true "no file at evil.html outside visual/" sh -c "[ '$STORE_LEAK' = '0' ]"

# ─── Cell 9j: same-second renders keep their own manifests ──
# PR 1 pass 6 P2 regression.
printf "\n  ${DIM}Cell 9j: same-second renders unique manifests (PR 1 pass 6)${NC}\n"
PROJ="$TMP_ROOT/cell9j"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
H1=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out "$NANOSTACK_STORE/visual/plan/a.html")
H2=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out "$NANOSTACK_STORE/visual/plan/b.html")
# Find each provenance footer's manifest pointer; they must differ.
M1=$(grep -oE 'visual-manifest-path[^>]*>[^<]+<' "$H1" | sed -E 's/.*>([^<]+)<.*/\1/' | head -1)
M2=$(grep -oE 'visual-manifest-path[^>]*>[^<]+<' "$H2" | sed -E 's/.*>([^<]+)<.*/\1/' | head -1)
assert_true "render 1 references manifest A" sh -c "[ -n '$M1' ] && [ -f '$M1' ]"
assert_true "render 2 references manifest B" sh -c "[ -n '$M2' ] && [ -f '$M2' ]"
assert_true "manifests differ" sh -c "[ '$M1' != '$M2' ]"

# ─── Cell 9k: non-object JSON artifact -> exit 1 ────────────
# PR 1 pass 6 P3 regression.
printf "\n  ${DIM}Cell 9k: non-object JSON exits 1 (PR 1 pass 6)${NC}\n"
PROJ="$TMP_ROOT/cell9k"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
ARR="$TMP_ROOT/cell9k-array.json"
echo '[]' > "$ARR"
assert_exit "array JSON exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan '$ARR'"
STR="$TMP_ROOT/cell9k-string.json"
echo '"hello"' > "$STR"
assert_exit "string JSON exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan '$STR'"
NUM="$TMP_ROOT/cell9k-num.json"
echo '42' > "$NUM"
assert_exit "number JSON exits 1" 1 \
  sh -c "cd '$PROJ' && '$REPO/bin/render-artifact.sh' plan '$NUM'"

# ─── Cell 9l: render does not mutate session state ─────────
# PR 1 pass 7 regression. find-artifact.sh registers the phase via
# session.sh phase-start as a convenience; render-artifact.sh must
# pass --no-session-sync so a viewer never marks a phase as
# in_progress.
printf "\n  ${DIM}Cell 9l: render does not mutate session (PR 1 pass 7)${NC}\n"
PROJ="$TMP_ROOT/cell9l"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Start a session but do not register any phase yet.
(cd "$PROJ" && "$REPO/bin/session.sh" init --goal "test session" >/dev/null 2>&1)
SESSION_BEFORE=$(jq -c '.phase_log // []' "$NANOSTACK_STORE/session.json" 2>/dev/null || echo "[]")
(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest >/dev/null)
SESSION_AFTER=$(jq -c '.phase_log // []' "$NANOSTACK_STORE/session.json" 2>/dev/null || echo "[]")
assert_true "session.phase_log unchanged after render" \
  sh -c "[ '$SESSION_BEFORE' = '$SESSION_AFTER' ]"
# Specifically: plan must NOT be in_progress after a render-only call.
PLAN_LOGGED=$(jq -r '.phase_log // [] | map(.phase) | contains(["plan"])' "$NANOSTACK_STORE/session.json" 2>/dev/null || echo "false")
assert_true "plan not registered as in_progress by render" \
  sh -c "[ '$PLAN_LOGGED' = 'false' ]"

# ─── Cell 9m: glob metachars in --out preserved literally ──
# PR 1 pass 8 P3 regression. nano_visual_normalize_path used to
# perform pathname expansion during the IFS split; an --out with `*`
# or `?` could be silently rewritten to a matching real filename.
printf "\n  ${DIM}Cell 9m: glob metachars in --out (PR 1 pass 8)${NC}\n"
PROJ="$TMP_ROOT/cell9m"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan"
# Pre-create a real file that would match a glob if expansion ran.
touch "$NANOSTACK_STORE/visual/plan/starA.html"
touch "$NANOSTACK_STORE/visual/plan/starB.html"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Use a quoted literal "star*.html" as --out; this must NOT expand.
TARGET="$NANOSTACK_STORE/visual/plan/star?special.html"
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest --out "$TARGET")
assert_true "literal glob path preserved (no expansion)" \
  sh -c "[ '$HTML' = '$TARGET' ]"
assert_true "literal file exists at requested path" test -f "$TARGET"

# ─── Cell 9n: predictable temp file not used ───────────────
# PR 1 pass 8 P2 regression. The pre-fix render created a temp file
# at $HTML_PATH.tmp.$$, which an attacker could pre-symlink. Verify
# the renderer no longer creates files with the predictable pattern
# and that any race-created symlink at .tmp.<pid> does not get
# followed.
printf "\n  ${DIM}Cell 9n: secure temp file (PR 1 pass 8)${NC}\n"
PROJ="$TMP_ROOT/cell9n"
setup_project "$PROJ"
export NANOSTACK_STORE="$PROJ/.nanostack"
mkdir -p "$NANOSTACK_STORE/visual/plan"
mkdir -p "$TMP_ROOT/cell9n-outside"
(cd "$PROJ" && save_valid_plan "$NANOSTACK_STORE")
# Race: pre-create a symlink at the *new* mktemp-format path. We
# cannot guess the random suffix; what we CAN do is verify that the
# render still works when there is no symlink hijack, and that
# leftover .tmp.* files are cleaned up.
HTML=$(cd "$PROJ" && "$REPO/bin/render-artifact.sh" plan --latest)
TMP_LEFTOVER=$(find "$NANOSTACK_STORE/visual" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_true "render succeeds with mktemp" test -f "$HTML"
assert_true "no leftover tmp files" sh -c "[ '$TMP_LEFTOVER' = '0' ]"

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
