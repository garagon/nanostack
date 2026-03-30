#!/usr/bin/env bash
# find-solution.sh — Search solutions by keyword, tag, or file path
# Usage: find-solution.sh <query> [--type bug|pattern|decision] [--tag tag] [--file path]
#
# Searches YAML frontmatter (title, tags, files) and body text.
# Returns paths to matching solution documents, most recent first.
# Exit 1 if no matches found.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

SOLUTIONS_DIR="$NANOSTACK_STORE/know-how/solutions"

# Parse arguments
QUERY=""
FILTER_TYPE=""
FILTER_TAG=""
FILTER_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --type) FILTER_TYPE="$2"; shift 2 ;;
    --tag) FILTER_TAG="$2"; shift 2 ;;
    --file) FILTER_FILE="$2"; shift 2 ;;
    *) QUERY="${QUERY:+$QUERY }$1"; shift ;;
  esac
done

[ -z "$QUERY" ] && [ -z "$FILTER_TYPE" ] && [ -z "$FILTER_TAG" ] && [ -z "$FILTER_FILE" ] && {
  echo "Usage: find-solution.sh <query> [--type bug|pattern|decision] [--tag tag] [--file path]" >&2
  exit 1
}

[ ! -d "$SOLUTIONS_DIR" ] && exit 1

# Find all solution files
FILES=$(find "$SOLUTIONS_DIR" -name "*.md" -type f 2>/dev/null | sort -r)
[ -z "$FILES" ] && exit 1

MATCHES=""

while IFS= read -r filepath; do
  [ -z "$filepath" ] && continue
  MATCH=true

  # Filter by type (directory name)
  if [ -n "$FILTER_TYPE" ]; then
    DIR_TYPE=$(basename "$(dirname "$filepath")")
    [ "$DIR_TYPE" != "$FILTER_TYPE" ] && MATCH=false
  fi

  # Filter by tag (search frontmatter)
  if [ -n "$FILTER_TAG" ] && [ "$MATCH" = true ]; then
    if ! grep -qi "tags:.*$FILTER_TAG" "$filepath" 2>/dev/null; then
      # Also check array format
      if ! grep -qi "\"$FILTER_TAG\"" "$filepath" 2>/dev/null; then
        MATCH=false
      fi
    fi
  fi

  # Filter by file path (search frontmatter files field)
  if [ -n "$FILTER_FILE" ] && [ "$MATCH" = true ]; then
    if ! grep -qi "$FILTER_FILE" "$filepath" 2>/dev/null; then
      MATCH=false
    fi
  fi

  # Search query in title, tags, and body
  if [ -n "$QUERY" ] && [ "$MATCH" = true ]; then
    FOUND=false
    # Search each query word (all must match)
    ALL_WORDS_MATCH=true
    for word in $QUERY; do
      if ! grep -qi "$word" "$filepath" 2>/dev/null; then
        ALL_WORDS_MATCH=false
        break
      fi
    done
    [ "$ALL_WORDS_MATCH" = true ] && FOUND=true
    [ "$FOUND" = false ] && MATCH=false
  fi

  if [ "$MATCH" = true ]; then
    MATCHES="${MATCHES:+$MATCHES
}$filepath"
  fi
done <<< "$FILES"

if [ -n "$MATCHES" ]; then
  echo "$MATCHES"
  exit 0
else
  exit 1
fi
