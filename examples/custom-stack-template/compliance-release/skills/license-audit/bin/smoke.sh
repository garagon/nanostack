#!/usr/bin/env bash
# smoke.sh — license-audit smoke check (placeholder for PR 1).
#
# PR 2 replaces this with a real /tmp project + manifests check.
# PR 1 ships only the file so the static contract validates that
# every skill folder has a smoke.sh.
set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$SKILL_DIR/bin/audit.sh"

if [ ! -x "$AUDIT" ]; then
  echo "FAIL: $AUDIT is not executable" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for the smoke check" >&2
  exit 1
fi

out=$( "$AUDIT" 2>/dev/null )
if ! printf '%s' "$out" | jq -e '.counts' >/dev/null 2>&1; then
  echo "FAIL: audit.sh did not emit a JSON object with .counts" >&2
  echo "$out" >&2
  exit 1
fi

echo "OK: license-audit placeholder smoke passed (PR 2 wires the real behavior)"
