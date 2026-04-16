#!/usr/bin/env bash
# preflight.sh — Verify required commands are available
# Source this file early in scripts that depend on jq/git/etc.
# Fails fast with a clear message instead of cryptic mid-execution errors.
#
# Usage:
#   source "$SCRIPT_DIR/lib/preflight.sh"
#   nanostack_require jq
#   nanostack_require jq git
#
# To skip the check (e.g., for offline test envs), set NANOSTACK_SKIP_PREFLIGHT=1.

nanostack_require() {
  [ "${NANOSTACK_SKIP_PREFLIGHT:-0}" = "1" ] && return 0

  local missing=""
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="${missing:+$missing }$cmd"
    fi
  done

  if [ -n "$missing" ]; then
    echo "ERROR: nanostack requires the following commands but they were not found: $missing" >&2
    echo "" >&2
    for cmd in $missing; do
      case "$cmd" in
        jq)  echo "  jq:  brew install jq  |  apt install jq  |  choco install jq" >&2 ;;
        git) echo "  git: https://git-scm.com/downloads" >&2 ;;
        *)   echo "  $cmd: install via your package manager" >&2 ;;
      esac
    done
    echo "" >&2
    echo "Set NANOSTACK_SKIP_PREFLIGHT=1 to bypass this check (not recommended)." >&2
    exit 127
  fi
}
