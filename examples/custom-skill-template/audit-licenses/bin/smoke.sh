#!/usr/bin/env bash
# smoke.sh — Sanity check that the copied audit-licenses skill works.
#
# Runs in a tmp directory with three minimal manifests (Node, Python,
# Go) and asserts audit.sh emits parseable JSON for each. Use after
# copying the skill into your agent's skills directory:
#
#   cp -R examples/custom-skill-template/audit-licenses ~/.claude/skills/
#   ~/.claude/skills/audit-licenses/bin/smoke.sh
#
# Exit 0 on success, 1 on any failure.
set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$SKILL_DIR/bin/audit.sh"

if [ ! -x "$AUDIT" ]; then
  echo "FAIL: $AUDIT is not executable"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for the smoke check"
  exit 1
fi

tmp=$(mktemp -d /tmp/audit-smoke.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fail=0

run_case() {
  local label="$1" stack="$2"
  local out
  if ! out=$( cd "$tmp" && "$AUDIT" "$stack" 2>&1 ); then
    echo "FAIL: $label exited non-zero"
    echo "      stack: $stack"
    echo "      output: $out"
    fail=1
    return
  fi
  if ! printf '%s' "$out" | jq -e '.counts' >/dev/null 2>&1; then
    echo "FAIL: $label did not emit a JSON object with .counts"
    echo "      output: $out"
    fail=1
    return
  fi
  echo "  ok   $label"
}

# Node — minimal package.json with one dep that has a known license.
cat > "$tmp/package.json" <<'JSON_EOF'
{
  "name": "smoke",
  "dependencies": {
    "lodash": "4.17.21"
  }
}
JSON_EOF
run_case "node manifest scans" node
rm -f "$tmp/package.json"

# Python — minimal requirements.txt.
printf 'requests==2.31.0\n' > "$tmp/requirements.txt"
run_case "python manifest scans" python
rm -f "$tmp/requirements.txt"

# Go — minimal go.mod.
cat > "$tmp/go.mod" <<'GOMOD_EOF'
module smoke

go 1.21

require github.com/stretchr/testify v1.8.4
GOMOD_EOF
run_case "go manifest scans" go
rm -f "$tmp/go.mod"

if [ "$fail" -eq 0 ]; then
  echo "OK: audit-licenses smoke passed"
fi
exit $fail
