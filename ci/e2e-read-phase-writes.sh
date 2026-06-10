#!/usr/bin/env bash
# e2e-read-phase-writes.sh — Bash write paths during read-only phases.
#
# Security review finding #3: the Bash guard blocked the obvious write
# utilities (rm/mv/cp/touch/...) during read-only phases, but a command
# can mutate state without naming one: output redirection (`echo x >>
# file`), in-place editors (`sed -i`), inline interpreter code
# (`python -c`, `sh -c` — whose quoted body is invisible to pattern
# checks), package installs, and git worktree mutations (`git stash`,
# `git restore`). check-dangerous.sh Tier 2.4 now detects those classes
# on the quote-stripped command. This suite is the active regression
# lock: every cell drives the real hook with a real session file.
#
# The negative cells matter as much as the positive ones: /dev/null
# redirection, bare fd dups (2>&1), quoted arrows (`awk '$3 > 5'`),
# sed without -i, and allowlisted reads must all stay allowed, or
# read-only phases become unusable for review/security/qa work.
#
# Exit 0 = all cells pass, exit 1 = any cell failed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/ci/lib/harness.sh"

CHECK_DANGEROUS="$REPO/guard/bin/check-dangerous.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --filter) nh_set_filter "${2:-}"; shift 2 ;;
    --filter=*) nh_set_filter "${1#*=}"; shift ;;
    *) shift ;;
  esac
done

nh_init read-phase-writes nano-rpw
nh_require_cmd git jq

WORK="$NH_TMP"
cd "$WORK"
git init -q
git config user.email t@t.t; git config user.name t
export NANOSTACK_STORE="$WORK/.nanostack"
mkdir -p "$NANOSTACK_STORE"

bash_hook() { (cd "$WORK" && "$CHECK_DANGEROUS" "$1" >/dev/null 2>&1); }

set_phase() {
  printf '{"workspace":"%s","current_phase":"%s","phase_log":[{"phase":"%s","status":"in_progress"}]}' \
    "$WORK" "$1" "$1" > "$NANOSTACK_STORE/session.json"
}

# Cells: redirection writes blocked, harmless redirection allowed.
cell_redirection() {
  set_phase review
  nh_assert_exit "append redirection blocked (echo hi >> notes.md)"  1 bash_hook 'echo hi >> notes.md'
  nh_assert_exit "truncate redirection blocked (printf x > out.txt)" 1 bash_hook 'printf x > out.txt'
  nh_assert_exit "stderr-to-file blocked (cmd 2> err.log)"           1 bash_hook 'diff a.txt b.txt 2> err.log'
  nh_assert_exit "/dev/null redirection allowed"                     0 bash_hook 'true > /dev/null'
  nh_assert_exit "bare fd dup allowed (npm test 2>&1)"               0 bash_hook 'npm test 2>&1'
  nh_assert_exit "quoted arrow is not redirection (awk \$3 > 5)"     0 bash_hook "awk '\$3 > 5' data.txt"
  nh_assert_exit "quoted redirection target blocked (> \"out.txt\")"  1 bash_hook 'printf x > "out.txt"'
  nh_assert_exit "single-quoted target blocked (>> 'notes.md')"      1 bash_hook "echo hi >> 'notes.md'"
  nh_assert_exit "noclobber override blocked (>| out.txt)"           1 bash_hook 'printf x >| out.txt'
  nh_assert_exit "quoted /dev/null stays allowed"                    0 bash_hook 'true > "/dev/null"'
  nh_assert_exit "bash comparison is not redirection ([[ 5 > 3 ]])"  0 bash_hook '[[ 5 > 3 ]]'
  nh_assert_exit "arithmetic comparison allowed ((( count > 0 )))"   0 bash_hook '(( count > 0 ))'
}

# Cells: in-place editors and write utilities.
cell_inplace() {
  set_phase security
  nh_assert_exit "sed -i blocked"               1 bash_hook 'sed -i s/a/b/ app.js'
  nh_assert_exit "sed -E -i blocked (option before -i)" 1 bash_hook "sed -E -i 's/a/b/' app.js"
  nh_assert_exit "sed -i.bak blocked (suffix form)"     1 bash_hook 'sed -i.bak s/a/b/ app.js'
  nh_assert_exit "sed --in-place=.bak blocked"          1 bash_hook 'sed --in-place=.bak s/a/b/ app.js'
  nh_assert_exit "quoted -i flag still blocks (sed \"-i\")" 1 bash_hook 'sed "-i" s/a/b/ app.js'

  nh_assert_exit "tee blocked"                  1 bash_hook 'tee log.txt'
  nh_assert_exit "npm install blocked"          1 bash_hook 'npm install left-pad'
  nh_assert_exit "sed without -i allowed"       0 bash_hook 'sed -n 1,5p app.js'
  nh_assert_exit "plain read tool allowed"      0 bash_hook 'diff a.txt b.txt'
}

# Cells: inline interpreter code (the quoted body can write through any
# API and is invisible to pattern checks, so the flag itself blocks).
cell_interpreters() {
  set_phase qa
  nh_assert_exit "python -c blocked"            1 bash_hook 'python3 -c "open(\"x\",\"w\")"'
  nh_assert_exit "node -e blocked"              1 bash_hook 'node -e "fs.writeFileSync(\"x\",\"y\")"'
  nh_assert_exit "sh -c blocked"                1 bash_hook 'sh -c "echo x > f"'
  nh_assert_exit "python --version allowed"     0 bash_hook 'python --version'
  nh_assert_exit "script execution allowed"     0 bash_hook 'npx playwright test'
  nh_assert_exit "subcommand config flag allowed (pytest -c)" 0 bash_hook 'python -m pytest -c pytest.ini'
  nh_assert_exit "deno test config flag allowed"              0 bash_hook 'deno test -c deno.json'
  nh_assert_exit "perl -i.bak as first flag blocked"          1 bash_hook "perl -i.bak -pe 's/a/b/' file"
  nh_assert_exit "perl -pe stream transform allowed"          0 bash_hook "perl -pe 's/a/b/' file"
  nh_assert_exit "stdin-fed python blocked (python3 - <<PY)"  1 bash_hook 'python3 - <<PY
open("x","w")
PY'
  nh_assert_exit "heredoc-fed sh blocked (sh <<EOF)"          1 bash_hook 'sh <<EOF
echo hi > f
EOF'
  nh_assert_exit "script execution with flag allowed"         0 bash_hook 'bash -x build.sh'
  nh_assert_exit "quoted -c flag still blocks (python3 \"-c\")" 1 bash_hook 'python3 "-c" "open()"'
}

# Cells: git worktree mutations beyond add/commit/push/reset.
cell_git_mutations() {
  set_phase review
  nh_assert_exit "git stash blocked"            1 bash_hook 'git stash'
  nh_assert_exit "git restore blocked"          1 bash_hook 'git restore app.js'
  nh_assert_exit "git switch blocked"           1 bash_hook 'git switch -c tmp'
  nh_assert_exit "git stash list allowed"       0 bash_hook 'git stash list'
  nh_assert_exit "git diff allowed"             0 bash_hook 'git diff'
  nh_assert_exit "git merge-base is a read, allowed" 0 bash_hook 'git merge-base main HEAD'
  nh_assert_exit "git stash show is a read, allowed"  0 bash_hook 'git stash show'
  nh_assert_exit "git worktree list is a read, allowed" 0 bash_hook 'git worktree list'
  nh_assert_exit "git worktree add blocked"           1 bash_hook 'git worktree add ../w2'
  nh_assert_exit "git branch <name> blocked (ref creation)" 1 bash_hook 'git branch tmp'
  nh_assert_exit "git tag <name> blocked (ref creation)"    1 bash_hook 'git tag v1.0'
  nh_assert_exit "quoted ref name still blocks (git branch \"tmp\")" 1 bash_hook 'git branch "tmp"'
}

# Cells: the block is phase-scoped, not global.
cell_phase_scoped() {
  set_phase build
  nh_assert_exit "build phase: redirection allowed"  0 bash_hook 'printf x > out.txt'
  rm -f "$NANOSTACK_STORE/session.json"
  nh_assert_exit "no session: redirection allowed"   0 bash_hook 'printf x > out.txt'
}

nh_cell redirection    cell_redirection
nh_cell inplace        cell_inplace
nh_cell interpreters   cell_interpreters
nh_cell git-mutations  cell_git_mutations
nh_cell phase-scoped   cell_phase_scoped

nh_summary
