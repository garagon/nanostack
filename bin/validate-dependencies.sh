#!/usr/bin/env bash
# validate-dependencies.sh — Check that upstream phase artifacts exist before starting a phase
# Usage: validate-dependencies.sh <phase>
# Reads depends_on from the skill's SKILL.md frontmatter and verifies each dependency
# has a completed artifact for the current project.
# Exit 0 = all deps met. Exit 1 = missing dependencies (lists them).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

PHASE="${1:?Usage: validate-dependencies.sh <phase>}"

# Map phase name to skill directory
case "$PHASE" in
  plan) SKILL_DIR="$NANOSTACK_ROOT/plan" ;;
  build) echo "OK"; exit 0 ;; # build is implicit, no SKILL.md
  *) SKILL_DIR="$NANOSTACK_ROOT/$PHASE" ;;
esac

SKILL_MD="$SKILL_DIR/SKILL.md"

if [ ! -f "$SKILL_MD" ]; then
  echo "OK"
  exit 0
fi

# Extract depends_on from YAML frontmatter
# Format: depends_on: [think, plan] or depends_on: []
DEPS_RAW=$(sed -n '/^---$/,/^---$/p' "$SKILL_MD" | grep '^depends_on:' | head -1 | sed 's/^depends_on: *//')

# Parse YAML array: [think, plan] → "think plan"
DEPS=$(echo "$DEPS_RAW" | tr -d '[]' | tr ',' ' ' | tr -d ' ')

# Handle empty deps
if [ -z "$DEPS" ] || [ "$DEPS" = "[]" ]; then
  echo "OK"
  exit 0
fi

# Re-parse with spaces preserved between items
DEPS=$(echo "$DEPS_RAW" | tr -d '[]' | sed 's/,/ /g' | tr -s ' ')

MISSING=""
FOUND=0

for dep in $DEPS; do
  dep=$(echo "$dep" | tr -d ' ')
  [ -z "$dep" ] && continue

  if "$SCRIPT_DIR/find-artifact.sh" "$dep" 2 >/dev/null 2>&1; then
    FOUND=$((FOUND + 1))
  else
    MISSING="${MISSING:+$MISSING, }$dep"
  fi
done

if [ -n "$MISSING" ]; then
  echo "MISSING: $MISSING" >&2
  exit 1
fi

echo "OK"
