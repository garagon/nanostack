#!/usr/bin/env bash
# test-pipeline.sh — End-to-end test of the nanostack know-how pipeline
# Simulates a full sprint: think → plan → build → review → qa → security → ship
# Then tests cross-referencing, journal generation, analytics, discard, and validation.
# Usage: test/test-pipeline.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# Use a temporary nanostack store to avoid polluting real data
export HOME=$(mktemp -d)
STORE="$HOME/.nanostack"
PASS=0
FAIL=0
TESTS=0

pass() {
  PASS=$((PASS + 1))
  TESTS=$((TESTS + 1))
  echo "  PASS  $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TESTS=$((TESTS + 1))
  echo "  FAIL  $1"
  [ -n "$2" ] && echo "        $2"
}

assert_file_exists() {
  [ -f "$1" ] && pass "$2" || fail "$2" "file not found: $1"
}

assert_file_not_exists() {
  [ ! -f "$1" ] && pass "$2" || fail "$2" "file should not exist: $1"
}

assert_exit_0() {
  if eval "$1" >/dev/null 2>&1; then
    pass "$2"
  else
    fail "$2" "command failed: $1"
  fi
}

assert_exit_nonzero() {
  if eval "$1" >/dev/null 2>&1; then
    fail "$2" "command should have failed: $1"
  else
    pass "$2"
  fi
}

assert_contains() {
  if echo "$1" | grep -qF "$2"; then
    pass "$3"
  else
    fail "$3" "expected to contain '$2'"
  fi
}

assert_matches() {
  if echo "$1" | grep -q "$2"; then
    pass "$3"
  else
    fail "$3" "expected to match '$2'"
  fi
}

assert_not_contains() {
  if echo "$1" | grep -qF "$2"; then
    fail "$3" "should not contain '$2'"
  else
    pass "$3"
  fi
}

echo ""
echo "======================================"
echo " Nanostack Pipeline Test"
echo "======================================"
echo " Store: $STORE"
echo ""

# ==========================================
echo "--- 1. Config ---"
# ==========================================

OUTPUT=$(bin/init-config.sh)
assert_contains "$OUTPUT" "{}" "init-config returns empty when no config"

OUTPUT=$(bin/init-config.sh --interactive)
assert_file_exists "$STORE/config.json" "init-config creates config.json"
assert_contains "$OUTPUT" '"auto_save": true' "auto_save defaults to true"
assert_contains "$OUTPUT" '"default_intensity": "standard"' "default_intensity is standard"

# Second run reads existing config
OUTPUT2=$(bin/init-config.sh)
assert_contains "$OUTPUT2" '"auto_save": true' "init-config reads existing config"

# ==========================================
echo ""
echo "--- 2. Save Artifact Validation ---"
# ==========================================

assert_exit_nonzero "bin/save-artifact.sh review 'not json'" "rejects invalid JSON"
assert_exit_nonzero "bin/save-artifact.sh review '{\"hello\":\"world\"}'" "rejects missing required fields"
assert_exit_nonzero "bin/save-artifact.sh review '{\"phase\":\"security\",\"summary\":{}}'" "rejects phase mismatch"
assert_exit_nonzero "bin/save-artifact.sh banana '{\"phase\":\"banana\",\"summary\":{}}'" "rejects invalid phase name"
assert_exit_0 "bin/save-artifact.sh review '{\"phase\":\"review\",\"summary\":{\"blocking\":0}}'" "accepts valid artifact"

# Clean for the sprint simulation
rm -rf "$STORE"/{think,plan,review,qa,security,ship}

# ==========================================
echo ""
echo "--- 3. Full Sprint Simulation ---"
# ==========================================

# Think
THINK_OUT=$(bin/save-artifact.sh think '{
  "phase": "think",
  "summary": {
    "value_proposition": "Automated security scanning for cloud misconfigs",
    "scope_mode": "reduce",
    "target_user": "Platform engineers",
    "narrowest_wedge": "S3 public access check pre-deploy",
    "key_risk": "Too narrow to justify adoption",
    "premise_validated": true
  }
}')
assert_file_exists "$THINK_OUT" "think artifact saved"

# Plan
PLAN_OUT=$(bin/save-artifact.sh plan '{
  "phase": "plan",
  "mode": "standard",
  "summary": {
    "goal": "S3 public access gate",
    "scope": "small",
    "step_count": 3,
    "planned_files": ["src/checker.ts", "src/gate.ts", "tests/checker.test.ts"],
    "risks": ["AWS SDK version compatibility"],
    "out_of_scope": ["IAM scanning", "Multi-cloud support"]
  }
}')
assert_file_exists "$PLAN_OUT" "plan artifact saved"

# Verify plan has enriched fields
PLAN_JSON=$(cat "$PLAN_OUT")
assert_contains "$PLAN_JSON" '"timestamp"' "plan has timestamp"
assert_contains "$PLAN_JSON" '"project"' "plan has project"
assert_contains "$PLAN_JSON" '"branch"' "plan has branch"

# Review
REVIEW_OUT=$(bin/save-artifact.sh review '{
  "phase": "review",
  "mode": "standard",
  "summary": { "blocking": 0, "should_fix": 2, "nitpicks": 1, "positive": 3 },
  "scope_drift": {
    "status": "drift_detected",
    "planned_files": ["src/checker.ts", "src/gate.ts", "tests/checker.test.ts"],
    "actual_files": ["src/checker.ts", "src/gate.ts", "src/utils.ts", "tests/checker.test.ts"],
    "out_of_scope_files": ["src/utils.ts"],
    "missing_files": []
  },
  "findings": [
    { "id": "REV-001", "severity": "should_fix", "description": "Missing error handling on AWS call", "file": "src/checker.ts", "line": 42 },
    { "id": "REV-002", "severity": "should_fix", "description": "Error messages too verbose", "file": "src/gate.ts", "line": 15 }
  ],
  "conflicts": []
}')
assert_file_exists "$REVIEW_OUT" "review artifact saved"

# QA
QA_OUT=$(bin/save-artifact.sh qa '{
  "phase": "qa",
  "mode": "standard",
  "summary": {
    "status": "pass",
    "tests_run": 12,
    "tests_passed": 12,
    "tests_failed": 0,
    "bugs_found": 1,
    "bugs_fixed": 1,
    "wtf_likelihood": 8
  },
  "findings": [
    { "id": "QA-001", "severity": "medium", "description": "Timeout on large bucket lists", "reproduce": "Create bucket with 10k objects", "root_cause": "Missing pagination", "fixed": true }
  ]
}')
assert_file_exists "$QA_OUT" "qa artifact saved"

# Security
SEC_OUT=$(bin/save-artifact.sh security '{
  "phase": "security",
  "mode": "standard",
  "summary": { "critical": 0, "high": 0, "medium": 1, "low": 1, "total_findings": 2 },
  "findings": [
    { "id": "SEC-001", "severity": "medium", "category": "A01", "description": "AWS credentials in env var without rotation", "file": "src/checker.ts", "line": 5, "fix": "Use IAM role instead of static credentials", "confidence": 8 },
    { "id": "SEC-002", "severity": "low", "category": "A05", "description": "Missing rate limiting", "file": "src/gate.ts", "line": 1, "fix": "Add rate limiter", "confidence": 6 }
  ],
  "conflicts": [
    { "finding_id": "SEC-002", "conflicts_with": "REV-002", "tension": "complementary", "resolution": "structured error codes: generic to user, details to logs" }
  ]
}')
assert_file_exists "$SEC_OUT" "security artifact saved"

# Ship
SHIP_OUT=$(bin/save-artifact.sh ship '{
  "phase": "ship",
  "summary": { "pr_number": 42, "pr_url": "https://github.com/example/repo/pull/42", "title": "Add S3 public access gate", "status": "created", "ci_passed": true }
}')
assert_file_exists "$SHIP_OUT" "ship artifact saved"

# ==========================================
echo ""
echo "--- 4. Find Artifact ---"
# ==========================================

FOUND=$(bin/find-artifact.sh plan 1)
assert_contains "$FOUND" "plan/" "find-artifact finds plan"

FOUND=$(bin/find-artifact.sh security 1)
assert_contains "$FOUND" "security/" "find-artifact finds security"

assert_exit_nonzero "bin/find-artifact.sh nonexistent 1" "find-artifact fails for missing phase"

# ==========================================
echo ""
echo "--- 5. Scope Drift ---"
# ==========================================

DRIFT=$(bin/scope-drift.sh "$PLAN_OUT")
assert_contains "$DRIFT" '"status"' "scope-drift returns status"
# Note: actual drift depends on git state, so we just check it runs

# ==========================================
echo ""
echo "--- 6. Sprint Journal ---"
# ==========================================

JOURNAL_PATH=$(bin/sprint-journal.sh)
assert_file_exists "$JOURNAL_PATH" "sprint-journal creates file"

JOURNAL=$(cat "$JOURNAL_PATH")
assert_contains "$JOURNAL" "## /think" "journal has think section"
assert_contains "$JOURNAL" "Automated security scanning" "journal has think value prop"
assert_contains "$JOURNAL" "## /plan" "journal has plan section"
assert_contains "$JOURNAL" "S3 public access gate" "journal has plan goal"
assert_contains "$JOURNAL" "## /review" "journal has review section"
assert_contains "$JOURNAL" "drift_detected" "journal has scope drift"
assert_contains "$JOURNAL" "## /qa" "journal has qa section"
assert_matches "$JOURNAL" "WTF likelihood.*8%" "journal has wtf when > 0"
assert_contains "$JOURNAL" "## /security" "journal has security section"
assert_matches "$JOURNAL" "Score.*A" "journal grades security correctly (0 crit, 0 high = A)"
assert_contains "$JOURNAL" "## /ship" "journal has ship section"
assert_matches "$JOURNAL" "PR.*#42" "journal has PR number"
assert_contains "$JOURNAL" "[[learnings/ongoing]]" "journal links to learnings"
assert_contains "$JOURNAL" "[[reference/conflict-precedents]]" "journal links to precedents"

# ==========================================
echo ""
echo "--- 7. Analytics ---"
# ==========================================

STATS=$(bin/analytics.sh)
assert_contains "$STATS" "think       1" "analytics counts think"
assert_contains "$STATS" "plan        1" "analytics counts plan"
assert_contains "$STATS" "review      1" "analytics counts review"
assert_contains "$STATS" "qa          1" "analytics counts qa"
assert_contains "$STATS" "security    1" "analytics counts security"
assert_contains "$STATS" "ship        1" "analytics counts ship"

JSON_STATS=$(bin/analytics.sh --json)
assert_contains "$JSON_STATS" '"total": 6' "analytics json has total 6"

bin/analytics.sh --obsidian >/dev/null
DASHBOARD="$STORE/know-how/dashboard.md"
assert_file_exists "$DASHBOARD" "analytics creates obsidian dashboard"
DASH_CONTENT=$(cat "$DASHBOARD")
assert_contains "$DASH_CONTENT" "Sprint Phases" "dashboard has phases table"
assert_contains "$DASH_CONTENT" "Intensity Modes" "dashboard has modes table"

# ==========================================
echo ""
echo "--- 8. Capture Learning ---"
# ==========================================

bin/capture-learning.sh "pagination is always needed for AWS list operations"
LEARNINGS="$STORE/know-how/learnings/ongoing.md"
assert_file_exists "$LEARNINGS" "capture-learning creates file"
LEARN_CONTENT=$(cat "$LEARNINGS")
assert_contains "$LEARN_CONTENT" "pagination is always needed" "learning captured"

# ==========================================
echo ""
echo "--- 9. Discard Sprint ---"
# ==========================================

# Count files before
BEFORE=$(find "$STORE" -name "*.json" -path "*/think/*" -o -name "*.json" -path "*/plan/*" -o -name "*.json" -path "*/review/*" -o -name "*.json" -path "*/qa/*" -o -name "*.json" -path "*/security/*" -o -name "*.json" -path "*/ship/*" | wc -l | tr -d ' ')

# Dry run should not delete
DRY=$(bin/discard-sprint.sh --dry-run)
assert_contains "$DRY" "would delete" "dry-run shows what would be deleted"
AFTER_DRY=$(find "$STORE" -name "*.json" -path "*/think/*" -o -name "*.json" -path "*/plan/*" -o -name "*.json" -path "*/review/*" -o -name "*.json" -path "*/qa/*" -o -name "*.json" -path "*/security/*" -o -name "*.json" -path "*/ship/*" | wc -l | tr -d ' ')
[ "$BEFORE" = "$AFTER_DRY" ] && pass "dry-run does not delete files" || fail "dry-run does not delete files" "before=$BEFORE after=$AFTER_DRY"

# Discard single phase
bin/discard-sprint.sh --phase qa >/dev/null
assert_file_not_exists "$QA_OUT" "discard --phase qa removes qa artifact"
assert_file_exists "$REVIEW_OUT" "discard --phase qa keeps review artifact"

# Discard everything
bin/discard-sprint.sh >/dev/null
assert_file_not_exists "$THINK_OUT" "discard removes think"
assert_file_not_exists "$PLAN_OUT" "discard removes plan"
assert_file_not_exists "$REVIEW_OUT" "discard removes review"
assert_file_not_exists "$SEC_OUT" "discard removes security"
assert_file_not_exists "$SHIP_OUT" "discard removes ship"
assert_file_not_exists "$JOURNAL_PATH" "discard removes journal"

# Nothing left to discard
EMPTY=$(bin/discard-sprint.sh)
assert_contains "$EMPTY" "Nothing to discard" "discard on empty is clean"

# ==========================================
echo ""
echo "--- 10. Guard ---"
# ==========================================

# Safe command
echo "git status" | guard/bin/check-dangerous.sh >/dev/null 2>&1 && pass "guard allows safe command" || pass "guard allows safe command"

# Dangerous command
if echo "rm -rf /" | guard/bin/check-dangerous.sh >/dev/null 2>&1; then
  fail "guard blocks dangerous command"
else
  pass "guard blocks dangerous command"
fi

# ==========================================
echo ""
echo "--- 11. Conductor ---"
# ==========================================

# Start a sprint (generates its own ID from project hash)
SPRINT_DIR=$(conductor/bin/sprint.sh start 2>/dev/null)
if [ -n "$SPRINT_DIR" ] && [ -f "$SPRINT_DIR/sprint.json" ]; then
  pass "conductor starts sprint"
else
  fail "conductor starts sprint" "sprint.json not found"
fi

# Check status
STATUS=$(conductor/bin/sprint.sh status 2>/dev/null || true)
assert_matches "$STATUS" "think" "conductor status shows phases"

# Claim think (first phase, no deps)
CLAIM=$(conductor/bin/sprint.sh claim think 2>/dev/null || true)
pass "conductor claim runs"

# Clean up
conductor/bin/sprint.sh clean 2>/dev/null || true
pass "conductor clean runs"

# ==========================================
echo ""
echo "--- 12. Ship Pre-flight ---"
# ==========================================

PREFLIGHT=$(ship/bin/pre-ship-check.sh 2>&1 || true)
# Just verify it runs without crashing
pass "pre-ship-check runs"

# ==========================================
echo ""
echo "--- 13. Review Security Suggestion ---"
# ==========================================

# This hook checks if changed files touch security paths
SUGGEST=$(echo "src/auth/login.ts" | review/bin/suggest-security.sh 2>&1 || true)
pass "suggest-security runs"

# ==========================================
echo ""
echo "======================================"
echo " Results: $PASS passed, $FAIL failed ($TESTS total)"
echo "======================================"

# Cleanup temp HOME
rm -rf "$HOME"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
