#!/usr/bin/env bash
# check-policy-contract.sh — guard policy ordering and honest freeze wording.
#
# #8: the global gates (phase concurrency, sprint phase gate, budget gate) must
# run before the allowlist short-circuit and the in-project fast-path, so a
# safe-listed or in-project command cannot skip them. This is checked through
# the budget gate: a non-allowlisted in-project write is blocked when over
# budget, while an allowlisted safe read stays allowed (the documented
# save-your-work exemption).
# #9: the docs describe /freeze as a guided instruction, not a hook-enforced
# block, since no hook enforces it today.
#
# Scope boundary (accepted): the budget read exemption rejects the command-line
# vectors that turn a git read into command execution, but it does not defend
# against a repository whose own git config runs helper programs (diff.external,
# textconv, core.fsmonitor, filters, hooks). Those run on any git command with or
# without the gate, so the budget gate is a cost cap, not a sandbox. The wording
# lock below keeps the public docs from over-promising a git sandbox.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
pass() { printf '  ok   %s\n' "$1"; }
miss() { printf '  FAIL %s\n' "$1"; fail=1; }

GUARD="$ROOT/guard/bin/check-dangerous.sh"

# ── #8 budget gate is reached past the allowlist / in-project fast-paths ─────
WORK="$(mktemp -d)"
export HOME="$WORK"
export NANOSTACK_STORE="$WORK/.nanostack"
mkdir -p "$NANOSTACK_STORE"
( cd "$WORK" && git init -q && git config user.email t@example.com && git config user.name test \
  && echo "x" > app.js && git add -A && git commit -qm init ) >/dev/null 2>&1
# Active session with a tiny budget already over the limit.
jq -n '{status:"active",budget:{max_usd:0.01,model:"sonnet-4",tokens_input:100000000,tokens_output:100000000}}' \
  > "$NANOSTACK_STORE/session.json"

run() { ( cd "$WORK" && "$GUARD" "$1" >/dev/null 2>&1 ); echo $?; }

if [ "$(run 'touch ./newfile.txt')" = "1" ]; then
  pass "in-project write is blocked by the budget gate when over budget"
else
  miss "in-project write skipped the budget gate (over budget)"
fi
if [ "$(run 'cp app.js ./copy.js')" = "1" ]; then
  pass "in-project copy is blocked by the budget gate when over budget"
else
  miss "in-project copy skipped the budget gate (over budget)"
fi
# A wrapper command (env, xargs, timeout, ...) runs another program, so an
# allowlisted wrapper must not exempt the wrapped command from the gates.
if [ "$(run 'env git commit -m x')" = "1" ] && [ "$(run 'env FOO=bar touch ./x')" = "1" ]; then
  pass "an allowlisted wrapper does not exempt the wrapped command from the budget gate"
else
  miss "a wrapped command rode past the budget gate behind an allowlisted wrapper"
fi
# find can execute commands (-exec/-ok) or delete/write (-delete/-fprint), so an
# allowlisted find with such an action is not a read and must go through the gates.
if [ "$(run 'find . -exec git commit -m x {} +')" = "1" ] && [ "$(run 'find . -delete')" = "1" ]; then
  pass "find -exec / -delete go through the budget gate, not exempted as a read"
else
  miss "a find action (-exec/-delete) rode past the budget gate as a read"
fi
# Plain find searches stay allowed as reads.
if [ "$(run 'find . -type f')" = "0" ]; then
  pass "a plain find search stays allowed when over budget"
else
  miss "a plain find search was blocked when over budget"
fi
if [ "$(run 'ls -la')" = "0" ]; then
  pass "an allowlisted read stays allowed when over budget (save-work exemption)"
else
  miss "an allowlisted read was blocked when over budget"
fi
if [ "$(run 'git status')" = "0" ]; then
  pass "git status stays allowed when over budget"
else
  miss "git status was blocked when over budget"
fi
# A path-prefixed invocation of an allowlisted read resolves the same way, so it
# is not blocked by the budget wall just because it was called by full path.
if [ "$(run '/usr/bin/git status')" = "0" ] && [ "$(run '/usr/bin/git diff ./app.js')" = "0" ]; then
  pass "a path-prefixed allowlisted read (e.g. /usr/bin/git status) stays allowed when over budget"
else
  miss "a path-prefixed allowlisted read was blocked when over budget"
fi
# git read subcommands stay allowed even with global options before the
# subcommand, so inspection still works behind the budget wall.
if [ "$(run 'git -C . diff -- ./app.js')" = "0" ] && [ "$(run 'git --no-pager status')" = "0" ] \
   && [ "$(run 'git branch')" = "0" ]; then
  pass "git reads with global options (and bare git branch list) stay allowed when over budget"
else
  miss "a git read with global options was blocked when over budget"
fi
# But mutating git forms are not reads: git branch <name> / -m / -d create or
# change refs and must not ride the save-work exemption past the budget wall.
if [ "$(run 'git branch new-topic')" = "1" ] && [ "$(run 'git branch -m old new')" = "1" ] \
   && [ "$(run 'git branch -D old')" = "1" ]; then
  pass "mutating git branch forms are gated by the budget wall, not exempted as reads"
else
  miss "a mutating git branch form rode past the budget wall as an allowlisted read"
fi
# But read-only branch list/filter modes take a positional pattern or commit and
# stay available for inspection behind the wall.
if [ "$(run 'git branch --list feature/*')" = "0" ] && [ "$(run 'git branch --contains HEAD')" = "0" ] \
   && [ "$(run 'git branch --merged main')" = "0" ]; then
  pass "read-only git branch list/filter modes stay allowed when over budget"
else
  miss "a read-only git branch list/filter mode was blocked when over budget"
fi
# Output modifiers (--sort/--format) do not make a positional a filter: git still
# creates the named branch, so these stay gated.
if [ "$(run 'git branch --sort=refname scratch')" = "1" ] \
   && [ "$(run "git branch --format=%(refname) scratch")" = "1" ] \
   && [ "$(run 'git branch --sort refname scratch')" = "1" ]; then
  pass "git branch with --sort/--format plus a new name is gated as a create, not a read"
else
  miss "git branch --sort/--format with a new name was exempted as a read"
fi
# Other write-producing git forms are not reads either: --output writes a file,
# and a mutating subcommand after `remote -v` changes config.
if [ "$(run 'git diff --output=out')" = "1" ] && [ "$(run 'git show --output=out')" = "1" ] \
   && [ "$(run 'git remote -v remove origin')" = "1" ] \
   && [ "$(run 'git remote -v set-url origin url')" = "1" ]; then
  pass "write-producing git forms (--output, remote mutation) are gated, not exempted as reads"
else
  miss "a write-producing git form rode past the budget wall as an allowlisted read"
fi
# git fetch does network I/O, writes refs, and can run helper programs even with
# --dry-run (--upload-pack), so no fetch form is exempted as a read.
if [ "$(run 'git fetch')" = "1" ] && [ "$(run 'git fetch origin')" = "1" ] \
   && [ "$(run 'git fetch --dry-run')" = "1" ] \
   && [ "$(run 'git fetch --dry-run --upload-pack=/tmp/evil /repo')" = "1" ]; then
  pass "git fetch (including --dry-run) is gated by the budget wall, not exempted as a read"
else
  miss "git fetch was exempted from the budget wall as a read"
fi
# A git read that injects config or an external helper can execute a command, so
# it is not a safe read: -c (config injection), --ext-diff, and --exec-path= are
# all gated rather than exempted.
if [ "$(run 'git -c diff.external=evilcmd diff')" = "1" ] \
   && [ "$(run 'git diff --ext-diff')" = "1" ] \
   && [ "$(run 'git --exec-path=/evil diff')" = "1" ]; then
  pass "git reads that inject config or an external helper are gated, not exempted"
else
  miss "a git read that can execute an external helper rode past the budget wall"
fi
# The shell strips quotes before git runs, so a quoted write-producing flag must
# be recognized the same as a bare one and stay gated.
if [ "$(run 'git diff "--output=out"')" = "1" ] && [ "$(run "git diff '--ext-diff'")" = "1" ] \
   && [ "$(run "git -c 'diff.external=evil' diff")" = "1" ]; then
  pass "quoted write-producing git flags are gated, not exempted as reads"
else
  miss "a quoted write-producing git flag rode past the budget wall as a read"
fi
# Other allowlisted git read subcommands (not just the first one) stay runnable
# over budget, so the save-your-work inspection commands all keep working.
if [ "$(run 'git diff ./app.js')" = "0" ] && [ "$(run 'git log ./app.js')" = "0" ] \
   && [ "$(run 'git show HEAD')" = "0" ]; then
  pass "allowlisted git read subcommands (diff/log/show) stay allowed when over budget"
else
  miss "an allowlisted git read subcommand was blocked when over budget"
fi
# A safe read whose arguments merely contain an operator character keeps its
# exemption (the operator is inside quotes, not a shell pipe/chain).
if [ "$(run "grep 'foo|bar' app.js")" = "0" ] && [ "$(run "jq '.a | .b' app.js")" = "0" ] \
   && [ "$(run 'grep "foo|bar" app.js')" = "0" ]; then
  pass "a read with a quoted operator (single or double quotes) stays allowed when over budget"
else
  miss "a safe read with a quoted operator was blocked by the budget gate"
fi
# But substitution hidden in double quotes, process substitution, or output
# redirection is not a safe read and must go through the gates.
if [ "$(run 'echo "$(git commit -m x)"')" = "1" ] && [ "$(run 'cat <(touch ./x)')" = "1" ] \
   && [ "$(run 'git diff > ./out.patch')" = "1" ] && [ "$(run 'git diff >> ./out.patch')" = "1" ]; then
  pass "substitution or output redirection behind a safe prefix is gated"
else
  miss "substitution or redirection behind a safe prefix skipped the gates"
fi
# The budget recovery commands stay runnable when they resolve to this install's
# own bin/budget.sh (the trusted path), so the user can inspect or raise the
# limit through the guarded path.
if [ "$(run "$ROOT/bin/budget.sh check")" = "0" ] \
   && [ "$(run "$ROOT/bin/budget.sh set --max-usd 50")" = "0" ]; then
  pass "the trusted budget.sh check / set stay runnable when over budget"
else
  miss "the trusted budget management commands were blocked by the budget wall"
fi
# The exemption must not let a chained command smuggle other work past the wall,
# and it must not trust a foreign budget.sh (different path or bare name on PATH).
if [ "$(run "npm test && $ROOT/bin/budget.sh check")" = "1" ] \
   && [ "$(run "$ROOT/bin/budget.sh check \$(npm test)")" = "1" ] \
   && [ "$(run "$(printf '%s/bin/budget.sh check \nnpm test' "$ROOT")")" = "1" ] \
   && [ "$(run '/tmp/budget.sh check')" = "1" ] \
   && [ "$(run 'budget.sh check')" = "1" ]; then
  pass "the budget exemption rejects chaining (incl. newline), substitution, a foreign path, and a bare name"
else
  miss "the budget exemption is too loose (chain / newline / substitution / foreign path / bare name)"
fi
# Control: with no budget set, the in-project write passes again.
jq 'del(.budget)' "$NANOSTACK_STORE/session.json" > "$NANOSTACK_STORE/s.tmp" \
  && mv "$NANOSTACK_STORE/s.tmp" "$NANOSTACK_STORE/session.json"
if [ "$(run 'touch ./newfile2.txt')" = "0" ]; then
  pass "in-project write passes when no budget is set"
else
  miss "in-project write was blocked with no budget set"
fi

# ── #8 allowlisted reads are not gated by their argument text ───────────────
# In an active read-only phase, a write is blocked but an allowlisted read whose
# arguments merely contain write-command text must still pass.
RPW="$(mktemp -d)"; RPS="$RPW/.nanostack"; mkdir -p "$RPS"
( cd "$RPW" && git init -q && git config user.email t@example.com && git config user.name test \
  && echo "x" > a.js && git add -A && git commit -qm init ) >/dev/null 2>&1
printf '{"workspace":"%s","current_phase":"review","phase_log":[{"phase":"review","status":"in_progress"}]}' \
  "$RPW" > "$RPS/session.json"
runrp() { ( cd "$RPW" && NANOSTACK_STORE="$RPS" "$GUARD" "$1" >/dev/null 2>&1 ); echo $?; }
if [ "$(runrp 'touch ./newx.txt')" = "1" ]; then
  pass "a real write is blocked during a read-only phase"
else
  miss "a write was not blocked during a read-only phase"
fi
if [ "$(runrp "grep 'git commit' a.js")" = "0" ] && [ "$(runrp "echo 'touch ./x'")" = "0" ]; then
  pass "allowlisted reads with write-like argument text are not blocked"
else
  miss "an allowlisted read was blocked because its arguments contained write text"
fi
# The phase gate recognizes commit/push even with git global options, so they
# cannot slip through the in-project fast path during an active sprint.
if [ "$(runrp 'git -C . commit -m x')" = "1" ] && [ "$(runrp 'git commit -m x')" = "1" ]; then
  pass "git commit (including git -C ... commit) is gated during an active sprint"
else
  miss "git -C ... commit slipped past the phase gate"
fi
# Phase-gate recognition, tested directly so it is isolated from the read-only
# concurrency layer. The gate must recognize a real commit/push behind global
# options or a shell wrapper, and must NOT mistake a read inspection for one.
pgate() { ( cd "$RPW" && NANOSTACK_STORE="$RPS" "$ROOT/guard/bin/phase-gate.sh" "$1" >/dev/null 2>&1 ); echo $?; }
if [ "$(pgate 'git commit -m x')" = "1" ] && [ "$(pgate 'git -C . commit')" = "1" ] \
   && [ "$(pgate "git -c user.name='Jane Doe' commit -m x")" = "1" ] \
   && [ "$(pgate 'git -c user.name="Jane Doe" commit -m x')" = "1" ] \
   && [ "$(pgate 'git -c user.name=Jane\ Doe commit -m x')" = "1" ] \
   && [ "$(pgate "sh -c 'git commit -m x'")" = "1" ]; then
  pass "a real commit is gated through global options, quoted or escaped values, and a shell wrapper"
else
  miss "a real commit was not gated (global option, quoted/escaped value, or shell wrapper)"
fi
# Read-only git inspections whose arguments contain the word commit/push must
# not be mistaken for a commit/push subcommand.
if [ "$(pgate 'git grep commit')" = "0" ] && [ "$(pgate 'git log --grep push')" = "0" ] \
   && [ "$(pgate 'git diff -- commit_helper.py')" = "0" ]; then
  pass "git grep/log/diff are not mistaken for commit/push by the phase gate"
else
  miss "a read-only git inspection was gated as a commit/push"
fi
# A safe allowlisted prefix must not let a chained command skip the gates.
if [ "$(runrp 'ls && git commit -m x')" = "1" ] && [ "$(runrp 'git status; git commit -m x')" = "1" ]; then
  pass "a chained command behind a safe prefix is still gated"
else
  miss "a chained command rode past the gates behind a safe prefix"
fi

# ── #9 freeze wording is honest ─────────────────────────────────────────────
if grep -q "not a hook-enforced block" "$ROOT/guard/SKILL.md"; then
  pass "guard/SKILL.md describes freeze as guided, not hook-enforced"
else
  miss "guard/SKILL.md still claims freeze is enforced"
fi
if grep -q "guided, not hook-enforced" "$ROOT/README.md"; then
  pass "README frames freeze as guided, not hook-enforced"
else
  miss "README does not frame freeze as guided"
fi
if ! grep -q "freezes writes outside scope" "$ROOT/guard/agents/openai.yaml"; then
  pass "the adapter YAML no longer claims freeze enforces scope"
else
  miss "guard/agents/openai.yaml still claims freeze enforces scope"
fi

# ── budget-gate scope: cost cap, not a sandbox (wording lock) ────────────────
# The docs must frame the budget gate honestly so they never promise a git
# sandbox that the cost cap does not provide.
if grep -q "cost cap, not a sandbox" "$ROOT/guard/SKILL.md"; then
  pass "guard/SKILL.md frames the budget gate as a cost cap, not a sandbox"
else
  miss "guard/SKILL.md does not state the budget gate is a cost cap, not a sandbox"
fi

if [ "$fail" -ne 0 ]; then
  echo "check-policy-contract: FAIL"
  exit 1
fi
echo "check-policy-contract: OK"
