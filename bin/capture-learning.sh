#!/usr/bin/env bash
# capture-learning.sh — Append a learning to the Obsidian vault
# Usage: capture-learning.sh "what you learned"
# Or: capture-learning.sh (reads from stdin)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

KNOW_HOW="$NANOSTACK_STORE/know-how"
LEARNINGS_FILE="$KNOW_HOW/learnings/ongoing.md"
DATE=$(date +"%Y-%m-%d")
PROJECT=$(basename "$(pwd)")

mkdir -p "$(dirname "$LEARNINGS_FILE")"

# Create file with header if it doesn't exist
if [ ! -f "$LEARNINGS_FILE" ]; then
  {
    echo "# Ongoing Learnings"
    echo ""
    echo "Captured during sprints. Review periodically for patterns."
    echo ""
  } > "$LEARNINGS_FILE"
fi

# Get the learning text
if [ $# -gt 0 ]; then
  LEARNING="$*"
else
  echo "What did you learn? (enter to submit)"
  read -r LEARNING
fi

[ -z "$LEARNING" ] && { echo "Nothing to capture."; exit 0; }

# Append
{
  echo "## $DATE ($PROJECT)"
  echo ""
  echo "$LEARNING"
  echo ""
} >> "$LEARNINGS_FILE"

echo "Captured in $LEARNINGS_FILE"
