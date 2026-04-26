#!/usr/bin/env bash
# smoke.sh — release-readiness smoke check (placeholder for PR 1).
set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUMMARIZE="$SKILL_DIR/bin/summarize.sh"

if [ ! -x "$SUMMARIZE" ]; then
  echo "FAIL: $SUMMARIZE is not executable" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for the smoke check" >&2
  exit 1
fi

out=$( "$SUMMARIZE" 2>/dev/null )
if ! printf '%s' "$out" | jq -e '.checks' >/dev/null 2>&1; then
  echo "FAIL: summarize.sh did not emit a JSON object with .checks" >&2
  echo "$out" >&2
  exit 1
fi

echo "OK: release-readiness placeholder smoke passed (PR 2 wires the real behavior)"
