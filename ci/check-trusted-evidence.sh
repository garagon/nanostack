#!/usr/bin/env bash
# check-trusted-evidence.sh — gates and context loaders use verified artifacts.
#
# Phase artifacts carry a SHA-256 .integrity field. This check confirms that:
#  - the /feature commit gate treats a tampered artifact as missing, and still
#    passes when the evidence is intact;
#  - restore-context skips a tampered artifact and keeps a valid one;
#  - conductor "complete --artifact" only links a real JSON file that lives
#    inside the store or project (no symlink, no non-JSON, no outside path).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
# Keep the run hermetic: point HOME at the temp workspace so a developer's
# global ~/.nanostack/config.json (with a custom phase_graph) cannot change the
# default sprint phases this check claims and completes.
export HOME="$WORK"
cd "$WORK"
git init -q >/dev/null 2>&1
git config user.email t@example.com >/dev/null 2>&1
git config user.name test >/dev/null 2>&1
export NANOSTACK_STORE="$WORK/.nanostack"
mkdir -p "$NANOSTACK_STORE"
echo "console.log(1)" > app.js
git add -A >/dev/null 2>&1
git commit -qm init >/dev/null 2>&1
PROJECT="$WORK"

fail=0
ck() { if [ "$1" = "$2" ]; then printf '  ok   %s\n' "$3"; else printf '  FAIL %s (got %s, want %s)\n' "$3" "$2" "$1"; fail=1; fi; }
hash_of() { (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1; }

# Use a current artifact filename and timestamp (matching how save-artifact.sh
# names files) so the gate counts the evidence on its own merits, not because of
# an mtime nudge on an old fixed name.
TS=$(date -u +%Y%m%d-%H%M%S)
ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Write a signed phase artifact (integrity over canonical JSON without .integrity).
sign() {
  local phase="$1" dir="$NANOSTACK_STORE/$1" f h
  mkdir -p "$dir"
  f="$dir/$TS.json"
  jq -nc --arg p "$PROJECT" --arg ph "$phase" --arg ts "$ISO" \
    '{phase:$ph, project:$p, timestamp:$ts, summary:{blocking:0}, context_checkpoint:{summary:("did "+$ph)}}' > "$f"
  h=$(jq -Sc 'del(.integrity)' "$f" | hash_of)
  jq --arg h "$h" '.integrity=$h' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
tamper() { local f="$NANOSTACK_STORE/$1/$TS.json"; jq '.summary.blocking=99' "$f" > "$f.t" && mv "$f.t" "$f"; }

for p in plan review security qa; do sign "$p"; done

# Already in $WORK (cd above). Call helpers directly so the conductor's
# per-process agent identity (derived from the parent shell) stays the same
# across claim and complete; wrapping each call in its own subshell would make
# claim and complete look like different agents.

# /feature commit gate: passes on intact evidence, blocks on tampered evidence.
"$ROOT/feature/bin/enforce-sprint.sh" "git commit -m x" >/dev/null 2>&1
ck 0 $? "feature gate passes when all evidence is intact"
tamper review
"$ROOT/feature/bin/enforce-sprint.sh" "git commit -m x" >/dev/null 2>&1
ck 1 $? "feature gate blocks a commit when an artifact is tampered"

# restore-context skips the tampered artifact, keeps the valid ones.
OUT=$("$ROOT/bin/restore-context.sh" 2>/dev/null)
if printf '%s' "$OUT" | grep -q 'did review'; then
  ck reject keep "restore-context omits the tampered review artifact"
else
  ck reject reject "restore-context omits the tampered review artifact"
fi
if printf '%s' "$OUT" | grep -q 'did plan'; then
  ck keep keep "restore-context keeps an intact artifact"
else
  ck keep reject "restore-context keeps an intact artifact"
fi

# conductor complete --artifact only links a real in-scope JSON file.
"$ROOT/conductor/bin/sprint.sh" start >/dev/null 2>&1
"$ROOT/conductor/bin/sprint.sh" claim think >/dev/null 2>&1
echo '{"ok":true}' > "$NANOSTACK_STORE/good.json"
"$ROOT/conductor/bin/sprint.sh" complete think --artifact "$NANOSTACK_STORE/good.json" >/dev/null 2>&1
ck 0 $? "complete accepts a real JSON file inside the store"
"$ROOT/conductor/bin/sprint.sh" claim plan >/dev/null 2>&1
ln -s /etc/hosts "$NANOSTACK_STORE/link.json"
"$ROOT/conductor/bin/sprint.sh" complete plan --artifact "$NANOSTACK_STORE/link.json" >/dev/null 2>&1
ck 1 $? "complete refuses a symlink artifact"
# A rejected artifact must not mark the phase done (which would unblock
# dependent phases without trusted evidence).
if find "$NANOSTACK_STORE/conductor" -path '*/plan/done' 2>/dev/null | grep -q .; then
  ck nodone done "complete leaves the phase not-done when the artifact is rejected"
else
  ck nodone nodone "complete leaves the phase not-done when the artifact is rejected"
fi
echo "not json" > "$NANOSTACK_STORE/bad.json"
"$ROOT/conductor/bin/sprint.sh" complete plan --artifact "$NANOSTACK_STORE/bad.json" >/dev/null 2>&1
ck 1 $? "complete refuses a non-JSON artifact"
OUTSIDE="$(mktemp)"; echo '{"x":1}' > "$OUTSIDE"
"$ROOT/conductor/bin/sprint.sh" complete plan --artifact "$OUTSIDE" >/dev/null 2>&1
ck 1 $? "complete refuses a file outside the store or project"
# A path that lexically starts under the store but resolves outside it (here via
# a symlinked directory in the path) must also be refused: the prefix check runs
# on the canonical path, not the lexical one.
EXT="$(mktemp -d)"; echo '{"x":1}' > "$EXT/x.json"
ln -s "$EXT" "$NANOSTACK_STORE/linkdir"
"$ROOT/conductor/bin/sprint.sh" complete plan --artifact "$NANOSTACK_STORE/linkdir/x.json" >/dev/null 2>&1
ck 1 $? "complete refuses a path that resolves outside via a symlinked directory"
# A real JSON file under the project (but not under the store) is also accepted,
# so the "store or project" boundary is covered on both sides.
echo '{"ok":true}' > "$WORK/project-artifact.json"
"$ROOT/conductor/bin/sprint.sh" complete plan --artifact "$WORK/project-artifact.json" >/dev/null 2>&1
ck 0 $? "complete accepts a real JSON file under the project"

if [ "$fail" -ne 0 ]; then
  echo "check-trusted-evidence: FAIL"
  exit 1
fi
echo "check-trusted-evidence: OK"
