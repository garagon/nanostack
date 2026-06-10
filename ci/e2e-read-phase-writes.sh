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
  nh_assert_exit "/dev escape via .. blocked"                        1 bash_hook 'printf x > /dev/../tmp/out'
  nh_assert_exit "bare fd dup allowed (npm test 2>&1)"               0 bash_hook 'npm test 2>&1'
  nh_assert_exit "quoted arrow is not redirection (awk \$3 > 5)"     0 bash_hook "awk '\$3 > 5' data.txt"
  nh_assert_exit "quoted redirection target blocked (> \"out.txt\")"  1 bash_hook 'printf x > "out.txt"'
  nh_assert_exit "single-quoted target blocked (>> 'notes.md')"      1 bash_hook "echo hi >> 'notes.md'"
  nh_assert_exit "noclobber override blocked (>| out.txt)"           1 bash_hook 'printf x >| out.txt'
  nh_assert_exit "quoted /dev/null stays allowed"                    0 bash_hook 'true > "/dev/null"'
  nh_assert_exit "bash comparison is not redirection ([[ 5 > 3 ]])"  0 bash_hook '[[ 5 > 3 ]]'
  nh_assert_exit "arithmetic comparison allowed ((( count > 0 )))"   0 bash_hook '(( count > 0 ))'
  nh_assert_exit "escaped test comparison not redirection"          0 bash_hook '[ a \> b ]'
  nh_assert_exit "env -S inline code blocked"                       1 bash_hook "env -S \"python3 -c 'open(1)'\""
}

# Cells: in-place editors and write utilities.
cell_inplace() {
  set_phase security
  nh_assert_exit "sed -i blocked"               1 bash_hook 'sed -i s/a/b/ app.js'
  nh_assert_exit "sed -E -i blocked (option before -i)" 1 bash_hook "sed -E -i 's/a/b/' app.js"
  nh_assert_exit "sed -i.bak blocked (suffix form)"     1 bash_hook 'sed -i.bak s/a/b/ app.js'
  nh_assert_exit "sed --in-place=.bak blocked"          1 bash_hook 'sed --in-place=.bak s/a/b/ app.js'
  nh_assert_exit "sed -i after the script blocked"      1 bash_hook "sed -e 's/a/b/' -i file"
  nh_assert_exit "sed -e without -i stays allowed"     0 bash_hook "sed -e 's/a/b/' app.js"
  nh_assert_exit "ruby -i in-place blocked"            1 bash_hook 'ruby -i -pe "x" file'
  nh_assert_exit "ruby -pe stream stays allowed"       0 bash_hook "ruby -pe 'puts' file"


  nh_assert_exit "quoted -i flag still blocks (sed \"-i\")" 1 bash_hook 'sed "-i" s/a/b/ app.js'

  nh_assert_exit "tee blocked"                  1 bash_hook 'tee log.txt'
  nh_assert_exit "npm install blocked"          1 bash_hook 'npm install left-pad'
  nh_assert_exit "sed without -i allowed"       0 bash_hook 'sed -n 1,5p app.js'
  nh_assert_exit "plain read tool allowed"      0 bash_hook 'diff a.txt b.txt'
  nh_assert_exit "install utility at cmd pos blocked" 1 bash_hook 'install -m 0644 a b'
  nh_assert_exit "install as npm script name allowed" 0 bash_hook 'npm run install'
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
  nh_assert_exit "combined shell flag blocks (bash -lc)"      1 bash_hook 'bash -lc "echo x > f"'
  nh_assert_exit "combined shell flag blocks (sh -ec)"        1 bash_hook 'sh -ec "echo x > f"'
  nh_assert_exit "combined python flag blocks (python -bc)"   1 bash_hook 'python -bc "open()"'
  nh_assert_exit "perl stream loop stays allowed (-ne)"       0 bash_hook "perl -ne 'print' file"
  nh_assert_exit "node --eval blocked (long form)"           1 bash_hook 'node --eval "fs.writeFileSync()"'
  nh_assert_exit "deno eval subcommand blocked"              1 bash_hook 'deno eval "Deno.writeTextFile()"'
  nh_assert_exit "perl numeric flag in-place blocked"        1 bash_hook 'perl -0777 -pi.bak rewrite.pl file'
  nh_assert_exit "perl clustered -0pi.bak blocked"           1 bash_hook 'perl -0pi.bak rewrite.pl file'
  nh_assert_exit "pipe into bare interpreter blocked"        1 bash_hook 'echo "code" | node'
  nh_assert_exit "heredoc piped into python blocked"         1 bash_hook 'cat <<PY | python3
open("x","w")
PY'
  nh_assert_exit "pipe into interpreter with script allowed" 0 bash_hook 'cat data.csv | python3 process.py'
  nh_assert_exit "pipe into module mode allowed"             0 bash_hook 'cat x | python3 -m json.tool'
  nh_assert_exit "option-arg before -c still blocks (python -W)" 1 bash_hook 'python -W ignore -c "open()"'
  nh_assert_exit "option-arg before -e still blocks (node -r)"   1 bash_hook 'node -r ./hook -e "fs()"'
  nh_assert_exit "interpreter name as grep arg not misread"      0 bash_hook 'grep python3 -c file'
  nh_assert_exit "php -r inline code blocked"                    1 bash_hook 'php -r "file_put_contents()"'
  nh_assert_exit "env-wrapped inline code blocked"              1 bash_hook 'env FOO=1 python3 -c "open()"'
  nh_assert_exit "timeout-wrapped inline code blocked"          1 bash_hook 'timeout 5 python3 -c "open()"'
  nh_assert_exit "timeout with options wraps inline code"      1 bash_hook 'timeout --preserve-status 5 python3 -c "open()"'
  nh_assert_exit "timeout -s with signal arg wraps code"      1 bash_hook 'timeout -s KILL 5 python3 -c "open()"'
  nh_assert_exit "sudo -u with user arg wraps code"           1 bash_hook 'sudo -u nobody python3 -c "open()"'
  nh_assert_exit "env-assignment prefix inline code blocked"    1 bash_hook 'FOO=1 python3 -c "open()"'
  nh_assert_exit "attached perl -e code blocked"                1 bash_hook "perl -e'open F,\">x\"'"
  nh_assert_exit "pipe into wrapped interpreter blocked"        1 bash_hook 'echo code | env python3'
  nh_assert_exit "wrapped npm test stays allowed"               0 bash_hook 'env NODE_ENV=test npm test'
  nh_assert_exit "attached perl -pe stream stays allowed"       0 bash_hook "perl -pe'X' file"
  nh_assert_exit "command substitution inline code blocked"     1 bash_hook 'echo $(python3 -c "open()")'
  nh_assert_exit "backtick substitution inline code blocked"    1 bash_hook 'x=`python3 -c "open()"`'
  nh_assert_exit "path-qualified env wrapper blocked"           1 bash_hook '/usr/bin/env python3 -c "open()"'
  nh_assert_exit "pipe into path-qualified wrapper blocked"     1 bash_hook 'echo code | /usr/bin/env python3'
  nh_assert_exit "substitution of read command stays allowed"   0 bash_hook 'echo $(git rev-parse HEAD)'
  nh_assert_exit "stdin pseudo-file is inline code"            1 bash_hook 'echo code | python3 /dev/stdin'
  nh_assert_exit "heredoc to /dev/stdin is inline code"        1 bash_hook 'python3 /dev/stdin <<PY
open()
PY'
  nh_assert_exit "double-quoted substitution inline code blocks"  1 bash_hook 'echo "$(python3 -c '"'"'open(1)'"'"')"'
  nh_assert_exit "double-quoted git mutation blocks"              1 bash_hook 'echo "$(git checkout main)"'
  nh_assert_exit "redirection inside substitution blocks"         1 bash_hook 'echo "$(printf x > out.txt)"'
  nh_assert_exit "git as a plain argument is not classified"      0 bash_hook 'printf git checkout'
  nh_assert_exit "nested substitution redirection blocks"         1 bash_hook 'echo "$(printf x > $(pwd)/out.txt)"'
  nh_assert_exit "nested read substitution stays allowed"         0 bash_hook 'echo $(git rev-parse $(git branch --show-current))'
  nh_assert_exit "single-quoted substitution is inert"            0 bash_hook "grep -R '\$(git checkout main)' docs"
  nh_assert_exit "escaped substitution is literal"                0 bash_hook 'grep "\\$(git checkout main)" docs'


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
  nh_assert_exit "git apply --check is read-only"     0 bash_hook 'git apply --check patch.diff'
  nh_assert_exit "git apply (real) blocked"           1 bash_hook 'git apply patch.diff'
  nh_assert_exit "git branch <name> blocked (ref creation)" 1 bash_hook 'git branch tmp'
  nh_assert_exit "git tag <name> blocked (ref creation)"    1 bash_hook 'git tag v1.0'
  nh_assert_exit "quoted ref name still blocks (git branch \"tmp\")" 1 bash_hook 'git branch "tmp"'
  nh_assert_exit "display flag before ref still blocks (branch -v tmp)" 1 bash_hook 'git branch -v tmp'
  nh_assert_exit "rename blocks (git branch -m old new)"     1 bash_hook 'git branch -m old new'
  nh_assert_exit "tag with sort and name blocks"            1 bash_hook 'git tag --sort=creatordate v1'
  nh_assert_exit "branch --contains is a filtered read"      0 bash_hook 'git branch --contains HEAD'
  nh_assert_exit "branch --merged is a filtered read"        0 bash_hook 'git branch --merged main'
  nh_assert_exit "branch -v alone is a read"                 0 bash_hook 'git branch -v'
  nh_assert_exit "branch -a (all) is a read"                 0 bash_hook 'git branch -a'
  nh_assert_exit "branch --format value is a read"           0 bash_hook "git branch --format '%(refname)'"
  nh_assert_exit "branch -v && echo is a read"               0 bash_hook 'git branch -v && echo done'
  nh_assert_exit "branch read then chained create blocks"    1 bash_hook 'git branch -v && git branch tmp'
  nh_assert_exit "git mutation in substitution blocks"       1 bash_hook 'echo $(git checkout main)'
  nh_assert_exit "no-space && chained mutation blocks"       1 bash_hook 'git diff&&git checkout main'
  nh_assert_exit "no-space ; chained mutation blocks"        1 bash_hook 'git status;git restore app.js'
  nh_assert_exit "chained read-then-mutate blocks"           1 bash_hook 'git diff && git checkout main'
  nh_assert_exit "chained with ; blocks the mutation"        1 bash_hook 'git status; git restore app.js'
  nh_assert_exit "tag -n annotation listing is a read"       0 bash_hook 'git tag -n v1'
  nh_assert_exit "tag --contains is a read"                  0 bash_hook 'git tag --contains HEAD'
  nh_assert_exit "tag -a annotated create blocks"            1 bash_hook 'git tag -a v1 -m x'
  nh_assert_exit "tag -v signature verify is a read"         0 bash_hook 'git tag -v v1.0'
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
# Cells: package-manager dependency writes block; read subcommands stay.
cell_package_managers() {
  set_phase qa
  nh_assert_exit "npm ci blocked"               1 bash_hook 'npm ci'
  nh_assert_exit "yarn add blocked"             1 bash_hook 'yarn add left-pad'
  nh_assert_exit "go get blocked"               1 bash_hook 'go get ./...'
  nh_assert_exit "pip install blocked"          1 bash_hook 'pip install foo'
  nh_assert_exit "npm test allowed"             0 bash_hook 'npm test'
  nh_assert_exit "go test allowed"              0 bash_hook 'go test ./...'
  nh_assert_exit "cargo build allowed"          0 bash_hook 'cargo build'
  nh_assert_exit "npm ls allowed"               0 bash_hook 'npm ls'
  nh_assert_exit "go mod tidy blocked"          1 bash_hook 'go mod tidy'
  nh_assert_exit "go mod graph is a read"       0 bash_hook 'go mod graph'
  nh_assert_exit "npm version bump blocked"     1 bash_hook 'npm version patch'
  nh_assert_exit "npm version (no arg) is read" 0 bash_hook 'npm version'
  nh_assert_exit "go generate blocked"          1 bash_hook 'go generate ./...'
  nh_assert_exit "pnpm --filter add blocked"    1 bash_hook 'pnpm --filter app add left-pad'
  nh_assert_exit "yarn workspace add blocked"   1 bash_hook 'yarn workspace app add left-pad'
  nh_assert_exit "pip -q install blocked"       1 bash_hook 'pip -q install foo'
  nh_assert_exit "npm run <script> stays read"  0 bash_hook 'npm run add'
  nh_assert_exit "wrapped npm ci blocked"       1 bash_hook '/usr/bin/env npm ci'
  nh_assert_exit "env-assignment pnpm add blocked" 1 bash_hook 'FOO=1 pnpm add x'
  nh_assert_exit "python -m pip install blocked"   1 bash_hook 'python -m pip install foo'
  nh_assert_exit "python -m pytest stays a read"   0 bash_hook 'python -m pytest'
  nh_assert_exit "python flags before -m pip blocked" 1 bash_hook 'python3 -u -m pip install foo'
  nh_assert_exit "dotted pip version blocked"      1 bash_hook 'pip3.12 install foo'
  nh_assert_exit "npm config set blocked"          1 bash_hook 'npm config set registry x'
  nh_assert_exit "npm cache clean blocked"         1 bash_hook 'npm cache clean --force'
  nh_assert_exit "npm config get stays a read"     0 bash_hook 'npm config get registry'
}

nh_cell phase-scoped   cell_phase_scoped
nh_cell package-managers cell_package_managers

nh_summary
