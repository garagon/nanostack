#!/usr/bin/env bash
# doctor.sh — Know-how health check
# Diagnoses the .nanostack/know-how/ directory for stale, unused,
# or orphaned knowledge. Inspired by gbrain's dream cycle.
#
# Usage:
#   doctor.sh              Human-readable report
#   doctor.sh --json       Machine-readable output
#   doctor.sh --fix        Auto-fix safe issues (remove stale refs, prune empty)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

SOLUTIONS_DIR="$NANOSTACK_STORE/know-how/solutions"
DIARIZE_DIR="$NANOSTACK_STORE/know-how/diarizations"
BRIEFS_DIR="$NANOSTACK_STORE/know-how/briefs"
# Journal dir reserved for future checks

JSON_OUTPUT=false
FIX_MODE=false
for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    --fix) FIX_MODE=true ;;
  esac
done

NOW_EPOCH=$(date +%s 2>/dev/null || echo 0)
SIXTY_DAYS=$((60 * 86400))
NINETY_DAYS=$((90 * 86400))

# ─── Helpers ────────────────────────────────────────────────

# Cross-platform date-to-epoch (macOS + Linux)
date_to_epoch() {
  local d="$1"
  if command -v gdate >/dev/null 2>&1; then
    gdate -d "$d" +%s 2>/dev/null || echo 0
  elif date -j -f "%Y-%m-%d" "$d" +%s >/dev/null 2>&1; then
    date -j -f "%Y-%m-%d" "$d" +%s
  else
    date -d "$d" +%s 2>/dev/null || echo 0
  fi
}

get_field() {
  local file="$1" field="$2"
  sed -n '/^---$/,/^---$/p' "$file" | grep -i "^${field}:" | head -1 | sed "s/^${field}: *//i"
}

# ─── Counters ───────────────────────────────────────────────

TOTAL_SOLUTIONS=0
STALE_SOLUTIONS=0
UNUSED_SOLUTIONS=0
UNVALIDATED_SOLUTIONS=0
GRADUATION_CANDIDATES=0
STALE_DIARIZATIONS=0
TOTAL_DIARIZATIONS=0
TOTAL_BRIEFS=0

STALE_LIST=""
UNUSED_LIST=""
UNVALIDATED_LIST=""
STALE_DIAR_LIST=""

# ─── 1. Solution health ────────────────────────────────────

if [ -d "$SOLUTIONS_DIR" ]; then
  while IFS= read -r filepath; do
    [ -z "$filepath" ] && continue
    TOTAL_SOLUTIONS=$((TOTAL_SOLUTIONS + 1))

    DATE=$(get_field "$filepath" "date")
    VALIDATED=$(get_field "$filepath" "validated")
    APPLIED=$(get_field "$filepath" "applied_count")
    FM_FILES=$(get_field "$filepath" "files")
    GRADUATED=$(get_field "$filepath" "graduated")
    TYPE_DIR=$(basename "$(dirname "$filepath")")
    BASENAME=$(basename "$filepath")

    # Check stale: all referenced files gone
    if [ -n "$FM_FILES" ] && [ "$FM_FILES" != "[]" ]; then
      ALL_GONE=true
      HAS_FILES=false
      for ref_file in $(echo "$FM_FILES" | tr -d '[]"' | tr ',' ' '); do
        ref_file=$(echo "$ref_file" | tr -d ' ' | sed 's/:.*$//')
        [ -z "$ref_file" ] && continue
        HAS_FILES=true
        [ -f "$ref_file" ] && { ALL_GONE=false; break; }
      done
      if [ "$HAS_FILES" = true ] && [ "$ALL_GONE" = true ]; then
        STALE_SOLUTIONS=$((STALE_SOLUTIONS + 1))
        STALE_LIST="$STALE_LIST\n  $TYPE_DIR/$BASENAME — all referenced files deleted"
      fi
    fi

    # Check unused: applied_count=0 and older than 60 days
    APPLIED_NUM="${APPLIED:-0}"
    if [ "$APPLIED_NUM" = "0" ] && [ -n "$DATE" ]; then
      DOC_EPOCH=$(date_to_epoch "$DATE")
      if [ "$DOC_EPOCH" -gt 0 ] && [ $((NOW_EPOCH - DOC_EPOCH)) -gt "$SIXTY_DAYS" ]; then
        UNUSED_SOLUTIONS=$((UNUSED_SOLUTIONS + 1))
        UNUSED_LIST="$UNUSED_LIST\n  $TYPE_DIR/$BASENAME — never applied, $(( (NOW_EPOCH - DOC_EPOCH) / 86400 )) days old"
      fi
    fi

    # Check unvalidated: validated=false and older than 90 days
    if [ "$VALIDATED" != "true" ] && [ -n "$DATE" ]; then
      DOC_EPOCH=$(date_to_epoch "$DATE")
      if [ "$DOC_EPOCH" -gt 0 ] && [ $((NOW_EPOCH - DOC_EPOCH)) -gt "$NINETY_DAYS" ]; then
        UNVALIDATED_SOLUTIONS=$((UNVALIDATED_SOLUTIONS + 1))
        UNVALIDATED_LIST="$UNVALIDATED_LIST\n  $TYPE_DIR/$BASENAME — unvalidated, $(( (NOW_EPOCH - DOC_EPOCH) / 86400 )) days old"
      fi
    fi

    # Check graduation candidates
    if [ "$GRADUATED" != "true" ] && [ "${APPLIED_NUM:-0}" -ge 3 ] && [ "$VALIDATED" = "true" ]; then
      GRADUATION_CANDIDATES=$((GRADUATION_CANDIDATES + 1))
    fi

  done < <(find "$SOLUTIONS_DIR" -name "*.md" -type f 2>/dev/null | sort)
fi

# ─── 2. Diarization health ─────────────────────────────────

if [ -d "$DIARIZE_DIR" ]; then
  for dfile in "$DIARIZE_DIR"/*.md; do
    [ -f "$dfile" ] || continue
    TOTAL_DIARIZATIONS=$((TOTAL_DIARIZATIONS + 1))

    D_DATE=$(get_field "$dfile" "date")
    D_SUBJECT=$(get_field "$dfile" "subject")

    if [ -n "$D_DATE" ]; then
      D_EPOCH=$(date_to_epoch "$D_DATE")
      AGE_DAYS=0
      [ "$D_EPOCH" -gt 0 ] && AGE_DAYS=$(( (NOW_EPOCH - D_EPOCH) / 86400 ))

      # Check if subject files were modified after diarization date
      if [ -n "$D_SUBJECT" ]; then
        TOUCHED=false
        if [ -d "$D_SUBJECT" ]; then
          LATEST_MOD=$(find "$D_SUBJECT" -type f -newer "$dfile" 2>/dev/null | head -1)
          [ -n "$LATEST_MOD" ] && TOUCHED=true
        elif [ -f "$D_SUBJECT" ]; then
          [ "$D_SUBJECT" -nt "$dfile" ] && TOUCHED=true
        fi
        if [ "$TOUCHED" = true ]; then
          STALE_DIARIZATIONS=$((STALE_DIARIZATIONS + 1))
          STALE_DIAR_LIST="$STALE_DIAR_LIST\n  $(basename "$dfile") — subject modified since last diarization (${AGE_DAYS}d old)"
        fi
      fi
    fi
  done
fi

# ─── 3. Brief health ───────────────────────────────────────

if [ -d "$BRIEFS_DIR" ]; then
  TOTAL_BRIEFS=$(find "$BRIEFS_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

# ─── 4. Score ───────────────────────────────────────────────

ISSUES=$((STALE_SOLUTIONS + UNUSED_SOLUTIONS + UNVALIDATED_SOLUTIONS + STALE_DIARIZATIONS))
if [ "$TOTAL_SOLUTIONS" -eq 0 ]; then
  SCORE="N/A"
  GRADE="no data"
elif [ "$ISSUES" -eq 0 ]; then
  SCORE="10/10"
  GRADE="healthy"
elif [ "$ISSUES" -le 2 ]; then
  SCORE="8/10"
  GRADE="good"
elif [ "$ISSUES" -le 5 ]; then
  SCORE="6/10"
  GRADE="needs attention"
else
  SCORE="4/10"
  GRADE="unhealthy"
fi

# ─── Output ─────────────────────────────────────────────────

if $JSON_OUTPUT; then
  jq -n \
    --arg score "$SCORE" \
    --arg grade "$GRADE" \
    --argjson total_solutions "$TOTAL_SOLUTIONS" \
    --argjson stale "$STALE_SOLUTIONS" \
    --argjson unused "$UNUSED_SOLUTIONS" \
    --argjson unvalidated "$UNVALIDATED_SOLUTIONS" \
    --argjson graduation_candidates "$GRADUATION_CANDIDATES" \
    --argjson total_diarizations "$TOTAL_DIARIZATIONS" \
    --argjson stale_diarizations "$STALE_DIARIZATIONS" \
    --argjson total_briefs "$TOTAL_BRIEFS" \
    --argjson issues "$ISSUES" \
    '{
      score: $score,
      grade: $grade,
      solutions: { total: $total_solutions, stale: $stale, unused: $unused, unvalidated: $unvalidated, graduation_candidates: $graduation_candidates },
      diarizations: { total: $total_diarizations, stale: $stale_diarizations },
      briefs: { total: $total_briefs },
      issues: $issues
    }'
  exit 0
fi

echo ""
echo "Know-how Health: $SCORE ($GRADE)"
echo "════════════════════════════════"
echo ""
echo "  Solutions: $TOTAL_SOLUTIONS total"

if [ "$STALE_SOLUTIONS" -gt 0 ]; then
  echo "  Stale ($STALE_SOLUTIONS): all referenced files deleted"
  printf "$STALE_LIST\n"
fi

if [ "$UNUSED_SOLUTIONS" -gt 0 ]; then
  echo "  Unused ($UNUSED_SOLUTIONS): never applied, 60+ days old"
  printf "$UNUSED_LIST\n"
fi

if [ "$UNVALIDATED_SOLUTIONS" -gt 0 ]; then
  echo "  Unvalidated ($UNVALIDATED_SOLUTIONS): not validated, 90+ days old"
  printf "$UNVALIDATED_LIST\n"
fi

if [ "$GRADUATION_CANDIDATES" -gt 0 ]; then
  echo "  Ready to graduate: $GRADUATION_CANDIDATES (run graduate.sh)"
fi

if [ "$TOTAL_SOLUTIONS" -gt 0 ] && [ "$STALE_SOLUTIONS" -eq 0 ] && [ "$UNUSED_SOLUTIONS" -eq 0 ] && [ "$UNVALIDATED_SOLUTIONS" -eq 0 ]; then
  echo "  All solutions healthy."
fi

echo ""
echo "  Diarizations: $TOTAL_DIARIZATIONS total"
if [ "$STALE_DIARIZATIONS" -gt 0 ]; then
  echo "  Stale ($STALE_DIARIZATIONS): subject modified since last run"
  printf "$STALE_DIAR_LIST\n"
elif [ "$TOTAL_DIARIZATIONS" -gt 0 ]; then
  echo "  All diarizations current."
fi

echo ""
echo "  Briefs: $TOTAL_BRIEFS total"

echo ""

# ─── Fix mode ───────────────────────────────────────────────

if $FIX_MODE && [ "$ISSUES" -gt 0 ]; then
  echo "Fixes applied:"

  # Remove stale solutions (all files gone = solution is noise)
  if [ "$STALE_SOLUTIONS" -gt 0 ] && [ -d "$SOLUTIONS_DIR" ]; then
    while IFS= read -r filepath; do
      [ -z "$filepath" ] && continue
      FM_FILES=$(get_field "$filepath" "files")
      [ -z "$FM_FILES" ] || [ "$FM_FILES" = "[]" ] && continue
      ALL_GONE=true
      for ref_file in $(echo "$FM_FILES" | tr -d '[]"' | tr ',' ' '); do
        ref_file=$(echo "$ref_file" | tr -d ' ' | sed 's/:.*$//')
        [ -z "$ref_file" ] && continue
        [ -f "$ref_file" ] && { ALL_GONE=false; break; }
      done
      if [ "$ALL_GONE" = true ]; then
        echo "  Removed stale: $(basename "$(dirname "$filepath")")/$(basename "$filepath")"
        rm -f "$filepath"
      fi
    done < <(find "$SOLUTIONS_DIR" -name "*.md" -type f 2>/dev/null)
  fi

  echo ""
fi
