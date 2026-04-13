#!/usr/bin/env bash
# gather-subject.sh — Deterministic source gathering for diarization
# Expands a subject (file, directory, or concept) to file paths,
# then collects git history, solutions, and artifacts about it.
#
# Usage: gather-subject.sh <subject>
#   subject: a file path, directory, module name, or keyword
#
# Output: JSON with all sources the model needs to synthesize a diarization.
# The model does the judgment (synthesis). This script does the gathering (deterministic).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

SUBJECT="${1:?Usage: gather-subject.sh <subject>}"
MAX_LOG_ENTRIES=100

# ─── 1. Expand subject to file paths ───────────────────────

FILES=""
if [ -f "$SUBJECT" ]; then
  # Exact file
  FILES="$SUBJECT"
elif [ -d "$SUBJECT" ]; then
  # Directory — list all code files (skip node_modules, .git, etc.)
  FILES=$(find "$SUBJECT" -type f \
    -not -path '*/node_modules/*' \
    -not -path '*/.git/*' \
    -not -path '*/dist/*' \
    -not -path '*/.nanostack/*' \
    -not -name '*.lock' \
    -not -name '*.min.*' \
    2>/dev/null | head -50)
else
  # Keyword — find files containing the subject name (fixed string, no regex)
  FILES=$(git ls-files 2>/dev/null | grep -Fi "$SUBJECT" | head -30)
  if [ -z "$FILES" ]; then
    # Try broader: grep for the keyword in file contents
    FILES=$(grep -rlFi "$SUBJECT" --include='*.ts' --include='*.js' --include='*.py' --include='*.go' --include='*.rs' --include='*.md' . 2>/dev/null | head -20)
  fi
fi

[ -z "$FILES" ] && { echo "{\"error\": \"no files found for subject: $SUBJECT\"}"; exit 1; }

# Convert to JSON array
FILES_JSON=$(echo "$FILES" | jq -R . | jq -s '.')

# ─── 2. Git history ────────────────────────────────────────

GIT_LOG="[]"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Collect git log for all matched files (cap at MAX_LOG_ENTRIES)
  LOG_OUTPUT=""
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ -f "$file" ] || continue
    FLOG=$(git log --oneline --follow -n 20 -- "$file" 2>/dev/null || true)
    if [ -n "$FLOG" ]; then
      LOG_OUTPUT="$LOG_OUTPUT
$FLOG"
    fi
  done <<< "$FILES"

  if [ -n "$LOG_OUTPUT" ]; then
    # Deduplicate and cap
    GIT_LOG=$(echo "$LOG_OUTPUT" | sort -u | head -"$MAX_LOG_ENTRIES" | jq -R . | jq -s '.')
  fi

  # Ownership: who contributed most
  OWNERSHIP="[]"
  FIRST_FILE=$(echo "$FILES" | head -5)
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    [ -f "$file" ] || continue
    git log --format='%an' -- "$file" 2>/dev/null || true
  done <<< "$FIRST_FILE" | sort | uniq -c | sort -rn | head -5 > /tmp/nanostack_gather_own_$$ 2>/dev/null || true

  if [ -s /tmp/nanostack_gather_own_$$ ]; then
    OWNERSHIP=$(awk '{printf "{\"author\":\"%s\",\"commits\":%d},", substr($0, index($0,$2)), $1}' /tmp/nanostack_gather_own_$$ | sed 's/,$//' | sed 's/^/[/;s/$/]/')
  fi
  rm -f /tmp/nanostack_gather_own_$$
fi

# ─── 3. Related solutions ──────────────────────────────────

SOLUTIONS="[]"
# Search by the first few file paths
SEARCH_FILES=$(echo "$FILES" | head -3)
SOL_OUTPUT=""
while IFS= read -r file; do
  [ -z "$file" ] && continue
  RESULT=$("$SCRIPT_DIR/find-solution.sh" --file "$file" --full 2>/dev/null) || true
  [ -n "$RESULT" ] && SOL_OUTPUT="$SOL_OUTPUT
$RESULT"
done <<< "$SEARCH_FILES"

# Also search by subject keyword
KEYWORD_RESULT=$("$SCRIPT_DIR/find-solution.sh" "$SUBJECT" --full 2>/dev/null) || true
[ -n "$KEYWORD_RESULT" ] && SOL_OUTPUT="$SOL_OUTPUT
$KEYWORD_RESULT"

if [ -n "$SOL_OUTPUT" ]; then
  SOLUTIONS=$(echo "$SOL_OUTPUT" | grep '\.md$' | sort -u | head -10 | jq -R . | jq -s '.')
fi

# ─── 4. Related artifacts ──────────────────────────────────

ARTIFACTS="{}"
ARTIFACT_JSON="{"
AFIRST=true
for phase in think plan review security qa ship compound; do
  RESULT=$("$SCRIPT_DIR/find-artifact.sh" "$phase" 30 2>/dev/null) || continue
  [ -z "$RESULT" ] && continue

  # Check if artifact mentions any of our files
  MENTIONS=false
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    BASENAME=$(basename "$file")
    if grep -q "$BASENAME" "$RESULT" 2>/dev/null; then
      MENTIONS=true
      break
    fi
  done <<< "$(echo "$FILES" | head -5)"

  if [ "$MENTIONS" = true ]; then
    $AFIRST || ARTIFACT_JSON="$ARTIFACT_JSON,"
    ARTIFACT_JSON="$ARTIFACT_JSON\"$phase\":\"$RESULT\""
    AFIRST=false
  fi
done
ARTIFACTS="$ARTIFACT_JSON}"

# ─── 5. Existing diarization ───────────────────────────────

EXISTING_DIARIZATION="null"
DIARIZE_DIR="$NANOSTACK_STORE/know-how/diarizations"
if [ -d "$DIARIZE_DIR" ]; then
  # Check for existing diarization by subject overlap
  for dfile in "$DIARIZE_DIR"/*.md; do
    [ -f "$dfile" ] || continue
    D_SUBJECT=$(sed -n '/^---$/,/^---$/p' "$dfile" | grep -i '^subject:' | head -1 | sed 's/^subject: *//i')
    if echo "$SUBJECT" | grep -qi "$D_SUBJECT" 2>/dev/null || echo "$D_SUBJECT" | grep -qi "$SUBJECT" 2>/dev/null; then
      EXISTING_DIARIZATION="\"$dfile\""
      break
    fi
  done
fi

# ─── Output ─────────────────────────────────────────────────

jq -n \
  --arg subject "$SUBJECT" \
  --argjson files "$FILES_JSON" \
  --argjson git_log "$GIT_LOG" \
  --argjson ownership "${OWNERSHIP:-[]}" \
  --argjson solutions "$SOLUTIONS" \
  --argjson artifacts "$ARTIFACTS" \
  --argjson existing "$EXISTING_DIARIZATION" \
  '{
    subject: $subject,
    files: $files,
    file_count: ($files | length),
    git_history: $git_log,
    ownership: $ownership,
    solutions: $solutions,
    related_artifacts: $artifacts,
    existing_diarization: $existing
  }'
