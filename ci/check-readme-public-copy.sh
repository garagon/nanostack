#!/usr/bin/env bash
# check-readme-public-copy.sh — README public-copy regression lock.
#
# Extracted verbatim from the lint.yml `readme-public-copy` job (Harness
# Architecture vNext PR 6) so the contract is a reusable, readable script
# instead of a long inline workflow block. Same checks, same enforcement.
#
# Spec public-copy-regression-locks-2026-04-26: stale claims have bitten
# this repo before, so this asserts the called-out stale strings are gone
# and the required v1.0 / Examples-Library / telemetry framing is present.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

# Stale strings must NOT appear in README.md or README.es.md. Each is one
# quoted argument so spaces inside do not split.
for stale in \
  'Under 15 minutes' \
  'Four tiers' \
  'endpoint lands in a later PR' \
  'Claude does the rest' \
  'se ships' \
  'Ship el puntito' \
  'Nothing leaves unless you opt in' \
  'post-deploy canary' \
  'Post-deploy: smoke test clean' \
  'Four commands' \
  'Six commands, start to shipped' \
  'That is not a copilot' \
  'Zero dependencies. Zero build step' \
  'Antigravity, Amp, and Cline' \
  'Antigravity, Amp, or Cline' \
  'Antigravity, Amp y Cline' \
  'Antigravity, Amp, Cline'; do
  if grep -nF "$stale" README.md README.es.md 2>/dev/null; then
    echo "FAIL: stale string present: $stale"
    fail=1
  fi
done

# Required strings MUST appear in README.md.
for required in \
  '13 built-in skills' \
  'seven-phase default sprint' \
  'build your own workflow stack' \
  'Examples Library' \
  'starter-todo' \
  'cli-notes' \
  'api-healthcheck' \
  'static-landing' \
  'delivery workflow' \
  'What changes after installing Nanostack' \
  'No Nanostack cloud' \
  'Production deployment stays explicit'; do
  if ! grep -qF "$required" README.md; then
    echo "FAIL: required string missing in README.md: $required"
    fail=1
  fi
done

# Required strings MUST appear in README.es.md.
for required in \
  'starter-todo' \
  'cli-notes' \
  'api-healthcheck' \
  'static-landing' \
  'telemetría' \
  'Privacidad'; do
  if ! grep -qF "$required" README.es.md; then
    echo "FAIL: required string missing in README.es.md: $required"
    fail=1
  fi
done

exit $fail
