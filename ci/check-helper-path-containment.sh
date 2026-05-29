#!/usr/bin/env bash
# check-helper-path-containment.sh — helper scripts stay within their folders.
#
# A few helpers build a filesystem path from a value they do not fully control:
# a session_id read from session.json, a phase argument passed to the conductor,
# the --phase / --date selectors of discard-sprint, and the screenshot name.
# This check confirms each helper keeps its writes and deletes inside the folder
# it manages, and still accepts ordinary inputs. Each negative case is set up so
# it fails specifically when the guard is missing, not for an unrelated reason.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NANOSTACK_STORE="$(mktemp -d)/store"
mkdir -p "$NANOSTACK_STORE"

fail=0
pass() { printf '  ok   %s\n' "$1"; }
miss() { printf '  FAIL %s\n' "$1"; fail=1; }

# ── session.sh archive ──────────────────────────────────────────────────────
# A session_id of "../escaped" would, without sanitizing, send the archive to
# $STORE/escaped.json (one level above the sessions/ folder). After the fix it
# lands inside sessions/ as a plain name.
printf '{"session_id":"../escaped","status":"active"}\n' > "$NANOSTACK_STORE/session.json"
bash "$ROOT/bin/session.sh" archive >/dev/null 2>&1
if [ -e "$NANOSTACK_STORE/escaped.json" ]; then
  miss "session.sh archive escaped sessions/ (wrote $NANOSTACK_STORE/escaped.json)"
elif [ -e "$NANOSTACK_STORE/sessions/escaped.json" ]; then
  pass "session.sh archive stays in sessions/"
else
  miss "session.sh archive produced no archive file"
fi

# ── conductor sprint.sh ─────────────────────────────────────────────────────
# Start a real sprint so find_sprint succeeds; then a path-like phase must be
# refused by the guard (specific message), while a real phase is accepted.
( cd "$ROOT" && bash conductor/bin/sprint.sh start >/dev/null 2>&1 ) || true
for cmd in abort unstuck; do
  out=$(cd "$ROOT" && bash conductor/bin/sprint.sh "$cmd" "../../escaped" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "invalid phase"; then
    pass "sprint.sh $cmd refuses a path-like phase"
  else
    miss "sprint.sh $cmd did not refuse a path-like phase (rc=$rc)"
  fi
done
if ( cd "$ROOT" && bash conductor/bin/sprint.sh abort "review" >/dev/null 2>&1 ); then
  pass "sprint.sh abort still accepts a real phase"
else
  miss "sprint.sh abort rejected a real phase"
fi

# ── discard-sprint.sh ───────────────────────────────────────────────────────
# A path-like phase must be refused. Quote each argument so the wildcard date
# below reaches discard-sprint literally (an unquoted "*" would glob to repo
# files first and be rejected for the wrong reason).
if ( cd "$ROOT" && bash bin/discard-sprint.sh --phase "../../escaped" --dry-run >/dev/null 2>&1 ); then
  miss "discard-sprint accepted '--phase ../../escaped'"
else
  pass "discard-sprint refuses '--phase ../../escaped'"
fi
if ( cd "$ROOT" && bash bin/discard-sprint.sh --date "*" --dry-run >/dev/null 2>&1 ); then
  miss "discard-sprint accepted a wildcard date"
else
  pass "discard-sprint refuses a wildcard date"
fi
# A multiline phase must be refused before it can split into a path.
if ( cd "$ROOT" && bash bin/discard-sprint.sh --phase "$(printf 'review\n../outside')" --dry-run >/dev/null 2>&1 ); then
  miss "discard-sprint accepted a multiline phase"
else
  pass "discard-sprint refuses a multiline phase"
fi
if ( cd "$ROOT" && bash bin/discard-sprint.sh --phase review --dry-run >/dev/null 2>&1 ); then
  pass "discard-sprint still accepts a registered phase"
else
  miss "discard-sprint rejected a registered phase"
fi
if ( cd "$ROOT" && bash bin/discard-sprint.sh --date 2026-03-24 --dry-run >/dev/null 2>&1 ); then
  pass "discard-sprint still accepts a YYYY-MM-DD date"
else
  miss "discard-sprint rejected a valid date"
fi

# ── screenshot.sh ───────────────────────────────────────────────────────────
# A path-like name must be refused by the guard message, before the browser is
# launched, so the result cannot land outside results/.
out=$(bash "$ROOT/qa/bin/screenshot.sh" "../../escaped" "http://localhost" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "invalid screenshot name"; then
  pass "screenshot.sh refuses a path-like name"
else
  miss "screenshot.sh did not refuse a path-like name (rc=$rc)"
fi

# Clean up any sprint state this check created under the temp store.
rm -rf "$NANOSTACK_STORE/conductor" 2>/dev/null || true

if [ "$fail" -ne 0 ]; then
  echo "check-helper-path-containment: FAIL"
  exit 1
fi
echo "check-helper-path-containment: OK"
