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

register_custom_phase() {
  local store="$1" phase="$2"
  mkdir -p "$store"
  cat > "$store/config.json" <<JSON
{
  "schema_version": "1",
  "custom_phases": ["$phase"],
  "phase_graph": [
    {"name": "plan", "depends_on": []},
    {"name": "$phase", "depends_on": ["plan"]}
  ]
}
JSON
}

save_valid_custom() {
  local store="$1" phase="$2"
  NANOSTACK_STORE="$store" "$REPO/bin/save-artifact.sh" "$phase" "{
    \"phase\": \"$phase\",
    \"summary\": {
      \"status\": \"OK\",
      \"headline\": \"all licenses approved\",
      \"licenses_scanned\": 42,
      \"warnings\": {
        \"notes\": [\"MIT-OK\", \"Apache-2.0-OK\"]
      }
    },
    \"findings\": [
      {\"id\": \"LIC-001\", \"severity\": \"low\", \"description\": \"GPL-3.0 in subdep\"}
    ],
    \"context_checkpoint\": {
      \"summary\": \"License audit completed\",
      \"key_files\": [\"package.json\"],
      \"decisions_made\": [],
      \"open_questions\": []
    }
  }" >/dev/null
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

# ── Section runner (Harness Architecture vNext PR 4 split) ─────────────
# The cell bodies live in sourced section files under ci/visual-artifacts/.
# This driver owns the shared helpers/fixtures above and the summary below.
# Each section is sourced in declared order unless --filter selects a subset
# (e.g. --filter trust, --filter stack). Public entry point is unchanged.
VISUAL_SECTIONS="core-render trust-and-path-safety journal-render stack-render custom-phases interactive"
VA_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --filter) VA_FILTER="${2:-}"; shift 2 ;;
    --filter=*) VA_FILTER="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
_VA_DIR="$REPO/ci/visual-artifacts"

# Lock: every section file on disk must be declared in VISUAL_SECTIONS, and
# every declared section must have a file. An orphan section would silently
# never run; a stale name would silently drop coverage.
for _f in "$_VA_DIR"/*.sh; do
  [ -f "$_f" ] || continue
  _b=$(basename "$_f" .sh)
  case " $VISUAL_SECTIONS " in
    *" $_b "*) ;;
    *) printf "    ${RED}FAIL${NC}  section file not registered in the driver: %s.sh\n" "$_b"; FAIL=$((FAIL+1)) ;;
  esac
done

_va_matched=0
for _s in $VISUAL_SECTIONS; do
  if [ ! -f "$_VA_DIR/$_s.sh" ]; then
    printf "    ${RED}FAIL${NC}  missing section file: %s.sh\n" "$_s"; FAIL=$((FAIL+1)); continue
  fi
  if [ -n "$VA_FILTER" ]; then
    case "$_s" in *"$VA_FILTER"*) ;; *) continue ;; esac
  fi
  _va_matched=$((_va_matched+1))
  # shellcheck disable=SC1090
  . "$_VA_DIR/$_s.sh"
done
# A non-empty filter that matches no section is a mistake (typo or a stale
# name after a rename); fail instead of reporting a green 0/0 run.
if [ -n "$VA_FILTER" ] && [ "$_va_matched" -eq 0 ]; then
  printf "    ${RED}FAIL${NC}  --filter '%s' matched no section (of: %s)\n" "$VA_FILTER" "$VISUAL_SECTIONS"
  FAIL=$((FAIL+1))
fi

# ─── Summary ────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -gt 0 ]; then
  printf "${RED}=== %s checks failed ===${NC}\n" "$FAIL"
  exit 1
fi
# The count line goes last: run-harness.sh parses the final non-empty
# line of the output for the expected_checks floor.
printf "${GREEN}=== all checks passed ===${NC}\n"
printf "\n  %s/%s checks passed\n" "$PASS" "$TOTAL"
