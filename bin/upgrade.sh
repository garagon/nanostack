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

# Step prefix used to make multi-step progress visible during the 10-30s upgrade.
# Bold-only formatting via ANSI; harmless when the terminal does not support it.
if [ -t 1 ]; then
  STEP="\033[1m==>\033[0m"
else
  STEP="==>"
fi

# Git clone installation: pull updates
if [ -d .git ]; then
  BEFORE=$(git rev-parse HEAD)

  printf "%b Checking for updates...\n" "$STEP"
  git pull --ff-only 2>&1 || {
    echo "Error: pull failed. You may have local changes." >&2
    echo "Run: git stash && bin/upgrade.sh && git stash pop" >&2
    exit 1
  }

  AFTER=$(git rev-parse HEAD)

  if [ "$BEFORE" = "$AFTER" ]; then
    printf "%b Already up to date.\n" "$STEP"
    exit 0
  fi

  # Show what changed
  COMMITS=$(git --no-pager log --oneline "$BEFORE".."$AFTER" | wc -l | tr -d ' ')
  SHORT=$(git rev-parse --short "$AFTER")
  printf "\n%b Updated to %s (%s new commits):\n\n" "$STEP" "$SHORT" "$COMMITS"
  git --no-pager log --oneline "$BEFORE".."$AFTER"

  # Check if setup needs re-run
  CHANGED=$(git diff --name-only "$BEFORE".."$AFTER")
  if echo "$CHANGED" | grep -qE '^setup$|^commands/|/agents/openai\.yaml$'; then
    printf "\n%b Setup changed, re-running...\n" "$STEP"
    ./setup
  else
    printf "\n%b No setup changes needed.\n" "$STEP"
  fi

  printf "%b Done.\n" "$STEP"

# npx/copy installation: re-install and re-run setup
else
  printf "%b Checking for updates (npx)...\n" "$STEP"
  if command -v npx >/dev/null 2>&1; then
    npx skills add garagon/nanostack -g --full-depth 2>&1
    printf "\n%b Re-running setup...\n" "$STEP"
    ./setup
    printf "%b Done.\n" "$STEP"
  else
    echo "Error: npx not found. Install manually:" >&2
    echo "  npx skills add garagon/nanostack -g --full-depth" >&2
    exit 1
  fi
fi
