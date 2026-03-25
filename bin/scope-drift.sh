#!/usr/bin/env bash
# scope-drift.sh — Compare planned files from a plan artifact vs actual git changes
# Usage: scope-drift.sh [plan-artifact-path]
# If no path given, finds the most recent plan for this project (last 48h)
# Output: JSON with drift status, out-of-scope files, missing files
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -n "$1" ]; then
  PLAN="$1"
else
  PLAN=$("$SCRIPT_DIR/find-artifact.sh" plan 2 2>/dev/null) || {
    echo '{"status":"no_plan","message":"No recent plan artifact found"}'
    exit 0
  }
fi

# Extract planned files
PLANNED=$(jq -r '.summary.planned_files[]' "$PLAN" 2>/dev/null | sort)
if [ -z "$PLANNED" ]; then
  echo '{"status":"no_plan","message":"Plan artifact has no planned_files"}'
  exit 0
fi

# Get actual changed files (staged + unstaged, or last commit)
ACTUAL=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || git diff --name-only --cached 2>/dev/null || git diff --name-only 2>/dev/null)
ACTUAL=$(echo "$ACTUAL" | sort)

# Exempt config/lock files from drift detection
EXEMPT="\.gitignore|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|go\.sum|\.DS_Store"
ACTUAL_FILTERED=$(echo "$ACTUAL" | grep -vE "$EXEMPT" || true)

# Compute drift
OUT_OF_SCOPE=$(comm -23 <(echo "$ACTUAL_FILTERED") <(echo "$PLANNED") | grep -v '^$' || true)
MISSING=$(comm -23 <(echo "$PLANNED") <(echo "$ACTUAL_FILTERED") | grep -v '^$' || true)

if [ -z "$OUT_OF_SCOPE" ] && [ -z "$MISSING" ]; then
  STATUS="clean"
elif [ -n "$MISSING" ] && [ -z "$OUT_OF_SCOPE" ]; then
  STATUS="requirements_missing"
else
  STATUS="drift_detected"
fi

# Output JSON
jq -n \
  --arg status "$STATUS" \
  --arg plan "$PLAN" \
  --argjson planned "$(echo "$PLANNED" | jq -R . | jq -s .)" \
  --argjson actual "$(echo "$ACTUAL_FILTERED" | jq -R . | jq -s .)" \
  --argjson out_of_scope "$(echo "$OUT_OF_SCOPE" | jq -R . | jq -s .)" \
  --argjson missing "$(echo "$MISSING" | jq -R . | jq -s .)" \
  '{status: $status, plan: $plan, planned_files: $planned, actual_files: $actual, out_of_scope_files: $out_of_scope, missing_files: $missing}'
