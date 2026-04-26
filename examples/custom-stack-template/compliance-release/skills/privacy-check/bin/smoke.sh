#!/usr/bin/env bash
# smoke.sh — privacy-check smoke check (placeholder for PR 1).
set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$SKILL_DIR/bin/check.sh"

if [ ! -x "$CHECK" ]; then
  echo "FAIL: $CHECK is not executable" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for the smoke check" >&2
  exit 1
fi

out=$( "$CHECK" 2>/dev/null )
if ! printf '%s' "$out" | jq -e '.signals' >/dev/null 2>&1; then
  echo "FAIL: check.sh did not emit a JSON object with .signals" >&2
  echo "$out" >&2
  exit 1
fi

echo "OK: privacy-check placeholder smoke passed (PR 2 wires the real behavior)"
