#!/usr/bin/env bash
# check-visual-artifact-public-copy.sh — visual artifact public-copy locks.
#
# Extracted verbatim from the lint.yml `visual-artifact-public-copy` job
# (Harness Architecture vNext PR 6). Same checks, same enforcement.
#
# Locks the PR 5 public framing: visual artifacts are inspectable local
# evidence (JSON canonical, HTML derived), no cloud/SaaS/certification
# language near any renderer mention, every public surface acknowledges
# the renderer, custom-phase wording is precise, and the --help text
# matches the store-first stack lookup contract.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

# 1. Public copy is locally-framed and modest.
FILES=(README.md README.es.md llms.txt AGENTS.md reference/visual-artifact-contract.md)
BAD_WORDS='cloud viewer|hosted viewer|SaaS viewer|cloud dashboard|cloud render|cloud-rendered|cloud-based viewer|attestation|certified release|enterprise[- ]grade'
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  window=$(grep -niE -A10 -B2 'render-artifact|visual artifact|\.nanostack/visual' "$f" 2>/dev/null || true)
  [ -z "$window" ] && continue
  if printf '%s\n' "$window" | grep -niE -- "$BAD_WORDS" >/dev/null 2>&1; then
    echo "FAIL: $f has a banned framing word in a visual-artifact paragraph."
    printf '%s\n' "$window" | grep -niE -- "$BAD_WORDS"
    fail=1
  fi
done

# 2. Visual artifact section present in public surfaces.
for pair in \
    "README.md|render-artifact" \
    "README.es.md|render-artifact" \
    "llms.txt|render-artifact" \
    "AGENTS.md|render-artifact" \
    "reference/visual-artifact-contract.md|render-artifact"; do
  file="${pair%|*}"
  needle="${pair#*|}"
  if ! grep -qF "$needle" "$file"; then
    echo "FAIL: $file does not mention $needle. Update the public copy when PR 5 framing changes."
    fail=1
  fi
done

# 3. Custom phase wording is precise, not 'any artifact'.
EN_FILES=(README.md AGENTS.md llms.txt bin/about.sh)
ES_FILES=(README.es.md)
FORBIDDEN='any artifact|any phase artifact'
for f in "${EN_FILES[@]}" "${ES_FILES[@]}"; do
  [ -f "$f" ] || continue
  window=$(grep -niE -A10 -B2 'render-artifact|visual artifact|\.nanostack/visual' "$f" 2>/dev/null || true)
  [ -z "$window" ] && continue
  if printf '%s\n' "$window" | grep -niE -- "$FORBIDDEN" >/dev/null 2>&1; then
    echo "FAIL: $f still uses vague 'any artifact' wording near a renderer mention."
    printf '%s\n' "$window" | grep -niE -- "$FORBIDDEN"
    fail=1
  fi
done
for f in "${EN_FILES[@]}"; do
  [ -f "$f" ] || continue
  if ! grep -qE -i 'core and registered custom phase' "$f"; then
    echo "FAIL: $f does not include the precise EN wording 'core and registered custom phase'."
    fail=1
  fi
done
for f in "${ES_FILES[@]}"; do
  [ -f "$f" ] || continue
  if ! grep -qE -i 'fases core y custom registradas' "$f"; then
    echo "FAIL: $f does not include the precise ES wording 'fases core y custom registradas'."
    fail=1
  fi
done

# 4. --help text matches store-first stack lookup.
if ! grep -qF '$NANOSTACK_STORE/stacks/<name>/stack.json' bin/render-artifact.sh; then
  echo "FAIL: bin/render-artifact.sh --help does not mention the store-first stack lookup path."
  fail=1
fi
if ! grep -qF 'examples/custom-stack-template' bin/render-artifact.sh; then
  echo "FAIL: bin/render-artifact.sh --help does not mention the bundled-example fallback."
  fail=1
fi
if ! grep -qF 'stack default' bin/render-artifact.sh; then
  echo "FAIL: bin/render-artifact.sh --help does not mention the 'stack default' form."
  fail=1
fi
if grep -qE 'positional arg.*looked up in .nanostack/config.json' bin/render-artifact.sh; then
  echo "FAIL: bin/render-artifact.sh --help still describes the old stack lookup model."
  grep -nE 'positional arg.*looked up in .nanostack/config.json' bin/render-artifact.sh
  fail=1
fi

exit $fail
