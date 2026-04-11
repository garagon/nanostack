#!/usr/bin/env bash
# save-solution.sh — Save a structured solution to know-how/solutions/
# Usage: save-solution.sh <type> <title> [tags]
#   type: bug, pattern, or decision
#   title: short description (used as filename)
#   tags: comma-separated (optional)
#
# Creates the file with YAML frontmatter. The agent fills in the body.
# Returns: path to the created file
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

TYPE="${1:?Usage: save-solution.sh <type> <title> [tags]}"
TITLE="${2:?Missing title}"
TAGS="${3:-}"

# Validate type
case "$TYPE" in
  bug|pattern|decision) ;;
  *) echo "error: type must be bug, pattern, or decision (got '$TYPE')" >&2; exit 1 ;;
esac

# Sanitize title for filename: lowercase, spaces to hyphens, strip special chars
SAFE_TITLE=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | head -c 80)
[ -z "$SAFE_TITLE" ] && { echo "error: title produced empty filename" >&2; exit 1; }

DATE=$(date +"%Y-%m-%d")
PROJECT=$(basename "$(pwd)")

# Create directory
SOLUTIONS_DIR="$NANOSTACK_STORE/know-how/solutions/$TYPE"
mkdir -p "$SOLUTIONS_DIR"

# Check for existing file with same name (prevent overwrite)
FILEPATH="$SOLUTIONS_DIR/$SAFE_TITLE.md"
if [ -f "$FILEPATH" ]; then
  echo "exists:$FILEPATH"
  exit 0
fi

# Format tags
TAGS_YAML="[]"
if [ -n "$TAGS" ]; then
  TAGS_YAML=$(echo "$TAGS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s '.')
fi

# Write frontmatter
cat > "$FILEPATH" << FRONTMATTER
---
type: $TYPE
title: $TITLE
date: $DATE
project: $PROJECT
files: []
tags: $TAGS_YAML
severity: medium
validated: false
last_validated: null
applied_count: 0
---

FRONTMATTER

# Add body template based on type
case "$TYPE" in
  bug)
    cat >> "$FILEPATH" << 'TEMPLATE'
## Problem


## Symptoms


## What didn't work


## Solution


## Why this works


## Prevention


## History

TEMPLATE
    ;;
  pattern)
    cat >> "$FILEPATH" << 'TEMPLATE'
## Context


## Pattern


## When to apply


## Example


## When NOT to apply


## History

TEMPLATE
    ;;
  decision)
    cat >> "$FILEPATH" << 'TEMPLATE'
## Context


## Decision


## Rationale


## Alternatives considered


## Consequences


## History

TEMPLATE
    ;;
esac

echo "created:$FILEPATH"
