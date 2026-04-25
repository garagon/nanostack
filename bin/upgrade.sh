#!/usr/bin/env bash
# upgrade.sh — Update nanostack to latest version
# Usage: ~/.claude/skills/nanostack/bin/upgrade.sh (from anywhere)
# Supports both git clone and npx skills add installations.
set -e

# Disable git pager globally for this script
export GIT_PAGER=cat

# Save the original working directory before we cd into the install dir.
# The post-upgrade hint reads from this path to detect whether the user
# is currently inside a nanostack-initialized project that predates the
# hook era. Privacy: nanostack does not maintain a central registry of
# projects (per agent-agnostic-delivery-spec.md). Only the current cwd
# is inspected.
ORIGINAL_PWD="$(pwd)"

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

# Post-upgrade migration hint. Looks at ORIGINAL_PWD (the directory the
# user was in when they ran upgrade.sh) and checks whether
# .claude/settings.json exists but is missing the PreToolUse hooks. If
# so, prints the exact command to repair. Silent in every other case
# (not in a project, hooks already wired, no jq available, etc.).
print_repair_hint() {
  command -v jq >/dev/null 2>&1 || return 0
  local proj_settings="$ORIGINAL_PWD/.claude/settings.json"
  # If the user wasn't in a project root, walk up to a git root once;
  # this matches how init-project.sh resolves PROJECT_ROOT.
  if [ ! -f "$proj_settings" ]; then
    local git_root
    git_root=$(cd "$ORIGINAL_PWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
    [ -n "$git_root" ] && proj_settings="$git_root/.claude/settings.json"
  fi
  [ -f "$proj_settings" ] || return 0

  # Check whether the Bash and Write/Edit hooks are wired. Same jq
  # filter as nano-doctor and init-project.sh use so the three tools
  # stay in sync.
  local has_bash=0 has_write=0
  if jq -e '
    (.hooks.PreToolUse // [])
    | any(
        (.matcher // "" | test("Bash"))
        and ((.hooks // []) | any((.command // "") | contains("check-dangerous.sh")))
      )
  ' "$proj_settings" >/dev/null 2>&1; then
    has_bash=1
  fi
  if jq -e '
    (.hooks.PreToolUse // [])
    | any(
        (.matcher // "" | test("Write|Edit"))
        and ((.hooks // []) | any((.command // "") | contains("check-write.sh")))
      )
  ' "$proj_settings" >/dev/null 2>&1; then
    has_write=1
  fi

  if [ $has_bash -eq 1 ] && [ $has_write -eq 1 ]; then
    return 0
  fi

  printf "\n%b This project's settings need a hook migration:\n" "$STEP"
  printf "    %s\n" "$proj_settings"
  printf "    Run: %s/bin/init-project.sh --repair\n" "$SCRIPT_DIR"
}

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
    print_repair_hint
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

  print_repair_hint
  printf "%b Done.\n" "$STEP"

# npx/copy installation: re-install and re-run setup
else
  printf "%b Checking for updates (npx)...\n" "$STEP"
  if command -v npx >/dev/null 2>&1; then
    npx skills add garagon/nanostack -g --full-depth 2>&1
    printf "\n%b Re-running setup...\n" "$STEP"
    ./setup
    print_repair_hint
    printf "%b Done.\n" "$STEP"
  else
    echo "Error: npx not found. Install manually:" >&2
    echo "  npx skills add garagon/nanostack -g --full-depth" >&2
    exit 1
  fi
fi
