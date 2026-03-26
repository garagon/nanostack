#!/usr/bin/env bash
# quality-check.sh — Verify repo quality before shipping
# Checks: broken links in README, stale references, writing quality
# Exit 0 = clean, output includes any warnings found
set -e

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
WARNINGS=""
ERRORS=""

# ─── Check README links ──────────────────────────────────────
if [ -f "$PROJECT_ROOT/README.md" ]; then
  # Extract relative links from markdown [text](path)
  LINKS=$(grep -oE '\[.*?\]\([^http][^)]+\)' "$PROJECT_ROOT/README.md" | grep -oE '\([^)]+\)' | tr -d '()' || true)
  for link in $LINKS; do
    # Strip anchor fragments
    file_path=$(echo "$link" | sed 's/#.*//')
    [ -z "$file_path" ] && continue
    if [ ! -e "$PROJECT_ROOT/$file_path" ]; then
      ERRORS="${ERRORS}BROKEN_LINK: README.md links to '$link' but file does not exist\n"
    fi
  done
fi

# ─── Check for stale references in changed files ─────────────
CHANGED=$(git diff --cached --name-only 2>/dev/null || git diff --name-only HEAD~1 2>/dev/null || true)
for file in $CHANGED; do
  [ -f "$PROJECT_ROOT/$file" ] || continue
  case "$file" in
    *.md|*.txt)
      # Check for common stale patterns
      if grep -qn '/plan[^-]' "$PROJECT_ROOT/$file" 2>/dev/null; then
        LINE=$(grep -n '/plan[^-]' "$PROJECT_ROOT/$file" | head -1 | cut -d: -f1)
        WARNINGS="${WARNINGS}STALE_REF: $file:$LINE may reference old '/plan' (should be '/nano-plan')\n"
      fi
      ;;
  esac
done

# ─── Check writing quality in public files ────────────────────
PUBLIC_FILES="README.md llms.txt AGENTS.md"
for file in $PUBLIC_FILES; do
  [ -f "$PROJECT_ROOT/$file" ] || continue

  # Em dashes
  if grep -Pn '—|–' "$PROJECT_ROOT/$file" >/dev/null 2>&1; then
    WARNINGS="${WARNINGS}WRITING: $file contains em/en dashes\n"
  fi

  # Oxford commas (rough check: ", and " in a list context)
  if grep -n ', and ' "$PROJECT_ROOT/$file" >/dev/null 2>&1; then
    WARNINGS="${WARNINGS}WRITING: $file may contain Oxford commas\n"
  fi
done

# ─── Check for secrets in diff ────────────────────────────────
DIFF=$(git diff --cached 2>/dev/null || git diff HEAD~1 2>/dev/null || true)
if echo "$DIFF" | grep -qiE 'api_key|secret_key|password|token.*=.*[a-zA-Z0-9]{20}' 2>/dev/null; then
  ERRORS="${ERRORS}SECRETS: Possible secrets detected in diff. Review before pushing.\n"
fi

# ─── Output ───────────────────────────────────────────────────
if [ -n "$ERRORS" ]; then
  echo "QUALITY ERRORS"
  echo -e "$ERRORS"
fi

if [ -n "$WARNINGS" ]; then
  echo "QUALITY WARNINGS"
  echo -e "$WARNINGS"
fi

if [ -z "$ERRORS" ] && [ -z "$WARNINGS" ]; then
  echo "QUALITY CLEAN"
fi
