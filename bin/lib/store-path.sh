#!/usr/bin/env bash
# store-path.sh — Resolve the .nanostack store path
# Sources into other scripts. Sets NANOSTACK_STORE variable.
#
# Priority:
#   1. NANOSTACK_STORE env var (explicit override)
#   2. <git-root>/.nanostack (project-local, default)
#   3. $HOME/.nanostack (fallback if not in a git repo)

if [ -z "${NANOSTACK_STORE:-}" ]; then
  _GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$_GIT_ROOT" ]; then
    NANOSTACK_STORE="$_GIT_ROOT/.nanostack"
  else
    NANOSTACK_STORE="$HOME/.nanostack"
  fi
  unset _GIT_ROOT
fi

export NANOSTACK_STORE
