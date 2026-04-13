#!/usr/bin/env bash
# graduate.sh — Promote validated solutions into skill files
# Scans solutions, filters by graduation criteria, proposes or applies
# insertions into SKILL.md Graduated Rules sections.
#
# Usage:
#   graduate.sh                 Dry run — show candidates
#   graduate.sh --apply         Apply graduated rules to skill files
#   graduate.sh --prune         Remove stale graduated rules (referenced files gone)
#   graduate.sh --status        Show current graduation budget usage
#
# Graduation criteria (all must be true):
#   - applied_count >= 3
#   - validated: true
#   - last_validated within 60 days
#   - Referenced files still exist
#   - Not already graduated
#
# Caps per skill (from benchmark):
#   review: 10 rules, plan: 8 rules, security: 8 rules
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

source "$SCRIPT_DIR/lib/audit.sh"

NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOLUTIONS_DIR="$NANOSTACK_STORE/know-how/solutions"

MODE="dry-run"
for arg in "$@"; do
  case "$arg" in
    --apply) MODE="apply" ;;
    --prune) MODE="prune" ;;
    --status) MODE="status" ;;
  esac
done

# ─── Caps ───────────────────────────────────────────────────
MAX_REVIEW=10
MAX_PLAN=8
MAX_SECURITY=8

# ─── Skill file paths ──────────────────────────────────────
REVIEW_SKILL="$NANOSTACK_ROOT/review/SKILL.md"
PLAN_SKILL="$NANOSTACK_ROOT/plan/SKILL.md"
SECURITY_SKILL="$NANOSTACK_ROOT/security/SKILL.md"

# ─── Helpers ────────────────────────────────────────────────

get_field() {
  local file="$1" field="$2"
  sed -n '/^---$/,/^---$/p' "$file" | grep -i "^${field}:" | head -1 | sed "s/^${field}: *//i"
}

count_graduated_rules() {
  local skill_file="$1"
  # Count rule lines between Graduated Rules header and END marker
  # Uses grep/awk instead of BSD-incompatible sed range+nested pattern
  awk '/^#+ Graduated Rules/,/END GRADUATED RULES/{if(/^- \*\*/) count++} END{print count+0}' "$skill_file" 2>/dev/null
}

target_skill() {
  local type="$1" tags="$2"
  # Security-tagged solutions go to security regardless of type
  if echo "$tags" | grep -qiE 'security|auth|injection|secrets|xss|csrf|rce' 2>/dev/null; then
    echo "security"
    return
  fi
  case "$type" in
    bug) echo "review" ;;
    pattern) echo "plan" ;;
    decision) echo "plan" ;;
    *) echo "review" ;;
  esac
}

skill_file_for() {
  case "$1" in
    review) echo "$REVIEW_SKILL" ;;
    plan) echo "$PLAN_SKILL" ;;
    security) echo "$SECURITY_SKILL" ;;
  esac
}

cap_for() {
  case "$1" in
    review) echo "$MAX_REVIEW" ;;
    plan) echo "$MAX_PLAN" ;;
    security) echo "$MAX_SECURITY" ;;
  esac
}

# ─── Status mode ────────────────────────────────────────────

if [ "$MODE" = "status" ]; then
  echo ""
  echo "Graduation Budget"
  echo "══════════════════"
  for skill in review plan security; do
    FILE=$(skill_file_for "$skill")
    CAP=$(cap_for "$skill")
    CURRENT=$(count_graduated_rules "$FILE")
    echo "  $skill: $CURRENT / $CAP rules"
  done

  TOTAL_SOLUTIONS=0
  GRADUATED_SOLUTIONS=0
  if [ -d "$SOLUTIONS_DIR" ]; then
    while IFS= read -r sol; do
      [ -z "$sol" ] && continue
      TOTAL_SOLUTIONS=$((TOTAL_SOLUTIONS + 1))
      GRAD=$(get_field "$sol" "graduated")
      [ "$GRAD" = "true" ] && GRADUATED_SOLUTIONS=$((GRADUATED_SOLUTIONS + 1))
    done < <(find "$SOLUTIONS_DIR" -name "*.md" -type f 2>/dev/null)
  fi
  echo ""
  echo "  Solutions: $TOTAL_SOLUTIONS total, $GRADUATED_SOLUTIONS graduated"
  echo ""
  exit 0
fi

# ─── Prune mode ─────────────────────────────────────────────

if [ "$MODE" = "prune" ]; then
  echo ""
  echo "Prune: checking graduated rules for staleness..."
  echo ""
  PRUNE_COUNT=0

  for skill in review plan security; do
    FILE=$(skill_file_for "$skill")
    [ -f "$FILE" ] || continue

    # Extract graduated rules with their source annotations
    grep -q 'Graduated Rules' "$FILE" 2>/dev/null || continue
    RULES=$(awk '/^#+ Graduated Rules/,/END GRADUATED RULES/{if(/^- \*\*/) print}' "$FILE" 2>/dev/null || true)
    [ -z "$RULES" ] && continue

    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      # Extract source file from annotation: (Source: bug/name.md, applied Nx)
      SOURCE=$(echo "$rule" | grep -oE 'Source: [^,)]+' | sed 's/Source: //')
      [ -z "$SOURCE" ] && continue

      SOURCE_PATH="$SOLUTIONS_DIR/$SOURCE"
      if [ ! -f "$SOURCE_PATH" ]; then
        echo "  STALE [$skill]: Source gone: $SOURCE"
        echo "    Rule: $(echo "$rule" | head -c 100)"
        PRUNE_COUNT=$((PRUNE_COUNT + 1))
      else
        # Check if referenced files in the solution still exist
        FM_FILES=$(get_field "$SOURCE_PATH" "files")
        if [ -n "$FM_FILES" ] && [ "$FM_FILES" != "[]" ]; then
          ALL_GONE=true
          for ref_file in $(echo "$FM_FILES" | tr -d '[]"' | tr ',' ' '); do
            ref_file=$(echo "$ref_file" | tr -d ' ' | sed 's/:.*$//')
            [ -z "$ref_file" ] && continue
            [ -f "$ref_file" ] && { ALL_GONE=false; break; }
          done
          if [ "$ALL_GONE" = true ]; then
            echo "  STALE [$skill]: All referenced files gone: $SOURCE"
            echo "    Rule: $(echo "$rule" | head -c 100)"
            PRUNE_COUNT=$((PRUNE_COUNT + 1))
          fi
        fi
      fi
    done <<< "$RULES"
  done

  if [ "$PRUNE_COUNT" -eq 0 ]; then
    echo "  No stale rules found."
  else
    echo ""
    echo "  $PRUNE_COUNT stale rules found. Remove manually from the Graduated Rules sections."
  fi
  echo ""
  exit 0
fi

# ─── Dry-run / Apply mode ──────────────────────────────────

[ ! -d "$SOLUTIONS_DIR" ] && { echo "No solutions directory found."; exit 0; }

# Collect candidates
CANDIDATES=""
CANDIDATE_COUNT=0

if command -v gdate >/dev/null 2>&1; then DC="gdate"; else DC="date"; fi
NOW_EPOCH=$($DC +%s 2>/dev/null || echo 0)
SIXTY_DAYS=$((60 * 86400))

while IFS= read -r filepath; do
  [ -z "$filepath" ] && continue

  APPLIED=$(get_field "$filepath" "applied_count")
  VALIDATED=$(get_field "$filepath" "validated")
  LAST_VAL=$(get_field "$filepath" "last_validated")
  GRADUATED=$(get_field "$filepath" "graduated")
  TITLE=$(get_field "$filepath" "title")
  TYPE_DIR=$(basename "$(dirname "$filepath")")
  TAGS=$(get_field "$filepath" "tags")
  FM_FILES=$(get_field "$filepath" "files")
  SEVERITY=$(get_field "$filepath" "severity")

  # Skip already graduated
  [ "$GRADUATED" = "true" ] && continue

  # Check applied_count >= 3
  [ -z "$APPLIED" ] && continue
  [ "$APPLIED" -lt 3 ] 2>/dev/null && continue

  # Check validated
  [ "$VALIDATED" != "true" ] && continue

  # Check last_validated within 60 days
  if [ -n "$LAST_VAL" ] && [ "$LAST_VAL" != "null" ]; then
    VAL_EPOCH=$($DC -d "$LAST_VAL" +%s 2>/dev/null || echo 0)
    if [ "$VAL_EPOCH" -gt 0 ] && [ $((NOW_EPOCH - VAL_EPOCH)) -gt "$SIXTY_DAYS" ]; then
      continue
    fi
  else
    continue
  fi

  # Check referenced files still exist (at least one)
  if [ -n "$FM_FILES" ] && [ "$FM_FILES" != "[]" ]; then
    ANY_EXISTS=false
    for ref_file in $(echo "$FM_FILES" | tr -d '[]"' | tr ',' ' '); do
      ref_file=$(echo "$ref_file" | tr -d ' ' | sed 's/:.*$//')
      [ -z "$ref_file" ] && continue
      [ -f "$ref_file" ] && { ANY_EXISTS=true; break; }
    done
    [ "$ANY_EXISTS" = false ] && continue
  fi

  # Determine target skill
  TARGET=$(target_skill "$TYPE_DIR" "$TAGS")
  TARGET_FILE=$(skill_file_for "$TARGET")
  TARGET_CAP=$(cap_for "$TARGET")

  # Check cap
  CURRENT=$(count_graduated_rules "$TARGET_FILE")
  if [ "$CURRENT" -ge "$TARGET_CAP" ]; then
    continue  # Cap reached, skip
  fi

  # Extract the rule text: use Prevention section for bugs, Pattern section for patterns, Decision for decisions
  RULE_TEXT=""
  SECTION=""
  case "$TYPE_DIR" in
    bug) SECTION="Prevention" ;;
    pattern) SECTION="Pattern" ;;
    decision) SECTION="Decision" ;;
  esac
  if [ -n "$SECTION" ]; then
    RULE_TEXT=$(awk -v s="$SECTION" '/^## /{found=0} /^## '"$SECTION"'/{found=1; next} found{print}' "$filepath" | head -5 | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//')
  fi

  # Fallback to title if section is empty
  [ -z "$RULE_TEXT" ] && RULE_TEXT="$TITLE"

  # Truncate to 200 chars
  RULE_TEXT=$(echo "$RULE_TEXT" | head -c 200)

  SOURCE_REF="$TYPE_DIR/$(basename "$filepath")"
  CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
  CANDIDATES="$CANDIDATES
$filepath|$TARGET|$TITLE|$RULE_TEXT|$SOURCE_REF|$APPLIED|$SEVERITY"

done < <(find "$SOLUTIONS_DIR" -name "*.md" -type f 2>/dev/null | sort)

# ─── Output candidates ─────────────────────────────────────

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "No solutions meet graduation criteria."
  exit 0
fi

echo ""
echo "Graduate candidates: $CANDIDATE_COUNT"
echo ""

IDX=1
echo "$CANDIDATES" | while IFS='|' read -r filepath target title rule_text source_ref applied severity; do
  [ -z "$filepath" ] && continue
  echo "  [$IDX] $source_ref → $target/SKILL.md"
  echo "      Rule: \"$rule_text\""
  echo "      Evidence: applied ${applied}x, validated, $severity"
  echo ""
  IDX=$((IDX + 1))
done

# ─── Apply mode ─────────────────────────────────────────────

if [ "$MODE" = "apply" ]; then
  echo "Applying..."
  echo ""

  echo "$CANDIDATES" | while IFS='|' read -r filepath target title rule_text source_ref applied severity; do
    [ -z "$filepath" ] && continue

    TARGET_FILE=$(skill_file_for "$target")
    [ ! -f "$TARGET_FILE" ] && continue

    # Build the rule line
    RULE_LINE="- **$(echo "$title" | head -c 80)** — $rule_text (Source: $source_ref, applied ${applied}x)"

    # Insert into Graduated Rules section (before the closing marker)
    if grep -q '<!-- END GRADUATED RULES -->' "$TARGET_FILE" 2>/dev/null; then
      # Insert before the end marker
      sed -i '' "/<!-- END GRADUATED RULES -->/i\\
$RULE_LINE" "$TARGET_FILE" 2>/dev/null || \
      sed -i "/<!-- END GRADUATED RULES -->/i\\$RULE_LINE" "$TARGET_FILE" 2>/dev/null
    fi

    # Mark solution as graduated (macOS BSD sed compatible)
    if grep -q '^graduated:' "$filepath" 2>/dev/null; then
      sed -i '' "s/^graduated:.*/graduated: true/" "$filepath" 2>/dev/null || \
        sed -i "s/^graduated:.*/graduated: true/" "$filepath" 2>/dev/null || true
    else
      # Add graduated fields after applied_count in frontmatter
      sed -i '' "/^applied_count:/a\\
graduated: true\\
graduated_to: $target/SKILL.md" "$filepath" 2>/dev/null || \
        sed -i "/^applied_count:/a\\graduated: true\ngraduated_to: $target/SKILL.md" "$filepath" 2>/dev/null || true
    fi

    # Update graduated_to if already exists
    if grep -q '^graduated_to:' "$filepath" 2>/dev/null; then
      sed -i '' "s|^graduated_to:.*|graduated_to: $target/SKILL.md|" "$filepath" 2>/dev/null || \
        sed -i "s|^graduated_to:.*|graduated_to: $target/SKILL.md|" "$filepath" 2>/dev/null || true
    fi

    audit_log "solution_graduated" "$source_ref" "$target/SKILL.md"
    echo "  ✓ $source_ref → $target/SKILL.md"
  done

  echo ""
  echo "Done. Review the changes in the SKILL.md files."
fi
