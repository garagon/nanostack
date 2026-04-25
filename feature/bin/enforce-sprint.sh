#!/usr/bin/env bash
# enforce-sprint.sh — PreToolUse hook for /feature
# Blocks git commit if review, security, or qa artifacts are missing.
# Forces the agent to run the full sprint before shipping.
set -e

CMD="${1:-$(cat)}"
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/bin/lib/store-path.sh"

# Only intercept git commit commands
case "$CMD" in
  *git\ commit*|*git\ add*) ;;
  *) exit 0 ;;
esac

PROJECT="$(pwd)"
MISSING=""

# Find the most recent code change timestamp
LAST_CODE_CHANGE=$(git log -1 --format=%ct 2>/dev/null || echo 0)
# If no commits yet, use the newest source file modification time.
# Try BSD stat (-f %m) first, then fall back to GNU stat (-c %Y) so the
# gate works on Linux agents, not just macOS. Mirrors the portable
# pattern already in guard/bin/phase-gate.sh.
if [ "$LAST_CODE_CHANGE" -eq 0 ]; then
  _srcs=$(find . -name '*.js' -o -name '*.ts' -o -name '*.html' -o -name '*.css' -o -name '*.py' -o -name '*.go' 2>/dev/null | head -20)
  LAST_CODE_CHANGE=$(echo "$_srcs" | xargs stat -f %m 2>/dev/null | sort -rn | head -1)
  [ -z "$LAST_CODE_CHANGE" ] && LAST_CODE_CHANGE=$(echo "$_srcs" | xargs stat -c %Y 2>/dev/null | sort -rn | head -1)
  [ -z "$LAST_CODE_CHANGE" ] && LAST_CODE_CHANGE=0
  unset _srcs
fi

# Check for artifacts that are newer than the last code change
for phase in plan review security qa; do
  ARTIFACT=$("$SCRIPT_DIR/bin/find-artifact.sh" "$phase" 2 2>/dev/null) || {
    MISSING="${MISSING:+$MISSING, }$phase"
    continue
  }
  # Verify artifact belongs to this project
  if ! jq -e --arg p "$PROJECT" '.project == $p' "$ARTIFACT" >/dev/null 2>&1; then
    MISSING="${MISSING:+$MISSING, }$phase"
    continue
  fi
  # Verify artifact is newer than last code change
  ARTIFACT_TIME=$(stat -f %m "$ARTIFACT" 2>/dev/null || stat -c %Y "$ARTIFACT" 2>/dev/null || echo 0)
  if [ "$ARTIFACT_TIME" -lt "$LAST_CODE_CHANGE" ]; then
    MISSING="${MISSING:+$MISSING, }$phase"
  fi
done

if [ -n "$MISSING" ]; then
  echo "BLOCKED [FEATURE] Sprint phases incomplete: $MISSING"
  echo ""
  echo "The /feature command requires a full sprint before committing."
  echo "Missing phases: $MISSING"
  echo ""
  echo "Run these skills first:"
  for phase in $MISSING; do
    phase_clean=$(echo "$phase" | tr -d ',')
    case "$phase_clean" in
      plan)     echo "  - Use Skill tool: skill=\"nano\"" ;;
      review)   echo "  - Use Skill tool: skill=\"review\"" ;;
      security) echo "  - Use Skill tool: skill=\"security\"" ;;
      qa)       echo "  - Use Skill tool: skill=\"qa\"" ;;
    esac
  done
  exit 1
fi

# All phases present
exit 0
