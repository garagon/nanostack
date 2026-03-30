#!/usr/bin/env bash
# upgrade.sh — Update nanostack to latest version
# Usage: ~/.claude/skills/nanostack/bin/upgrade.sh (from anywhere)
# Supports both git clone and npx skills add installations.
set -e

# Disable git pager globally for this script
export GIT_PAGER=cat

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

# Git clone installation: pull updates
if [ -d .git ]; then
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
  COMMITS=$(git --no-pager log --oneline "$BEFORE".."$AFTER" | wc -l | tr -d ' ')
  echo ""
  echo "Updated: $COMMITS new commits"
  echo ""
  git --no-pager log --oneline "$BEFORE".."$AFTER"

  # Check if setup needs re-run
  CHANGED=$(git diff --name-only "$BEFORE".."$AFTER")
  if echo "$CHANGED" | grep -qE '^setup$|^commands/|/agents/openai\.yaml$'; then
    echo ""
    echo "Setup changed. Re-running..."
    ./setup
  else
    echo ""
    echo "No setup changes needed."
  fi

# npx/copy installation: re-install and re-run setup
else
  echo "Updating nanostack (npx)..."
  if command -v npx >/dev/null 2>&1; then
    npx skills add garagon/nanostack -g --full-depth 2>&1
    echo ""
    echo "Re-running setup..."
    ./setup
  else
    echo "Error: npx not found. Install manually:" >&2
    echo "  npx skills add garagon/nanostack -g --full-depth" >&2
    exit 1
  fi
fi
