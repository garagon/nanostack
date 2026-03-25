#!/usr/bin/env bash
# sprint-journal.sh — Generate an Obsidian journal entry from sprint artifacts
# Usage: sprint-journal.sh [--project <name>]
# Reads ~/.nanostack/ artifacts and writes to docs/journal/<date>-<project>.md
set -e

STORE="$HOME/.nanostack"
KNOW_HOW="$HOME/.nanostack/know-how"
PROJECT_NAME="${2:-$(basename "$(pwd)")}"
DATE=$(date +"%Y-%m-%d")
MONTH=$(date +"%Y-%m")
JOURNAL_DIR="$KNOW_HOW/journal"
JOURNAL_FILE="$JOURNAL_DIR/$DATE-$PROJECT_NAME.md"

mkdir -p "$JOURNAL_DIR"

# Find most recent artifact per phase
find_latest() {
  local phase="$1"
  local dir="$STORE/$phase"
  [ -d "$dir" ] || { echo ""; return 0; }
  ls -t "$dir"/*.json 2>/dev/null | head -1 || echo ""
}

# Extract field from JSON
field() {
  jq -r "$1 // \"\"" "$2" 2>/dev/null
}

# Start building the journal
{
  echo "# Sprint: $PROJECT_NAME ($DATE)"
  echo ""
  echo "---"
  echo "tags: [sprint, $PROJECT_NAME, $MONTH]"
  echo "---"
  echo ""

  # Think
  THINK_FILE=$(find_latest think)
  if [ -n "$THINK_FILE" ]; then
    echo "## /think"
    echo ""
    VP=$(field '.summary.value_proposition' "$THINK_FILE")
    SCOPE=$(field '.summary.scope_mode' "$THINK_FILE")
    WEDGE=$(field '.summary.narrowest_wedge' "$THINK_FILE")
    RISK=$(field '.summary.key_risk' "$THINK_FILE")
    [ -n "$VP" ] && echo "**Value proposition:** $VP"
    [ -n "$SCOPE" ] && echo "**Scope mode:** $SCOPE"
    [ -n "$WEDGE" ] && echo "**Narrowest wedge:** $WEDGE"
    [ -n "$RISK" ] && echo "**Key risk:** $RISK"
    echo ""
  fi

  # Plan
  PLAN_FILE=$(find_latest plan)
  if [ -n "$PLAN_FILE" ]; then
    echo "## /plan"
    echo ""
    GOAL=$(field '.summary.goal' "$PLAN_FILE")
    SCOPE=$(field '.summary.scope' "$PLAN_FILE")
    STEPS=$(field '.summary.step_count' "$PLAN_FILE")
    FILES=$(field '.summary.planned_files | length' "$PLAN_FILE")
    [ -n "$GOAL" ] && echo "**Goal:** $GOAL"
    echo "**Scope:** $SCOPE | **Steps:** $STEPS | **Files:** $FILES"
    echo ""
  fi

  # Review
  REVIEW_FILE=$(find_latest review)
  if [ -n "$REVIEW_FILE" ]; then
    echo "## /review"
    echo ""
    BLOCKING=$(field '.summary.blocking' "$REVIEW_FILE")
    SHOULD=$(field '.summary.should_fix' "$REVIEW_FILE")
    NITS=$(field '.summary.nitpicks' "$REVIEW_FILE")
    POSITIVE=$(field '.summary.positive' "$REVIEW_FILE")
    MODE=$(field '.mode' "$REVIEW_FILE")
    echo "**Mode:** $MODE"
    echo "**Findings:** blocking=$BLOCKING, should_fix=$SHOULD, nitpicks=$NITS, positive=$POSITIVE"

    # Scope drift
    DRIFT=$(field '.scope_drift.status' "$REVIEW_FILE")
    [ -n "$DRIFT" ] && echo "**Scope drift:** $DRIFT"

    # Conflicts
    CONFLICTS=$(field '.conflicts | length' "$REVIEW_FILE")
    [ "$CONFLICTS" != "0" ] && [ -n "$CONFLICTS" ] && echo "**Conflicts resolved:** $CONFLICTS (see [[reference/conflict-precedents]])"
    echo ""
  fi

  # QA
  QA_FILE=$(find_latest qa)
  if [ -n "$QA_FILE" ]; then
    echo "## /qa"
    echo ""
    STATUS=$(field '.summary.status' "$QA_FILE")
    TESTS_RUN=$(field '.summary.tests_run' "$QA_FILE")
    PASSED=$(field '.summary.tests_passed' "$QA_FILE")
    FAILED=$(field '.summary.tests_failed' "$QA_FILE")
    BUGS=$(field '.summary.bugs_found' "$QA_FILE")
    FIXED=$(field '.summary.bugs_fixed' "$QA_FILE")
    WTF=$(field '.summary.wtf_likelihood' "$QA_FILE")
    echo "**Status:** $STATUS | **Tests:** $TESTS_RUN ($PASSED passed, $FAILED failed)"
    echo "**Bugs:** $BUGS found, $FIXED fixed | **WTF:** ${WTF}%"
    echo ""
  fi

  # Security
  SEC_FILE=$(find_latest security)
  if [ -n "$SEC_FILE" ]; then
    echo "## /security"
    echo ""
    CRIT=$(field '.summary.critical' "$SEC_FILE")
    HIGH=$(field '.summary.high' "$SEC_FILE")
    MED=$(field '.summary.medium' "$SEC_FILE")
    LOW=$(field '.summary.low' "$SEC_FILE")
    TOTAL=$(field '.summary.total_findings' "$SEC_FILE")
    MODE=$(field '.mode' "$SEC_FILE")

    # Calculate grade
    GRADE="A"
    [ "$CRIT" -gt 2 ] 2>/dev/null && GRADE="F"
    [ "$CRIT" -gt 0 ] 2>/dev/null && [ "$CRIT" -le 2 ] 2>/dev/null && GRADE="D"
    [ "$HIGH" -gt 2 ] 2>/dev/null && [ "$CRIT" -eq 0 ] 2>/dev/null && GRADE="C"
    [ "$HIGH" -gt 0 ] 2>/dev/null && [ "$HIGH" -le 2 ] 2>/dev/null && [ "$CRIT" -eq 0 ] 2>/dev/null && GRADE="B"

    echo "**Mode:** $MODE | **Score:** $GRADE"
    echo "**Findings:** CRITICAL=$CRIT HIGH=$HIGH MEDIUM=$MED LOW=$LOW (total: $TOTAL)"
    echo ""
  fi

  # Ship
  SHIP_FILE=$(find_latest ship)
  if [ -n "$SHIP_FILE" ]; then
    echo "## /ship"
    echo ""
    PR=$(field '.summary.pr_number' "$SHIP_FILE")
    STATUS=$(field '.summary.status' "$SHIP_FILE")
    CI=$(field '.summary.ci_passed' "$SHIP_FILE")
    [ -n "$PR" ] && echo "**PR:** #$PR | **Status:** $STATUS | **CI:** $CI"
    echo ""
  fi

  # Lessons section (empty, for manual fill)
  echo "## Lessons"
  echo ""
  echo "<!-- What surprised you in this sprint? What would you do differently? -->"
  echo ""

  # Links
  echo "---"
  echo ""
  echo "Related: [[learnings/from-building]] | [[reference/conflict-precedents]]"

} > "$JOURNAL_FILE"

echo "$JOURNAL_FILE"
