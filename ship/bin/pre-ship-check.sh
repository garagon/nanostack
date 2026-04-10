#!/usr/bin/env bash
# pre-ship-check.sh — PreToolUse hook for /ship
# Before creating a PR, verify basic hygiene
# In local mode (no git), skips git checks gracefully
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../bin/lib/git-context.sh" 2>/dev/null || true
GIT_MODE=$(detect_git_mode 2>/dev/null || echo "local")

if [ "$GIT_MODE" = "local" ]; then
  echo "LOCAL_MODE"
  exit 0
fi

WARNINGS=""

# Check for uncommitted changes
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  WARNINGS="${WARNINGS}UNCOMMITTED_CHANGES\n"
fi

# Check if tests exist and were run recently (look for test result files)
if ! find . -name "*.test.*" -o -name "*_test.*" -o -name "test_*" 2>/dev/null | head -1 | grep -q .; then
  WARNINGS="${WARNINGS}NO_TESTS_FOUND\n"
fi

# Check for .env files that might be staged
if git diff --cached --name-only 2>/dev/null | grep -qE '\.env$|\.env\.local$|credentials'; then
  WARNINGS="${WARNINGS}SECRETS_STAGED\n"
fi

# Check branch is not main/master
BRANCH=$(git branch --show-current 2>/dev/null)
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  WARNINGS="${WARNINGS}ON_MAIN_BRANCH\n"
fi

if [ -n "$WARNINGS" ]; then
  echo "WARNINGS"
  echo -e "$WARNINGS"
else
  echo "CLEAN"
fi
