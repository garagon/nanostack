#!/usr/bin/env bash
# upgrade.sh — Update nanostack to latest version
# Usage: bin/upgrade.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# Check we're in a git repo
if [ ! -d .git ]; then
  echo "Error: not a git repository. Run this from the nanostack directory." >&2
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

# Show what changed
COMMITS=$(git log --oneline "$BEFORE".."$AFTER" | wc -l | tr -d ' ')
echo ""
echo "Updated: $COMMITS new commits"
echo ""
git log --oneline "$BEFORE".."$AFTER"

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
