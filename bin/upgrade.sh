#!/usr/bin/env bash
# upgrade.sh — Update nanostack to latest version
# Usage: ~/.claude/skills/nanostack/bin/upgrade.sh (from anywhere)
set -e

# Find nanostack directory
if [ -f "$(dirname "$0")/../setup" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
elif [ -d "$HOME/.claude/skills/nanostack/.git" ]; then
  SCRIPT_DIR="$HOME/.claude/skills/nanostack"
elif [ -f "$HOME/.nanostack/setup.json" ]; then
  SCRIPT_DIR=$(jq -r '.source' "$HOME/.nanostack/setup.json" 2>/dev/null)
else
  echo "Error: can't find nanostack. Is it installed?" >&2
  exit 1
fi

cd "$SCRIPT_DIR"

if [ ! -d .git ]; then
  echo "Error: not a git repository at $SCRIPT_DIR" >&2
  exit 1
fi

BEFORE=$(git rev-parse HEAD)

echo "Updating nanostack..."
git pull --ff-only 2>&1 || {
  echo "Error: pull failed. You may have local changes." >&2
  echo "Run: git stash && bin/upgrade.sh && git stash pop" >&2
  exit 1
}

AFTER=$(git rev-parse HEAD)

if [ "$BEFORE" = "$AFTER" ]; then
  echo "Already up to date."
  exit 0
fi

# Show what changed (--no-pager prevents opening less/vim)
COMMITS=$(git --no-pager log --oneline "$BEFORE".."$AFTER" | wc -l | tr -d ' ')
echo ""
echo "Updated: $COMMITS new commits"
echo ""
git --no-pager log --oneline "$BEFORE".."$AFTER"

# Check if setup needs re-run (new skills or setup changes)
CHANGED=$(git diff --name-only "$BEFORE".."$AFTER")
if echo "$CHANGED" | grep -qE '^setup$|/agents/openai\.yaml$'; then
  echo ""
  echo "Setup changed. Re-running..."
  ./setup
else
  echo ""
  echo "No setup changes needed."
fi
