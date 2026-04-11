#!/usr/bin/env bash
# find-solution.sh — Search solutions by keyword, tag, or file path
# Usage: find-solution.sh <query> [--type bug|pattern|decision] [--tag tag] [--file path] [--full]
#
# Default output: ranked summaries with title, severity, tags, files.
# The agent reads summaries first, then loads only the relevant documents.
# --full: return bare file paths (backward compatible, for scripts).
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
FULL_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --type) FILTER_TYPE="$2"; shift 2 ;;
    --tag) FILTER_TAG="$2"; shift 2 ;;
    --file) FILTER_FILE="$2"; shift 2 ;;
    --full) FULL_MODE=true; shift ;;
    *) QUERY="${QUERY:+$QUERY }$1"; shift ;;
  esac
done

[ -z "$QUERY" ] && [ -z "$FILTER_TYPE" ] && [ -z "$FILTER_TAG" ] && [ -z "$FILTER_FILE" ] && {
  echo "Usage: find-solution.sh <query> [--type bug|pattern|decision] [--tag tag] [--file path] [--full]" >&2
  exit 1
}

[ ! -d "$SOLUTIONS_DIR" ] && exit 1

# Find all solution files
FILES=$(find "$SOLUTIONS_DIR" -name "*.md" -type f 2>/dev/null | sort -r)
[ -z "$FILES" ] && exit 1

# Extract frontmatter field from a file
get_field() {
  local file="$1" field="$2"
  sed -n '/^---$/,/^---$/p' "$file" | grep -i "^${field}:" | head -1 | sed "s/^${field}: *//i"
}

# Score severity: critical=4, high=3, medium=2, low=1
severity_score() {
  case "$1" in
    critical) echo 4 ;; high) echo 3 ;; medium) echo 2 ;; low) echo 1 ;; *) echo 2 ;;
  esac
}

# Collect matches with scores
RESULTS=""

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
    ALL_WORDS_MATCH=true
    for word in $QUERY; do
      if ! grep -qi "$word" "$filepath" 2>/dev/null; then
        ALL_WORDS_MATCH=false
        break
      fi
    done
    [ "$ALL_WORDS_MATCH" = false ] && MATCH=false
  fi

  if [ "$MATCH" = true ]; then
    # Extract frontmatter for scoring and display
    TITLE=$(get_field "$filepath" "title")
    SEVERITY=$(get_field "$filepath" "severity")
    DATE=$(get_field "$filepath" "date")
    TAGS=$(get_field "$filepath" "tags")
    FM_FILES=$(get_field "$filepath" "files")
    TYPE_DIR=$(basename "$(dirname "$filepath")")

    # Score: severity + tag match density + recency
    SCORE=$(severity_score "$SEVERITY")

    # Tag density: count query words that appear in tags
    if [ -n "$QUERY" ]; then
      for word in $QUERY; do
        if echo "$TAGS" | grep -qi "$word" 2>/dev/null; then
          SCORE=$((SCORE + 1))
        fi
      done
    fi

    # Recency: +1 if within last 30 days
    if [ -n "$DATE" ]; then
      if command -v gdate >/dev/null 2>&1; then
        DATE_CMD="gdate"
      else
        DATE_CMD="date"
      fi
      DOC_EPOCH=$($DATE_CMD -d "$DATE" +%s 2>/dev/null || echo 0)
      NOW_EPOCH=$($DATE_CMD +%s 2>/dev/null || echo 0)
      if [ "$DOC_EPOCH" -gt 0 ] && [ $((NOW_EPOCH - DOC_EPOCH)) -lt 2592000 ]; then
        SCORE=$((SCORE + 1))
      fi
    fi

    # Validation bonus: +2 if validated, +1 per applied_count (cap 5)
    VALIDATED=$(get_field "$filepath" "validated")
    APPLIED_COUNT=$(get_field "$filepath" "applied_count")
    LAST_VALIDATED=$(get_field "$filepath" "last_validated")

    if [ "$VALIDATED" = "true" ]; then
      SCORE=$((SCORE + 2))
    fi

    if [ -n "$APPLIED_COUNT" ] && [ "$APPLIED_COUNT" != "0" ]; then
      BONUS=$APPLIED_COUNT
      [ "$BONUS" -gt 5 ] && BONUS=5
      SCORE=$((SCORE + BONUS))
    fi

    # Unvalidated penalty: -1 if >60 days old and never validated
    if [ "$VALIDATED" != "true" ] && [ -n "$DATE" ]; then
      DOC_EPOCH_V=$($DATE_CMD -d "$DATE" +%s 2>/dev/null || echo 0)
      NOW_EPOCH_V=$($DATE_CMD +%s 2>/dev/null || echo 0)
      if [ "$DOC_EPOCH_V" -gt 0 ] && [ $((NOW_EPOCH_V - DOC_EPOCH_V)) -gt 5184000 ]; then
        SCORE=$((SCORE - 1))
      fi
    fi

    # Staleness: penalize if referenced files no longer exist
    if [ -n "$FM_FILES" ] && [ "$FM_FILES" != "[]" ]; then
      STALE_FILES=0
      TOTAL_FILES=0
      for ref_file in $(echo "$FM_FILES" | tr -d '[]"' | tr ',' ' '); do
        ref_file=$(echo "$ref_file" | tr -d ' ' | sed 's/:.*$//')  # strip line numbers
        [ -z "$ref_file" ] && continue
        TOTAL_FILES=$((TOTAL_FILES + 1))
        [ ! -f "$ref_file" ] && STALE_FILES=$((STALE_FILES + 1))
      done
      if [ "$TOTAL_FILES" -gt 0 ] && [ "$STALE_FILES" -eq "$TOTAL_FILES" ]; then
        SCORE=$((SCORE - 3))  # all files gone: heavy penalty
      elif [ "$STALE_FILES" -gt 0 ]; then
        SCORE=$((SCORE - 1))  # some files gone: light penalty
      fi
    fi

    RESULTS="${RESULTS}${SCORE}|${filepath}|${TITLE}|${SEVERITY}|${DATE}|${TAGS}|${FM_FILES}|${TYPE_DIR}
"
  fi
done <<< "$FILES"

[ -z "$RESULTS" ] && exit 1

# Sort by score descending
SORTED=$(echo "$RESULTS" | sort -t'|' -k1 -rn)

# Output
if [ "$FULL_MODE" = true ]; then
  echo "$SORTED" | while IFS='|' read -r score path rest; do
    echo "$path"
  done
  exit 0
fi

# Summary output
COUNT=$(echo "$SORTED" | grep -c '|')
echo "$COUNT solutions found${QUERY:+ for \"$QUERY\"}"
echo ""

IDX=1
echo "$SORTED" | while IFS='|' read -r score path title severity date tags fm_files type_dir; do
  [ -z "$path" ] && continue
  # Clean tags: remove brackets and quotes
  clean_tags=$(echo "$tags" | tr -d '[]"' | sed 's/,  */, /g')
  # Clean files: remove brackets and quotes
  clean_files=$(echo "$fm_files" | tr -d '[]"' | sed 's/,  */, /g')

  echo "  [$IDX] $type_dir/$(basename "$path") ($severity, $date)"
  [ -n "$title" ] && echo "      $title"
  [ -n "$clean_tags" ] && [ "$clean_tags" != "[]" ] && echo "      tags: $clean_tags"
  [ -n "$clean_files" ] && [ "$clean_files" != "[]" ] && echo "      files: $clean_files"
  echo ""
  IDX=$((IDX + 1))
done
