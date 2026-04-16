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
[ -f "$SCRIPT_DIR/lib/preflight.sh" ] && { source "$SCRIPT_DIR/lib/preflight.sh"; nanostack_require jq; }
[ -f "$SCRIPT_DIR/lib/cache.sh" ] && source "$SCRIPT_DIR/lib/cache.sh"
[ -f "$SCRIPT_DIR/lib/solutions-index.sh" ] && source "$SCRIPT_DIR/lib/solutions-index.sh"

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

# Load the solutions index once (cached at .nanostack/.cache/solutions-index.json,
# regenerated when the solutions dir mtime changes). Replaces N file-by-file
# sed/grep frontmatter parses with a single jq scan up front.
INDEX=""
if declare -F nano_solutions_index >/dev/null 2>&1; then
  INDEX=$(nano_solutions_index "$SOLUTIONS_DIR" 2>/dev/null || echo "[]")
fi

# Pre-compute a tab-separated stream of every solution and all its frontmatter
# fields with a single jq call. The main loop iterates this stream directly,
# so no get_field calls are needed and the per-file sed+grep parse cost goes
# from N x fields to zero (one jq up front).
INDEX_TSV=""
USE_INDEX_TSV=false
if [ -n "$INDEX" ] && [ "$INDEX" != "[]" ]; then
  INDEX_TSV=$(printf '%s' "$INDEX" | jq -r '
    def fmt: if type == "array" then "[" + (map(tostring) | join(",")) + "]"
             elif . == null then "" else tostring end;
    .[] | [.path, (.title|fmt), (.severity|fmt), (.date|fmt), (.tags|fmt),
           (.files|fmt), (.validated|fmt), (.applied_count|fmt),
           (.confidence|fmt), (.last_validated|fmt)] | @tsv' 2>/dev/null) || INDEX_TSV=""
  [ -n "$INDEX_TSV" ] && USE_INDEX_TSV=true
fi

# Legacy get_field — only called on the slow path when the index is unavailable
# (no lib/solutions-index.sh, or index build failed). Kept verbatim so existing
# behaviour is preserved when the cache cannot be loaded.
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

# Iterate either the TSV stream (fast: all fields already extracted by jq)
# or the legacy file list (slow: per-file get_field). The matching logic is
# identical in both branches; only the field source changes.
process_one() {
  # Inputs: filepath title severity date tags fm_files validated applied_count
  #         confidence last_validated   (last six may be empty in legacy mode)
  local filepath="$1" title="$2" severity="$3" date="$4" tags="$5" fm_files="$6"
  local validated="$7" applied_count="$8" confidence="$9" last_validated="${10}"
  local TYPE_DIR
  TYPE_DIR=$(basename "$(dirname "$filepath")")

  local MATCH=true

  # Filter by type (directory name)
  if [ -n "$FILTER_TYPE" ] && [ "$TYPE_DIR" != "$FILTER_TYPE" ]; then
    MATCH=false
  fi

  # Filter by tag — prefer the in-memory tags string when present,
  # fall back to a file scan when the index is unavailable.
  if [ -n "$FILTER_TAG" ] && [ "$MATCH" = true ]; then
    if [ -n "$tags" ]; then
      echo "$tags" | grep -qi "$FILTER_TAG" 2>/dev/null || MATCH=false
    else
      if ! grep -qi "tags:.*$FILTER_TAG" "$filepath" 2>/dev/null; then
        grep -qi "\"$FILTER_TAG\"" "$filepath" 2>/dev/null || MATCH=false
      fi
    fi
  fi

  # Filter by file path — index files field first, file scan as fallback.
  if [ -n "$FILTER_FILE" ] && [ "$MATCH" = true ]; then
    if [ -n "$fm_files" ]; then
      echo "$fm_files" | grep -qi "$FILTER_FILE" 2>/dev/null || MATCH=false
    else
      grep -qi "$FILTER_FILE" "$filepath" 2>/dev/null || MATCH=false
    fi
  fi

  # Query may match title/tags (cheap) or body (file scan). Try cheap fields
  # first per word; only open the file when the field check misses.
  if [ -n "$QUERY" ] && [ "$MATCH" = true ]; then
    local ALL_WORDS_MATCH=true
    for word in $QUERY; do
      local word_match=false
      if [ -n "$title" ] && echo "$title" | grep -qi "$word" 2>/dev/null; then
        word_match=true
      elif [ -n "$tags" ] && echo "$tags" | grep -qi "$word" 2>/dev/null; then
        word_match=true
      elif grep -qi "$word" "$filepath" 2>/dev/null; then
        word_match=true
      fi
      if [ "$word_match" = false ]; then
        ALL_WORDS_MATCH=false
        break
      fi
    done
    [ "$ALL_WORDS_MATCH" = false ] && MATCH=false
  fi

  [ "$MATCH" = true ] || return 0

  # Fields not in the TSV (legacy path) need to be fetched lazily.
  if [ -z "$title" ] && [ -z "$severity" ]; then
    title=$(get_field "$filepath" "title")
    severity=$(get_field "$filepath" "severity")
    date=$(get_field "$filepath" "date")
    tags=$(get_field "$filepath" "tags")
    fm_files=$(get_field "$filepath" "files")
    validated=$(get_field "$filepath" "validated")
    applied_count=$(get_field "$filepath" "applied_count")
    confidence=$(get_field "$filepath" "confidence")
    last_validated=$(get_field "$filepath" "last_validated")
  fi

  TITLE="$title"; SEVERITY="$severity"; DATE="$date"; TAGS="$tags"
  FM_FILES="$fm_files"; VALIDATED="$validated"; APPLIED_COUNT="$applied_count"
  CONFIDENCE="$confidence"; LAST_VALIDATED="$last_validated"

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
    if [ "$VALIDATED" = "true" ]; then
      SCORE=$((SCORE + 2))
    fi

    if [ -n "$APPLIED_COUNT" ] && [ "$APPLIED_COUNT" != "0" ]; then
      BONUS=$APPLIED_COUNT
      [ "$BONUS" -gt 5 ] && BONUS=5
      SCORE=$((SCORE + BONUS))
    fi

    # Confidence bonus: scale by confidence (1-10, default 5)
    if [ -n "$CONFIDENCE" ] && [ "$CONFIDENCE" != "0" ]; then
      # Confidence 5 = neutral (+0), 8 = +3, 10 = +5, 2 = -3
      CONF_BONUS=$((CONFIDENCE - 5))
      SCORE=$((SCORE + CONF_BONUS))
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
}

# Drive process_one with either the pre-extracted TSV (fast) or the legacy
# file list (one process_one call per path; get_field re-fetches inside).
if [ "$USE_INDEX_TSV" = true ]; then
  while IFS=$'\t' read -r p title severity date tags fm_files validated applied_count confidence last_validated; do
    [ -z "$p" ] && continue
    process_one "$p" "$title" "$severity" "$date" "$tags" "$fm_files" "$validated" "$applied_count" "$confidence" "$last_validated"
  done <<< "$INDEX_TSV"
else
  while IFS= read -r filepath; do
    [ -z "$filepath" ] && continue
    process_one "$filepath" "" "" "" "" "" "" "" "" ""
  done <<< "$FILES"
fi

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
