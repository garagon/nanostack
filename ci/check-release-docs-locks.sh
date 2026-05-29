#!/usr/bin/env bash
# check-release-docs-locks.sh — release-surface doc locks.
#
# Spec release-readme-site-refresh-2026-05-29 (PR 3). The README narrative
# locks (ci/check-readme-narrative-locks.sh) already cover README.md and
# README.es.md. This script locks the rest of the release surface that the
# refresh round touched — RELEASE_NOTES.md, EXTENDING.md, llms.txt, AGENTS.md —
# so the same accuracy holds there and the published version cannot drift away
# from the VERSION file.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

# 1. The release-surface files must exist.
for f in RELEASE_NOTES.md EXTENDING.md llms.txt AGENTS.md; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required release-surface file missing: $f"
    fail=1
  fi
done

# 2. Version currency: the top version heading in RELEASE_NOTES.md must match
#    the VERSION file. A published release cannot advertise a stale version.
ver=$(tr -d '[:space:]' < VERSION 2>/dev/null)
notes_ver=$(grep -m1 -E '^## v[0-9]+\.[0-9]+\.[0-9]+' RELEASE_NOTES.md 2>/dev/null \
  | sed -E 's/^## v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
if [ -z "$notes_ver" ]; then
  echo "FAIL: RELEASE_NOTES.md has no '## vMAJOR.MINOR.PATCH' version heading"
  fail=1
elif [ "$ver" != "$notes_ver" ]; then
  echo "FAIL: VERSION ($ver) does not match newest RELEASE_NOTES heading (v$notes_ver)"
  fail=1
fi

# 3. RELEASE_NOTES.md required tokens: every verified adapter on one line,
#    plus the round's headline capabilities and the honest enforcement framing.
for tok in \
  'Claude Code' \
  'Cursor' \
  'OpenAI Codex' \
  'OpenCode' \
  'Gemini CLI' \
  'workflow stack' \
  'Visual artifacts' \
  'host-dependent' \
  'workflow_dispatch'; do
  if ! grep -qF -- "$tok" RELEASE_NOTES.md; then
    echo "FAIL: RELEASE_NOTES.md missing required token: $tok"
    fail=1
  fi
done

# 4. EXTENDING.md required tokens: the scaffold path, the --from flag, and the
#    contributor harness runner must stay documented.
for tok in \
  'bin/create-skill.sh' \
  '--from' \
  'ci/run-harness.sh --all'; do
  if ! grep -qF -- "$tok" EXTENDING.md; then
    echo "FAIL: EXTENDING.md missing required token: $tok"
    fail=1
  fi
done

# 4b. Agent-facing surfaces (llms.txt, AGENTS.md) must keep listing every
#     verified adapter and the headline capabilities. These files are the
#     machine-readable face of the release, so a regression here is as bad as
#     one in the human docs. Tokens chosen as case-sensitive substrings that
#     match the wording in both files.
for f in llms.txt AGENTS.md; do
  for tok in \
    'Claude Code' \
    'Cursor' \
    'OpenAI Codex' \
    'OpenCode' \
    'Gemini CLI' \
    'workflow stack' \
    'Visual artifacts'; do
    if ! grep -qF -- "$tok" "$f"; then
      echo "FAIL: $f missing required token: $tok"
      fail=1
    fi
  done
done

# 5. Forbidden phrases (case-insensitive literal substring) must NOT appear in
#    the release surface not already covered by the README narrative locks.
FILES="RELEASE_NOTES.md EXTENDING.md llms.txt AGENTS.md"
# This is the README narrative lock's forbidden set (so the same regressions
# are caught outside the READMEs) plus this round's additions (agent-count and
# rule-count claims).
for bad in \
  'npx create-nanostack install' \
  'on every workflow run' \
  'every workflow run' \
  '4 commands' \
  'cuatro comandos' \
  'zero dependencies' \
  'cero dependencias' \
  'works in every agent identically' \
  '8 agents' \
  'eight agents' \
  '33 rules' \
  '33 block rules' \
  'marketplace' \
  'plugin ecosystem' \
  'GDPR ready' \
  'SOC2 ready' \
  'compliance certified' \
  'full engineering team'; do
  hits=$(grep -niF -- "$bad" $FILES 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "FAIL: forbidden phrase '$bad' present (case-insensitive):"
    echo "$hits"
    fail=1
  fi
done

# 6. Forbidden agent names (bare-word boundary, case-insensitive).
for name in 'Amp' 'Cline' 'Antigravity'; do
  hits=$(grep -niE "\\b${name}\\b" $FILES 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "FAIL: forbidden agent name '$name' (bare word, case-insensitive) present:"
    echo "$hits"
    fail=1
  fi
done

# 7. Sprint-order arrow must NOT show /qa before /security anywhere in the set.
if grep -nE '/qa[[:space:]]*(->|→)[[:space:]]*/security' $FILES; then
  echo "FAIL: release surface contains /qa -> /security arrow (canonical order is /security -> /qa)"
  fail=1
fi

# 8. Spanish typo guard: the correct word is "Artefactos", not "Artifactos".
if grep -niw 'Artifactos' README.es.md TROUBLESHOOTING.es.md 2>/dev/null; then
  echo "FAIL: README.es.md/TROUBLESHOOTING.es.md uses 'Artifactos' (correct: 'Artefactos')"
  fail=1
fi

exit $fail
