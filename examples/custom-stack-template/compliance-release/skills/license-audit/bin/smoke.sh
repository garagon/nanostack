#!/usr/bin/env bash
# smoke.sh — license-audit runtime sanity check.
#
# Sets up three minimal projects in /tmp (Node with one MIT dep
# installed under node_modules/, Python with a single requirements.txt
# entry, Go with a single go.mod require). Asserts:
#   1. Stack auto-detection picks the right manifest in each case.
#   2. The Node case classifies an MIT dep as permissive (read from
#      node_modules/<dep>/package.json).
#   3. Python and Go cases classify their unknown-license deps as
#      `unknown` (the helper has no way to know without a deeper
#      auditor).
#   4. A GPL dep installed under node_modules/ classifies as
#      strong_copyleft and lands in `flagged`.
set -eu

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

tmp=$(mktemp -d /tmp/license-audit-smoke.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fail=0

# ─── Case 1: Node + permissive MIT dep installed ────────────
mkdir -p "$tmp/node-permissive/node_modules/lodash"
cat > "$tmp/node-permissive/package.json" <<'PKG'
{ "name": "smoke-node", "dependencies": { "lodash": "4.17.21" } }
PKG
cat > "$tmp/node-permissive/node_modules/lodash/package.json" <<'PKG'
{ "name": "lodash", "version": "4.17.21", "license": "MIT" }
PKG
out=$( cd "$tmp/node-permissive" && "$AUDIT" 2>&1 )
if echo "$out" | jq -e '.stack == "node" and .counts.permissive == 1 and .counts.strong_copyleft == 0' >/dev/null 2>&1; then
  echo "  ok    node MIT dep classifies as permissive"
else
  echo "FAIL: node MIT case wrong"
  echo "$out"
  fail=1
fi

# ─── Case 2: Node + GPL dep installed ───────────────────────
mkdir -p "$tmp/node-gpl/node_modules/some-gpl-thing"
cat > "$tmp/node-gpl/package.json" <<'PKG'
{ "name": "smoke-gpl", "dependencies": { "some-gpl-thing": "1.0.0" } }
PKG
cat > "$tmp/node-gpl/node_modules/some-gpl-thing/package.json" <<'PKG'
{ "name": "some-gpl-thing", "version": "1.0.0", "license": "GPL-3.0" }
PKG
out=$( cd "$tmp/node-gpl" && "$AUDIT" 2>&1 )
if echo "$out" | jq -e '.counts.strong_copyleft == 1 and (.flagged | length) == 1 and .flagged[0].name == "some-gpl-thing"' >/dev/null 2>&1; then
  echo "  ok    GPL dep classifies as strong_copyleft and lands in flagged"
else
  echo "FAIL: node GPL case wrong"
  echo "$out"
  fail=1
fi

# ─── Case 3: Python requirements.txt ────────────────────────
printf 'requests==2.31.0\nflask>=2.0\n' > "$tmp/py-req.txt"
mkdir -p "$tmp/python-req"
cp "$tmp/py-req.txt" "$tmp/python-req/requirements.txt"
out=$( cd "$tmp/python-req" && "$AUDIT" 2>&1 )
if echo "$out" | jq -e '.stack == "python" and .counts.unknown >= 2' >/dev/null 2>&1; then
  echo "  ok    python requirements.txt deps classify as unknown"
else
  echo "FAIL: python case wrong"
  echo "$out"
  fail=1
fi

# ─── Case 4: Go go.mod ──────────────────────────────────────
mkdir -p "$tmp/go-mod"
cat > "$tmp/go-mod/go.mod" <<'GOMOD'
module smoke

go 1.21

require (
	github.com/stretchr/testify v1.8.4
	github.com/spf13/cobra v1.7.0
)
GOMOD
out=$( cd "$tmp/go-mod" && "$AUDIT" 2>&1 )
if echo "$out" | jq -e '.stack == "go" and .counts.total >= 2 and .counts.unknown >= 2' >/dev/null 2>&1; then
  echo "  ok    go module deps classify as unknown"
else
  echo "FAIL: go case wrong"
  echo "$out"
  fail=1
fi

# ─── Case 5: No manifest in cwd ─────────────────────────────
mkdir -p "$tmp/empty"
out=$( cd "$tmp/empty" && "$AUDIT" 2>&1 )
if echo "$out" | jq -e '.stack == "none" and .counts.total == 0' >/dev/null 2>&1; then
  echo "  ok    empty project classifies as stack=none with zero counts"
else
  echo "FAIL: empty case wrong"
  echo "$out"
  fail=1
fi

# ─── Case 6: Go single-line require form ────────────────────
# A common minimal go.mod uses `require <module> <version>` without
# a require block. The original scanner only matched indented entries
# inside `require (...)`, dropping single-line deps silently.
mkdir -p "$tmp/go-single"
cat > "$tmp/go-single/go.mod" <<'GOMOD'
module smoke

go 1.21

require github.com/spf13/cobra v1.8.0
GOMOD
out=$( cd "$tmp/go-single" && "$AUDIT" 2>&1 )
if echo "$out" | jq -e '.stack == "go" and .counts.total == 1 and .counts.unknown == 1' >/dev/null 2>&1; then
  echo "  ok    go single-line require captures the dep"
else
  echo "FAIL: go single-line case wrong (counts.total should be 1)"
  echo "$out"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: license-audit smoke passed (6 cases)"
fi
exit $fail
