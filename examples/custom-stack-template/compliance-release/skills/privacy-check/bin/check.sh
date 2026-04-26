#!/usr/bin/env bash
# check.sh — privacy-check skill (placeholder for PR 1 of CSE v1).
#
# PR 2 replaces this body with the real release-hygiene scan
# (personal-data fields, telemetry imports, missing privacy note).
# PR 1 ships only the scaffolding so the static contract validates.
set -e

cat <<'JSON'
{
  "signals": [],
  "missing": [],
  "_placeholder": "privacy-check/bin/check.sh — PR 1 stub. Real behavior lands in PR 2."
}
JSON
