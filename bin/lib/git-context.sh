#!/usr/bin/env bash
# git-context.sh — Detect git availability for local mode adaptation
# Source this file, then call: detect_git_mode
# Returns: "full" (git + remote), "local-git" (git, no remote), "local" (no git)

detect_git_mode() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "local"
    return 0
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    echo "full"
    return 0
  fi
  echo "local-git"
}
