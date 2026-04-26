#!/usr/bin/env bash
# check-examples.sh — Examples Library contract enforcement.
#
# Validates every sandbox example under examples/ against the eight-
# section README contract and the structural rules from the spec:
#
#   - Each archetype directory has a README.md.
#   - Each README has the eight required H2 sections, in the exact
#     names the index promises.
#   - No em-dashes in public READMEs (matches the existing root-level
#     copy-style rule).
#   - No .nanostack/, node_modules/, *.log, or sprint artifacts
#     committed under examples/ (these are runtime, never repo).
#   - Bash files pass `bash -n`, JS files pass `node --check`.
#   - HTML files include <title> and a viewport meta tag.
#   - Each README has at least one prompt mention of /think,
#     /feature, or /nano.
#
# Skipped on purpose:
#   - examples/custom-skill-template/ — different archetype (a
#     template for extending nanostack with a custom skill, not a
#     sandbox to use it). Its own README has a different shape.
#
# Usage:
#   ci/check-examples.sh           validate every sandbox example
#   ci/check-examples.sh --filter cli-notes   only matching paths
#
# Exit code: 0 on success, 1 if any check failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FILTER=""
[ "${1:-}" = "--filter" ] && FILTER="${2:-}"

PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

# Sandbox archetypes the contract applies to. Add new ones here when
# they land; do not auto-derive from `ls examples/` because some
# directories under examples/ (custom-skill-template/) intentionally
# follow a different README shape.
ARCHETYPES=(
  starter-todo
  cli-notes
  api-healthcheck
  static-landing
)

# Exact H2 section names every sandbox README must include, in this
# order. The index in examples/README.md promises this shape; the
# CI grep locks it.
REQUIRED_SECTIONS=(
  "Who this is for"
  "What you start with"
  "First sprint"
  "Prompt to try"
  "Expected Nanostack flow"
  "Success criteria"
  "What this teaches"
  "Reset"
)

# ─── helpers ──────────────────────────────────────────────────────────

ok() {
  PASS=$((PASS+1))
  printf "    ${GREEN}OK${NC}    %s\n" "$1"
}
ng() {
  FAIL=$((FAIL+1))
  printf "    ${RED}FAIL${NC}  %s\n" "$1"
  [ -n "${2:-}" ] && printf "          ${DIM}%s${NC}\n" "$2"
}

# ─── per-example checks ──────────────────────────────────────────────

check_readme_contract() {
  local dir="$1" readme="$1/README.md"
  if [ ! -f "$readme" ]; then
    ng "$dir: missing README.md"
    return
  fi
  ok "$dir: README.md exists"

  # Eight required sections, in order. Each one must appear as a
  # top-level H2; the order check protects readers who scan top to
  # bottom.
  local last_line=0
  local i=0
  for section in "${REQUIRED_SECTIONS[@]}"; do
    local line
    line=$(grep -nE "^## ${section}\$" "$readme" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
      ng "$dir: missing H2 section '$section'"
    elif [ "$line" -le "$last_line" ]; then
      ng "$dir: H2 section '$section' is out of order (line $line, previous was $last_line)"
    else
      last_line="$line"
      i=$((i+1))
    fi
  done
  if [ "$i" -eq "${#REQUIRED_SECTIONS[@]}" ]; then
    ok "$dir: all eight sections present in order"
  fi

  # No em-dashes in the README. Matches the existing root-level
  # copy-style rule, applied per-example so a new archetype cannot
  # accidentally introduce one.
  if grep -q '—' "$readme"; then
    ng "$dir: README.md contains em-dash(es)" "$(grep -n '—' "$readme" | head -3 | sed 's/^/    /')"
  else
    ok "$dir: no em-dashes in README"
  fi

  # At least one prompt mention. The contract says every README must
  # ship a literal prompt the user can paste. Loose grep on the
  # slash-command names; specific phrasing is up to the example.
  if grep -qE "/think|/feature|/nano" "$readme"; then
    ok "$dir: README mentions /think, /feature, or /nano"
  else
    ng "$dir: README has no /think /feature /nano prompt"
  fi
}

check_no_committed_runtime_artifacts() {
  local dir="$1"
  local hits
  # Look for runtime junk that should be gitignored, never committed.
  # These are the four classes the spec called out plus the obvious
  # pkg-manager noise.
  hits=$(find "$dir" \
    -name '.nanostack' -o \
    -name 'node_modules' -o \
    -name '*.log' -o \
    -name 'package-lock.json' \
    2>/dev/null | head -5)
  if [ -z "$hits" ]; then
    ok "$dir: no runtime artifacts committed"
  else
    ng "$dir: runtime artifact(s) under examples/" "$hits"
  fi
}

check_executable_syntax() {
  local dir="$1"
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if bash -n "$f" 2>/dev/null; then
      ok "$dir: $(basename "$f") passes bash -n"
    else
      ng "$dir: $(basename "$f") bash -n failed" "$(bash -n "$f" 2>&1 | head -3)"
    fi
  done < <(find "$dir" -maxdepth 2 -name '*.sh' 2>/dev/null)

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if command -v node >/dev/null 2>&1; then
      if node --check "$f" 2>/dev/null; then
        ok "$dir: $(basename "$f") passes node --check"
      else
        ng "$dir: $(basename "$f") node --check failed" "$(node --check "$f" 2>&1 | head -3)"
      fi
    fi
  done < <(find "$dir" -maxdepth 2 -name '*.js' ! -name '*.test.js' 2>/dev/null)
}

check_html_meta() {
  local dir="$1"
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if grep -qi '<title>' "$f"; then
      ok "$dir: $(basename "$f") has <title>"
    else
      ng "$dir: $(basename "$f") missing <title>"
    fi
    if grep -qi 'viewport' "$f"; then
      ok "$dir: $(basename "$f") has viewport meta"
    else
      ng "$dir: $(basename "$f") missing viewport meta"
    fi
  done < <(find "$dir" -maxdepth 2 -name '*.html' 2>/dev/null)
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "Examples Library contract"
echo "========================="

# The library index itself must exist and link the archetypes.
echo ""
echo "[examples/README.md]"
if [ -f "$REPO/examples/README.md" ]; then
  ok "examples/README.md exists"
  if grep -q '—' "$REPO/examples/README.md"; then
    ng "examples/README.md contains em-dash(es)"
  else
    ok "examples/README.md: no em-dashes"
  fi
  for arch in "${ARCHETYPES[@]}"; do
    if grep -q "($arch/)" "$REPO/examples/README.md"; then
      ok "index links $arch"
    else
      ng "index does not link $arch (expected '($arch/)' in the table)"
    fi
  done
else
  ng "examples/README.md is missing"
fi

# Per-archetype contract.
for arch in "${ARCHETYPES[@]}"; do
  if [ -n "$FILTER" ] && ! echo "$arch" | grep -qi "$FILTER"; then
    continue
  fi
  echo ""
  echo "[examples/$arch]"
  dir="$REPO/examples/$arch"
  if [ ! -d "$dir" ]; then
    ng "examples/$arch directory missing"
    continue
  fi
  check_readme_contract            "$dir"
  check_no_committed_runtime_artifacts "$dir"
  check_executable_syntax          "$dir"
  check_html_meta                  "$dir"
done

echo ""
echo "========================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}Examples contract: $PASS checks passed, 0 failed${NC}\n"
else
  printf "${RED}Examples contract: $FAIL failed${NC} / $TOTAL total\n"
fi

[ "$FAIL" -eq 0 ]
