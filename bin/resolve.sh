#!/usr/bin/env bash
# resolve.sh — Centralized context resolver for nanostack skills
# Replaces per-skill Step 0 boilerplate with a single call.
# Routes context based on phase: loads upstream artifacts, matched solutions,
# conflict precedents, diarizations, and config.
#
# Usage: resolve.sh <phase> [--diff]
#   phase: plan, review, security, qa, ship, compound, feature
#   --diff: match solutions against current git diff file paths
#
# Output: JSON blob with all resolved context paths and summaries.
# Exit 0 on success (even if some lookups return empty).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
[ -f "$SCRIPT_DIR/lib/preflight.sh" ] && { source "$SCRIPT_DIR/lib/preflight.sh"; nanostack_require jq; }

# Portable timeout wrapper: gtimeout (coreutils on macOS) → timeout (Linux) → run as-is.
# Used to bound expensive solution lookups so resolve.sh never hangs the sprint.
_nano_timeout() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

PHASE="${1:?Usage: resolve.sh <phase> [--diff]}"
shift
USE_DIFF=false
for arg in "$@"; do
  [ "$arg" = "--diff" ] && USE_DIFF=true
done

# ─── Routing table ─────────────────────────────────────────
# Which upstream artifacts and solutions each phase needs.
# This is the only place routing logic lives.

UPSTREAM=""  # space-separated "phase:age" pairs (age in days, default 2)
LOAD_SOLUTIONS=false
SOLUTION_STRATEGY=""  # keywords, files, both
LOAD_PRECEDENTS=false
LOAD_DIARIZATIONS=false

case "$PHASE" in
  plan)
    UPSTREAM="think:2"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="keywords"
    ;;
  review)
    UPSTREAM="plan:2"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="files"
    LOAD_PRECEDENTS=true
    LOAD_DIARIZATIONS=true
    ;;
  security)
    UPSTREAM="plan:2 review:30"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="files"
    LOAD_PRECEDENTS=true
    LOAD_DIARIZATIONS=true
    ;;
  qa)
    UPSTREAM="plan:2"
    LOAD_DIARIZATIONS=true
    ;;
  ship)
    UPSTREAM="review:2 security:2 qa:2"
    ;;
  compound)
    UPSTREAM="think:2 plan:2 review:2 security:2 qa:2 ship:2"
    ;;
  feature)
    UPSTREAM="think:30 plan:30 ship:30"
    LOAD_SOLUTIONS=true
    SOLUTION_STRATEGY="keywords"
    ;;
  *)
    echo "{\"error\": \"unknown phase: $PHASE\"}" >&2
    exit 1
    ;;
esac

# ─── 1. Resolve upstream artifacts ─────────────────────────

ARTIFACTS_JSON="{"
FIRST=true
for entry in $UPSTREAM; do
  phase="${entry%%:*}"
  age="${entry#*:}"
  [ "$age" = "$entry" ] && age=2  # default if no colon
  RESULT=$("$SCRIPT_DIR/find-artifact.sh" "$phase" "$age" 2>/dev/null) || RESULT=""
  if [ -n "$RESULT" ]; then
    $FIRST || ARTIFACTS_JSON="$ARTIFACTS_JSON,"
    ARTIFACTS_JSON="$ARTIFACTS_JSON\"$phase\":\"$RESULT\""
    FIRST=false
  fi
done
ARTIFACTS_JSON="$ARTIFACTS_JSON}"

# ─── 2. Resolve solutions ──────────────────────────────────

SOLUTIONS_JSON="[]"
if [ "$LOAD_SOLUTIONS" = true ]; then
  DIFF_FILES=""
  if [ "$USE_DIFF" = true ]; then
    DIFF_FILES=$(git diff --name-only HEAD 2>/dev/null || git diff --name-only 2>/dev/null || echo "")
    # Also include staged files
    STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
    [ -n "$STAGED" ] && DIFF_FILES="$DIFF_FILES
$STAGED"
    DIFF_FILES=$(echo "$DIFF_FILES" | sort -u | head -20)
  fi

  SOLUTION_OUTPUT=""
  case "$SOLUTION_STRATEGY" in
    files)
      if [ -n "$DIFF_FILES" ]; then
        # Search by each changed file path (take top 5 unique dirs)
        DIRS=$(echo "$DIFF_FILES" | xargs -I{} dirname {} 2>/dev/null | sort -u | head -5)
        for dir in $DIRS; do
          # Bound find-solution at 3s; on timeout/failure fall back to a direct
          # listing of files under that dir so the model still sees candidates.
          RESULT=$(_nano_timeout 3 "$SCRIPT_DIR/find-solution.sh" --file "$dir" 2>/dev/null || true)
          if [ -z "$RESULT" ] && [ -d "$NANOSTACK_STORE/know-how/solutions" ]; then
            RESULT=$(find "$NANOSTACK_STORE/know-how/solutions" -name "*.md" -type f -path "*${dir}*" 2>/dev/null | head -5)
          fi
          [ -n "$RESULT" ] && SOLUTION_OUTPUT="$SOLUTION_OUTPUT
$RESULT"
        done
      fi
      ;;
    keywords)
      # Keywords mode: list all available solutions so the model can pick relevant ones.
      # find-solution.sh requires a query, so we list files directly.
      if [ -d "$NANOSTACK_STORE/know-how/solutions" ]; then
        SOLUTION_OUTPUT=$(find "$NANOSTACK_STORE/know-how/solutions" -name "*.md" -type f 2>/dev/null | sort -r | head -10)
      fi
      ;;
  esac

  # Parse solution output into JSON
  if [ -n "$SOLUTION_OUTPUT" ]; then
    # Extract unique file paths from the find-solution.sh output
    # find-solution.sh --full returns bare paths; summary mode has paths in brackets
    PATHS=$(echo "$SOLUTION_OUTPUT" | grep -E '^\s*\[' | sed 's/.*] //' | sed 's/ (.*//' 2>/dev/null || echo "")
    if [ -z "$PATHS" ]; then
      # --full mode output: bare file paths
      PATHS=$(echo "$SOLUTION_OUTPUT" | grep '\.md$' | head -10)
    fi

    if [ -n "$PATHS" ]; then
      SOLUTIONS_JSON=$(echo "$PATHS" | head -10 | sed '/^$/d' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s '.')
    fi
  fi
fi

# ─── 3. Resolve conflict precedents ────────────────────────

PRECEDENTS_JSON="null"
if [ "$LOAD_PRECEDENTS" = true ]; then
  PREC_FILE="$SCRIPT_DIR/../reference/conflict-precedents.md"
  if [ -f "$PREC_FILE" ]; then
    PRECEDENTS_JSON="\"$PREC_FILE\""
  fi
fi

# ─── 4. Resolve diarizations ───────────────────────────────

DIARIZATIONS_JSON="[]"
if [ "$LOAD_DIARIZATIONS" = true ]; then
  DIARIZE_DIR="$NANOSTACK_STORE/know-how/diarizations"
  if [ -d "$DIARIZE_DIR" ] && [ "$USE_DIFF" = true ] && [ -n "$DIFF_FILES" ]; then
    DIAR_RESULTS="["
    DFIRST=true
    for dfile in "$DIARIZE_DIR"/*.md; do
      [ -f "$dfile" ] || continue
      # Extract subject from frontmatter
      SUBJECT=$(sed -n '/^---$/,/^---$/p' "$dfile" | grep -i '^subject:' | head -1 | sed 's/^subject: *//i')
      [ -z "$SUBJECT" ] && continue

      # Check if any changed file overlaps with the diarization subject
      if echo "$DIFF_FILES" | grep -qi "$SUBJECT" 2>/dev/null; then
        # Calculate age in days
        FILE_DATE=$(sed -n '/^---$/,/^---$/p' "$dfile" | grep -i '^date:' | head -1 | sed 's/^date: *//i')
        AGE_DAYS="unknown"
        if [ -n "$FILE_DATE" ]; then
          if command -v gdate >/dev/null 2>&1; then DC="gdate"; else DC="date"; fi
          FILE_EPOCH=$($DC -d "$FILE_DATE" +%s 2>/dev/null || echo 0)
          NOW_EPOCH=$($DC +%s 2>/dev/null || echo 0)
          if [ "$FILE_EPOCH" -gt 0 ]; then
            AGE_DAYS=$(( (NOW_EPOCH - FILE_EPOCH) / 86400 ))
          fi
        fi

        $DFIRST || DIAR_RESULTS="$DIAR_RESULTS,"
        DIAR_RESULTS="$DIAR_RESULTS{\"path\":\"$dfile\",\"subject\":\"$SUBJECT\",\"age_days\":\"$AGE_DAYS\"}"
        DFIRST=false
      fi
    done
    DIARIZATIONS_JSON="$DIAR_RESULTS]"
  fi
fi

# ─── 5. Load config ────────────────────────────────────────

CONFIG_JSON="{}"
CONFIG_FILE="$NANOSTACK_STORE/config.json"
if [ -f "$CONFIG_FILE" ]; then
  CONFIG_JSON=$(jq -c '{
    intensity: (.preferences.default_intensity // "standard"),
    conflict_precedence: (.preferences.conflict_precedence // "security"),
    detected_stack: (.detected // [])
  }' "$CONFIG_FILE" 2>/dev/null) || CONFIG_JSON="{}"
fi

# ─── 6. Load goal from session ─────────────────────────────

GOAL="null"
SESSION_FILE="$NANOSTACK_STORE/session.json"
if [ -f "$SESSION_FILE" ]; then
  SESSION_GOAL=$(jq -r '.goal // ""' "$SESSION_FILE" 2>/dev/null)
  [ -n "$SESSION_GOAL" ] && GOAL="\"$SESSION_GOAL\""
fi

# ─── 7. Load sprint metrics (plan + compound phases) ───────

METRICS_JSON="null"
if [ "$PHASE" = "plan" ] || [ "$PHASE" = "compound" ]; then
  METRICS_SH="$SCRIPT_DIR/sprint-metrics.sh"
  if [ -x "$METRICS_SH" ]; then
    METRICS_JSON=$("$METRICS_SH" 2>/dev/null) || METRICS_JSON="null"
  fi
fi

# ─── Output ─────────────────────────────────────────────────

jq -n \
  --arg phase "$PHASE" \
  --argjson artifacts "$ARTIFACTS_JSON" \
  --argjson solutions "$SOLUTIONS_JSON" \
  --argjson precedents "$PRECEDENTS_JSON" \
  --argjson diarizations "$DIARIZATIONS_JSON" \
  --argjson config "$CONFIG_JSON" \
  --argjson goal "$GOAL" \
  --argjson metrics "$METRICS_JSON" \
  '{
    phase: $phase,
    upstream_artifacts: $artifacts,
    solutions: $solutions,
    conflict_precedents: $precedents,
    diarizations: $diarizations,
    config: $config,
    goal: $goal,
    sprint_metrics: $metrics
  }'
