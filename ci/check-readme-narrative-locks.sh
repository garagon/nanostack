#!/usr/bin/env bash
# check-readme-narrative-locks.sh — README narrative claim locks.
#
# Extracted verbatim from the lint.yml `readme-narrative-locks` job (Harness
# Architecture vNext PR 6). Same checks, same enforcement.
#
# Spec readme-product-narrative-refresh-2026-04-26: locks the "default
# sprint + framework for workflow stacks" claim surface so later edits do
# not drift back to older wording or reintroduce disallowed phrases
# (Amp/Cline/Antigravity, "4 commands", "every workflow run", etc.).
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

# New required tokens in README.md: every verified-adapter name must appear
# by itself, plus the opt-in E2E framing.
for tok in \
  'opt-in E2E workflow' \
  'Verified adapters' \
  'Claude Code' \
  'Cursor' \
  'OpenAI Codex' \
  'OpenCode' \
  'Gemini CLI'; do
  if ! grep -qF "$tok" README.md; then
    echo "FAIL: README.md missing required token: $tok"
    fail=1
  fi
done

# Spanish README declares the same E2E opt-in framing.
if ! grep -qE 'E2E opt-in|workflow E2E opt-in' README.es.md; then
  echo "FAIL: README.es.md does not declare E2E opt-in framing"
  fail=1
fi

# Forbidden phrases (case-insensitive literal substring) must NOT appear.
for bad in \
  'npx create-nanostack install' \
  'on every workflow run' \
  'every workflow run' \
  '4 commands' \
  'cuatro comandos' \
  'zero dependencies' \
  'cero dependencias' \
  'marketplace' \
  'plugin ecosystem' \
  'GDPR ready' \
  'SOC2 ready' \
  'compliance certified' \
  'works in every agent identically' \
  'full engineering team'; do
  hits=$(grep -niF "$bad" README.md README.es.md 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "FAIL: forbidden phrase '$bad' present (case-insensitive):"
    echo "$hits"
    fail=1
  fi
done

# Forbidden agent names (bare-word boundary, case-insensitive) must NOT appear.
for name in 'Amp' 'Cline' 'Antigravity'; do
  hits=$(grep -niE "\\b${name}\\b" README.md README.es.md 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "FAIL: forbidden agent name '$name' (bare word, case-insensitive) present:"
    echo "$hits"
    fail=1
  fi
done

# Sprint-order arrow must NOT show /qa before /security.
if grep -nE '/qa[[:space:]]*(->|→)[[:space:]]*/security' README.md README.es.md; then
  echo "FAIL: README contains /qa -> /security arrow form (canonical order is /security -> /qa)"
  fail=1
fi

exit $fail
