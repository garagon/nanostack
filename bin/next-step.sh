#!/usr/bin/env bash
# next-step.sh — Determine which sprint phases still need to run.
#
# Usage: next-step.sh <current-phase>
#   current-phase: review | security | qa
#
# Output: space-separated list of pending phases for the post-build trio
#   (review, security, qa) plus "ship" if any of them is missing or if the
#   ship artifact itself is missing.
#
# Pending = no fresh (within 1 day) artifact found by find-artifact.sh.
#
# Used by /review, /security, /qa to give phase-aware "Next Step" guidance
# instead of always suggesting every other phase.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

CURRENT="${1:?Usage: next-step.sh <current-phase>}"
FIND="$SCRIPT_DIR/find-artifact.sh"

PEERS="review security qa"
PENDING=""

for phase in $PEERS; do
  [ "$phase" = "$CURRENT" ] && continue
  if ! "$FIND" "$phase" 1 >/dev/null 2>&1; then
    PENDING="${PENDING:+$PENDING }$phase"
  fi
done

# ship is the terminal step. List it if anything before it is pending,
# or if ship itself has no fresh artifact.
if [ -n "$PENDING" ]; then
  PENDING="$PENDING ship"
elif ! "$FIND" "ship" 1 >/dev/null 2>&1; then
  PENDING="ship"
fi

echo "$PENDING"
