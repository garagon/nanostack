#!/usr/bin/env bash
# summarize.sh — release-readiness skill (placeholder for PR 1 of CSE v1).
#
# PR 2 replaces this body with the real composer that walks the five
# upstream artifacts (review, qa, security, license-audit,
# privacy-check) and rolls them up into a status. PR 1 ships only
# the scaffolding so the static contract validates.
set -e

cat <<'JSON'
{
  "checks": [],
  "rollup_status": "OK",
  "_placeholder": "release-readiness/bin/summarize.sh — PR 1 stub. Real behavior lands in PR 2."
}
JSON
