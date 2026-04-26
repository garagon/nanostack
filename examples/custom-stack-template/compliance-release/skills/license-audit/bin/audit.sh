#!/usr/bin/env bash
# audit.sh — license-audit skill (placeholder for PR 1 of CSE v1).
#
# PR 2 of the Custom Stack Examples v1 round replaces this body with
# real license classification across npm/pip/go manifests. PR 1 ships
# only the scaffolding so the static contract validates.
#
# When PR 2 lands, the helper must:
#   - Detect the project stack from package.json | requirements.txt |
#     pyproject.toml | go.mod.
#   - Classify each direct dependency's license into permissive,
#     weak_copyleft, strong_copyleft, or unknown.
#   - Print a JSON object on stdout: { counts, flagged }.
#   - Exit 0 always; the artifact's summary.status carries OK/WARN/BLOCKED.
set -e

cat <<'JSON'
{
  "counts": { "total": 0, "permissive": 0, "weak_copyleft": 0, "strong_copyleft": 0, "unknown": 0 },
  "flagged": [],
  "_placeholder": "license-audit/bin/audit.sh — PR 1 stub. Real behavior lands in PR 2."
}
JSON
