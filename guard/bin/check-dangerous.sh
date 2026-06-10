#!/usr/bin/env bash
# Guard: check-dangerous.sh
# Layered permission check for every Bash call. Block rules run before
# the allowlist so allowlisted binaries (cat, find, head, tail) still
# match known-bad patterns like `cat .env` or `find . -delete`.
#
# Order:
#   Block rules                (no exceptions, fail closed)
#   Allowlist                  (safe commands short-circuit)
#   Phase-aware concurrency    (read phases block write commands)
#   In-project fast-path       (git-reviewable changes pass)
#   Sprint phase gate          (blocks commit/push until required
#                               ancestors of ship are complete)
#   Budget gate                (blocks all commands when over budget)
#   Warn rules                 (allowed but flagged)
#
# On block: suggests a safer alternative (deny-and-continue).
# On warn: allows but flags the risk.
#
# Called by the PreToolUse hook on Bash commands (Claude Code hosts the
# hook directly; other adapters install per their host docs).
# Exit 0 = safe/warn, Exit 1 = blocked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RULES_FILE="$SCRIPT_DIR/rules.json"
CMD="${1:-$(cat)}"

# Resolve the nanostack root and store-path helper up front so every
# downstream tier (block, warn, audit trail) sees a consistent view.
# Previously STORE_PATH_SH was set inside Tier 2.5, which meant Tier
# 1.5 blocks never appended to audit.log when NANOSTACK_STORE was
# unset. Doing it here keeps blocking and trace visibility together.
GUARD_DIR="$SCRIPT_DIR"
NANOSTACK_ROOT="$(cd "$GUARD_DIR/.." && pwd)"
STORE_PATH_SH="$NANOSTACK_ROOT/bin/lib/store-path.sh"
if [ -z "${NANOSTACK_STORE:-}" ] && [ -f "$STORE_PATH_SH" ]; then
  # shellcheck disable=SC1090
  source "$STORE_PATH_SH" 2>/dev/null || true
fi
AUDIT_LOG="${NANOSTACK_STORE:-}/audit.log"

# Fallback if rules.json missing
if [ ! -f "$RULES_FILE" ]; then
  echo "⚠️  GUARD: rules.json not found, allowing command"
  exit 0
fi

# Mask inline secrets in a command string before it is shown or persisted. The
# audit log and the deny output echo the command back, so a command carrying a
# secret would otherwise leave it in a log file or the transcript. Shared with
# the sprint phase gate so both audit writers redact the same way.
REDACT_LIB="$NANOSTACK_ROOT/bin/lib/redact-secrets.sh"
if [ -f "$REDACT_LIB" ]; then
  # shellcheck disable=SC1090
  source "$REDACT_LIB"
else
  # Fallback no-op if the helper is missing: never break the guard over logging.
  redact_secrets() { printf '%s' "${1:-}"; }
fi

# Helper: append a JSON record to the audit log if the store resolved.
# No-op when the store is unavailable so guard still blocks even on
# machines without a configured .nanostack/ directory.
audit_trail_append() {
  local result="$1" rule="$2"
  [ -n "${AUDIT_LOG:-}" ] && [ -d "$(dirname "$AUDIT_LOG")" ] || return 0
  jq -cn \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg cmd "$(redact_secrets "$CMD")" \
    --arg result "$result" \
    --arg rule "$rule" \
    '{at:$at, cmd:$cmd, result:$result, rule:$rule}' \
    >> "$AUDIT_LOG" 2>/dev/null || true
}

CMD_BASE=$(echo "$CMD" | awk '{print $1}' | sed 's|.*/||')

BLOCK_INPUT="$CMD"

# Catastrophic recursive rm, independent of flag spelling and operand order.
# The rm rules (G-001..G-004) are written against the canonical
# `rm -rf <target>`, but `rm -fr`, `rm -r -f`, `rm --recursive --force`,
# `rm -r -f -- ~`, `rm -r --interactive=never *`, and `rm -fr /tmp /` are the
# same operation. Rather than rewrite flags in place (which is sensitive to
# operand position), detect a recursive rm and then scan every operand for a
# catastrophic target (root, home, current dir, wildcard) in any quoting. For
# each catastrophic target found, append the canonical form so the existing
# rules fire. A recursive cleanup of an ordinary path (e.g. `rm -r /tmp/build`)
# has no catastrophic operand, so nothing is appended and it is not blocked.
if printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])rm[[:space:]]+([-][-a-zA-Z0-9=]*[[:space:]]+)*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$)' 2>/dev/null; then
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?/+[*]?[\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf /"
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?~/?[*]?[\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf ~"
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?[*][\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf *"
  printf '%s' "$CMD" | grep -qE "([[:space:]=]|^)[\"']?[.]/?[\"']?([[:space:]]|[;&]|\$)" 2>/dev/null && BLOCK_INPUT="$BLOCK_INPUT
rm -rf ."
fi

# Heredoc and other multi-line invocations put the interpreter on one line
# and the secret read on another. Add a newline-flattened copy so rules like
# the interpreter secret-read guard (G-036) can match across the lines.
case "$CMD" in
  *"
"*)
    FLAT_CMD=$(printf '%s' "$CMD" | tr '\n' ' ')
    [ -n "$FLAT_CMD" ] && BLOCK_INPUT="$BLOCK_INPUT
$FLAT_CMD"
    ;;
esac

# ─── Tier 1: Block rules (authoritative, no exceptions) ─────
# Block patterns run before the allowlist so commands whose binary
# happens to be on the allowlist (cat, find, head, tail) still get
# evaluated against known-bad patterns such as reading .env or
# find . -delete. Previous ordering let allowlisted binaries short
# circuit past block rules; audit finding from April 2026.
BLOCK_PATTERNS=$(jq -r '.tiers.block.rules[] | .pattern' "$RULES_FILE" 2>/dev/null)
BLOCK_COMBINED=$(echo "$BLOCK_PATTERNS" | paste -sd'|' -)
if [ -n "$BLOCK_COMBINED" ] && printf '%s\n' "$BLOCK_INPUT" | grep -qiE -- "$BLOCK_COMBINED" 2>/dev/null; then
  BLOCK_IDX=0
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if printf '%s\n' "$BLOCK_INPUT" | grep -qiE -- "$PATTERN" 2>/dev/null; then
      RULE=$(jq -c ".tiers.block.rules[$BLOCK_IDX]" "$RULES_FILE")
      ID=$(echo "$RULE" | jq -r '.id')
      DESC=$(echo "$RULE" | jq -r '.description')
      CATEGORY=$(echo "$RULE" | jq -r '.category')
      ALT=$(echo "$RULE" | jq -r '.alternative')

      echo "BLOCKED [$ID] $DESC"
      echo "Category: $CATEGORY"
      echo "Command: $(redact_secrets "$CMD")"
      echo ""
      echo "Safer alternative: $ALT"
      audit_trail_append blocked "$ID"
      exit 1
    fi
    BLOCK_IDX=$((BLOCK_IDX + 1))
  done <<< "$BLOCK_PATTERNS"
fi

# ─── Tier 2: Allowlist match ────────────────────────────────
# Determine whether this is an allowlisted safe command, but do NOT exit yet.
# The global gates (phase concurrency, sprint phase gate, budget gate) run
# before the allowlist short-circuit below, so they are truly global and a
# safe-command match cannot skip them.
IS_ALLOWLISTED=false
TIER1=$(jq -r --arg cmd "$CMD" --arg base "$CMD_BASE" '
  .tiers.allowlist.commands[] |
  split(" ")[0] | gsub(".*/"; "") |
  select(. == $base)' "$RULES_FILE" 2>/dev/null | head -1)

# A chained, piped, substituted, or redirected command is never treated as
# allowlisted: the allowlist matches only the first command, so a safe prefix
# like `ls && git commit`, `echo "$(git commit -m x)"`, or `git diff > out`
# must not short-circuit the global gates. Quote handling differs by operator:
# control operators and output redirection (&& ; | & >) are literal inside both
# quote styles, so strip both before checking them; command and process
# substitution ($( ` <( ) are still active inside double quotes, so for those
# strip only single quotes. This keeps a real read like `grep 'a|b' f` or
# `grep "a|b" f` exempt while catching substitution hidden in double quotes.
CMD_NOQ=$(printf '%s' "$CMD" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
CMD_NOSQ=$(printf '%s' "$CMD" | sed "s/'[^']*'//g")
case "$CMD_NOQ" in *'&&'*|*';'*|*'|'*|*'&'*|*'>'*) TIER1="" ;; esac
case "$CMD_NOSQ" in *'$('*|*'`'*|*'<('*) TIER1="" ;; esac
# Wrapper commands run another program, so an allowlisted wrapper must not exempt
# the wrapped command from the gates: `env git commit` is a commit, not a read.
# These go through the gates, which inspect the full command string.
case "$CMD_BASE" in
  env|xargs|time|timeout|nice|nohup|stdbuf|ionice|setsid|chrt|sudo|doas|command|exec|watch) TIER1="" ;;
esac
# find is a read only without an action that executes a command (-exec/-ok) or
# writes/deletes (-delete/-fprint*/-fls). With any of those it must go through the
# gates, e.g. `find . -exec git commit {} +` is a commit, not a read.
if [ "$CMD_BASE" = "find" ]; then
  case " $CMD " in
    *' -exec'*|*' -ok'*|*' -delete'*|*' -fprint'*|*' -fls'*) TIER1="" ;;
  esac
fi
# git is allowlisted only for read-only subcommands. It is classified specially
# (not by raw prefix) so that global options before the subcommand are tolerated
# (`git -C . diff`, `git --no-pager status`) while mutating forms stay gated —
# in particular `git branch <name>` / `-m` / `-d` create or change refs and must
# not ride the save-work exemption that bare `git branch` (list) gets.
#
# Scope boundary: this rejects the command-line vectors that turn a "read" into
# command execution (`-c` config injection, `--ext-diff`, `--output`,
# `--exec-path=`). It does NOT defend against a repository whose own git config
# runs helper programs (`diff.external`, textconv, `core.fsmonitor`, filters,
# hooks). Those helpers run on ANY git command the agent issues, with or without
# the budget gate, so they are out of scope here: the budget gate is a cost cap,
# not a sandbox against a hostile repo config.
git_read_allowlisted() {
  local toks; IFS=' ' read -ra toks <<< "$1"
  # The shell strips quotes before git runs, so a quoted flag like
  # `"--output=out"` or `'--ext-diff'` reaches git as a bare flag. Dequote each
  # token (one surrounding pair) so the matching below cannot be evaded by
  # quoting a write-producing option.
  local k tk
  for k in "${!toks[@]}"; do
    tk="${toks[$k]}"; tk="${tk#[\"\']}"; tk="${tk%[\"\']}"; toks[$k]="$tk"
  done
  local i=1 n=${#toks[@]} sub="" t
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    case "$t" in
      # Config / exec-path injection: `-c diff.external=cmd`, `--config-env`, or a
      # rewritten `--exec-path=` can make a "read" execute an external helper, so
      # any of these disqualifies the read exemption outright.
      -c|--config-env|-c=*|--config-env=*|--exec-path=*) return 1 ;;
      -C|--git-dir|--work-tree|--namespace) i=$((i + 2)); continue ;;
      --git-dir=*|--work-tree=*|--namespace=*) i=$((i + 1)); continue ;;
      --) return 1 ;;
      -*) i=$((i + 1)); continue ;;
      *) sub="$t"; break ;;
    esac
  done
  local rest=("${toks[@]:$((i + 1))}") a
  case "$sub" in
    status|log|diff|show)
      # These are reads, except --output/-o writes a file and --ext-diff runs an
      # external diff helper configured in the repo.
      for a in ${rest[@]+"${rest[@]}"}; do
        case "$a" in -o|--output|--output=*|--ext-diff) return 1 ;; esac
      done
      return 0 ;;
    remote)
      # Read-only only when bare or `remote -v` with no following subcommand
      # (a trailing `remove`/`set-url`/`add` would mutate config).
      [ -z "${rest[0]:-}" ] && return 0
      [ "${rest[0]:-}" = "-v" ] && [ -z "${rest[1]:-}" ] && return 0
      return 1 ;;
    stash) [ "${rest[0]:-}" = "list" ] && [ -z "${rest[1]:-}" ] && return 0; return 1 ;;
    branch)
      # Write forms (-m/-d/-c/-f/-u/...) are gated. Real list/filter modes accept
      # a positional (a pattern or commit) and stay read: --list 'feature/*',
      # --contains HEAD, --merged main. A positional with no list-mode flag is a
      # new branch name, which creates a ref and is gated — even alongside output
      # modifiers like --sort/--format, which do NOT force list mode (and consume
      # their own value token).
      local listmode=false haspos=false j=0 m=${#rest[@]} a
      while [ "$j" -lt "$m" ]; do
        a="${rest[$j]}"
        case "$a" in
          -m|-M|-d|-D|-c|-C|-f|-u|--move|--copy|--delete|--force|--unset-upstream \
            |--edit-description|--set-upstream-to=*) return 1 ;;
          --list|-l|--contains|--contains=*|--no-contains|--no-contains=* \
            |--merged|--merged=*|--no-merged|--no-merged=*|--points-at|--points-at=* \
            |-a|--all|-r|--remotes|--show-current) listmode=true ;;
          --sort|--format) j=$((j + 1)) ;;   # output modifier: consumes its value
          --sort=*|--format=*) ;;            # value inline, no positional
          -*) ;;            # other read-only flags (-v, --color, --abbrev, ...)
          *) haspos=true ;; # pattern/commit in list mode, else a new branch name
        esac
        j=$((j + 1))
      done
      [ "$listmode" = true ] && return 0
      [ "$haspos" = true ] && return 1
      return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "$TIER1" ]; then
  if [ "$CMD_BASE" = "git" ]; then
    git_read_allowlisted "$CMD" && IS_ALLOWLISTED=true
  else
  # Base matches. Collect ALL multi-word allowlist entries for this base.
  MULTI=$(jq -r --arg base "$CMD_BASE" '
    .tiers.allowlist.commands[] |
    select((split(" ")[0] | gsub(".*/"; "")) == $base and (split(" ") | length) > 1)' "$RULES_FILE" 2>/dev/null)
  if [ -z "$MULTI" ]; then
    # Single-word entry: base match is enough.
    IS_ALLOWLISTED=true
  else
    # Multi-word entries (e.g. "node --version", "npm list"): the command must
    # start with one of them. The first token is normalized to its basename first
    # so a path-prefixed invocation matches the same as the bare command.
    CMD_FIRST="${CMD%% *}"
    CMD_NORM="${CMD_FIRST##*/}${CMD#"$CMD_FIRST"}"
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      case "$CMD_NORM" in "$entry"|"$entry "*) IS_ALLOWLISTED=true; break ;; esac
    done <<< "$MULTI"
  fi
  fi
fi

# ─── Tier 2.4: Phase-aware concurrency enforcement ─────────
# Runs BEFORE the in-project fast-path. A read-only phase must block
# write commands even when they only touch in-project paths, otherwise
# `touch ./foo` or `mv ./a ./b` slip through the git-reviewable
# allowlist and silently mutate files during a phase that promised no
# writes. Codex caught this on the PR 1 review by testing `touch ./x`
# from a git worktree while concurrency was set to read.
#
# Skill resolution goes through bin/lib/phases.sh so custom phases are
# protected the same way built-in ones are. The previous lookup did a
# raw $NANOSTACK_ROOT/$CURRENT_PHASE/SKILL.md, which silently no-oped
# for any phase whose SKILL.md lived outside the repo (every custom
# skill under $NANOSTACK_STORE/skills, ~/.claude/skills, etc.).
if [ -n "${NANOSTACK_STORE:-}" ]; then
  # Resolve the active phase's concurrency through the shared registry
  # helper (bin/lib/phases.sh). The SAME helper backs the Write/Edit
  # guard (guard/bin/check-write.sh) so the two hooks cannot drift on
  # what "read-only phase" means. The helper fails open (non-zero, no
  # output) for stale sessions, the conductor's "build" stage, removed
  # skills, and malformed custom skill metadata — so the guard never
  # blocks because of a bad session pointer.
  # Allowlisted safe reads (ls, cat, grep, echo, git status) are not writes, so
  # they are exempt from the concurrency substring check even when their
  # arguments happen to contain write-command text like `grep 'git commit'`.
  PHASES_LIB="$NANOSTACK_ROOT/bin/lib/phases.sh"
  if [ "$IS_ALLOWLISTED" != true ] && [ -f "$PHASES_LIB" ]; then
    # shellcheck disable=SC1090
    source "$PHASES_LIB" 2>/dev/null || true
    if command -v nano_active_phase_concurrency >/dev/null 2>&1; then
      ACTIVE_REC=$(nano_active_phase_concurrency 2>/dev/null) || ACTIVE_REC=""
      if [ -n "$ACTIVE_REC" ]; then
        CURRENT_PHASE=$(printf '%s' "$ACTIVE_REC" | cut -f1)
        SKILL_CONC=$(printf '%s' "$ACTIVE_REC" | cut -f2)
      else
        CURRENT_PHASE=""
        SKILL_CONC=""
      fi

      # Block writes during read-only phases
      if [ "$SKILL_CONC" = "read" ]; then
        RO_REASON=""
        case "$CMD" in
          *rm\ *|*mv\ *|*cp\ *|*mkdir\ *|*touch\ *|*chmod\ *|*git\ add*|*git\ commit*|*git\ push*|*git\ reset*)
            RO_REASON="write command"
            ;;
        esac

        # Mutation paths the utility list above cannot see (security
        # review finding #3): output redirection, in-place editors,
        # inline interpreter code, and git worktree mutations all write
        # without naming a write utility. Detection normalizes quoted
        # segments first so `grep 'a->b' file` is never read as
        # redirection. Allowlisted safe reads never reach this tier.

        # (a) Output redirection to anything except /dev/*. Quoted
        #     segments are REPLACED with a placeholder, not deleted:
        #     deleting them would erase a quoted target (`> "out.txt"`)
        #     and let the write through, while an arrow inside quotes
        #     still disappears either way. Bare fd dups (>&2, 2>&1)
        #     have no path target and never match the extraction;
        #     process substitution >(...) is an output pipe.
        if [ -z "$RO_REASON" ]; then
          # Quoted /dev paths are unquoted first so `> "/dev/null"`
          # keeps its /dev/* exemption; every other quoted segment
          # becomes a placeholder.
          # [[ ... ]] and (( ... )) are comparison contexts where > is
          # not a redirection; drop them before scanning.
          CMD_ROQ=$(printf '%s' "$CMD" | sed "s|'\(/dev/[^']*\)'|\1|g" | sed 's|"\(/dev/[^"]*\)"|\1|g' | sed "s/'[^']*'/QUOTEDARG/g; s/\"[^\"]*\"/QUOTEDARG/g" | sed -E 's/\[\[[^]]*\]\]//g; s/\(\([^)]*\)\)//g')
          RO_TARGETS=$(printf '%s' "$CMD_ROQ" | grep -oE '(&>>?|[0-9]*>>?\|?)[[:space:]]*[^[:space:]&;|<>()]+' | sed -E 's/^(&>>?|[0-9]*>>?\|?)[[:space:]]*//' || true)
          if [ -n "$RO_TARGETS" ]; then
            while IFS= read -r RO_TGT; do
              [ -z "$RO_TGT" ] && continue
              case "$RO_TGT" in /dev/*) ;; *) RO_REASON="output redirection to '$RO_TGT'"; break ;; esac
            done <<EOF
$RO_TARGETS
EOF
          fi
          case "$CMD_ROQ" in *'>('*) RO_REASON="process substitution output" ;; esac
        fi

        # (b) In-place editors and write utilities.
        if [ -z "$RO_REASON" ] && printf '%s' "$CMD_NOQ" | grep -qE '(^|[[:space:];&|(])(tee|truncate|ln|install|patch|dd)([[:space:]]|$)|(^|[[:space:];&|(])sed[[:space:]]+(--?[a-zA-Z-]+(=[^[:space:]]*)?[[:space:]]+)*(-[a-zA-Z]*i[^[:space:]]*|--in-place(=[^[:space:]]*)?)([[:space:]]|$)|(^|[[:space:];&|(])perl[[:space:]]+[^|;&]*[[:space:]]-[a-zA-Z]*i([[:space:]]|$)'; then
          RO_REASON="in-place edit or write utility"
        fi

        # (c) Inline interpreter code: a one-liner can write through any
        #     API, and its quoted body is invisible to pattern checks.
        # The flag must sit among the interpreter's own leading flags:
        # in `python -m pytest -c pytest.ini` the -c belongs to pytest
        # (a config flag on a read), not to the interpreter, and the
        # first non-flag token (pytest) ends the interpreter's flags.
        if [ -z "$RO_REASON" ] && printf '%s' "$CMD_NOQ" | grep -qE '(^|[[:space:];&|(])(python[0-9.]*|node|deno|bun|ruby|perl|php|bash|sh|zsh|ksh|dash)[[:space:]]+(-[^ec[:space:]][^[:space:]]*[[:space:]]+)*-(e|c)([[:space:]]|$)'; then
          RO_REASON="inline interpreter code"
        fi

        # (d) Git worktree mutations beyond add/commit/push/reset. The
        #     subcommand is parsed (skipping git's global options), not
        #     substring-matched: `git merge-base main HEAD` is a read
        #     and must not match `merge`, while `git switch -c tmp`
        #     mutates and must.
        if [ -z "$RO_REASON" ]; then
          case "$CMD_NOQ" in
            *git\ *)
              GIT_SUBPAIR=$(printf '%s' "$CMD_NOQ" | awk '{
                for (i = 1; i <= NF; i++) {
                  if ($i == "git" || $i ~ /\/git$/) {
                    for (j = i + 1; j <= NF; j++) {
                      if ($j == "-C" || $j == "-c" || $j == "--exec-path" || $j == "--git-dir" || $j == "--work-tree" || $j == "--namespace") { j++; continue }
                      if ($j ~ /^-/) continue
                      print $j, $(j + 1); exit
                    }
                  }
                }
              }' || true)
              GIT_SUB="${GIT_SUBPAIR%% *}"
              GIT_SUB2="${GIT_SUBPAIR#* }"
              [ "$GIT_SUB2" = "$GIT_SUBPAIR" ] && GIT_SUB2=""
              case "$GIT_SUB" in
                checkout|switch|restore|apply|am|merge|rebase|cherry-pick|revert|clean|pull)
                  RO_REASON="git worktree mutation (git $GIT_SUB)"
                  ;;
                stash|worktree)
                  # Read-only inspection forms stay usable during
                  # review/security diagnostics.
                  case "$GIT_SUB2" in
                    list|show) ;;
                    *) RO_REASON="git worktree mutation (git $GIT_SUB)" ;;
                  esac
                  ;;
                branch|tag)
                  # Bare and listing forms are reads; a positional name
                  # or a delete/move flag creates or mutates a ref.
                  case "$GIT_SUB2" in
                    ""|--list|-l|-a|--all|-r|--remotes|-v|-vv|--show-current|--contains|--merged|--no-merged|--points-at|--sort=*) ;;
                    *) RO_REASON="git ref mutation (git $GIT_SUB)" ;;
                  esac
                  ;;
              esac
              ;;
          esac
        fi

        if [ -n "$RO_REASON" ]; then
          echo "BLOCKED [PHASE] Write operation during read-only phase '$CURRENT_PHASE' ($RO_REASON)"
          echo "Category: concurrency-safety"
          echo "Command: $(redact_secrets "$CMD")"
          echo ""
          echo "Action: report this as a finding instead of auto-fixing. The current phase is read-only to prevent race conditions when multiple agents run in parallel."
          echo "Bypass: complete the current phase first (\`bin/session.sh phase-complete $CURRENT_PHASE\`), or end the session if you're not in a sprint."
          audit_trail_append blocked "PHASE-RO"
          exit 1
        fi
      fi
    fi
  fi
fi

# ─── Tier 2.75: Sprint phase gate (global) ─────────────────
# Runs before the allowlist short-circuit and the in-project fast-path so an
# in-project command cannot skip the commit/push gate. Allowlisted safe reads
# are exempt so a command like `grep 'git commit' README.md` is not treated as
# a commit attempt.
PHASE_GATE="$(dirname "$0")/phase-gate.sh"
if [ "$IS_ALLOWLISTED" != true ] && [ -x "$PHASE_GATE" ]; then
  GATE_OUTPUT=$("$PHASE_GATE" "$CMD" 2>&1) || {
    echo "$GATE_OUTPUT"
    exit 1
  }
  # Print warnings (exit 0 with output = advisory)
  [ -n "$GATE_OUTPUT" ] && echo "$GATE_OUTPUT"
fi

# ─── Tier 2.8: Budget gate (global) ────────────────────────
# Runs before the allowlist short-circuit and the in-project fast-path so a
# non-trivial in-project write cannot skip the budget wall. Allowlisted safe
# reads stay exempt (the agent can still run ls / git status to save work),
# matching the documented budget behavior. The budget-management commands the
# block message itself suggests (budget.sh check / set) are also exempt so the
# user can inspect or raise the limit through the guarded path.
# Exempt only the trusted budget.sh check / set invocation. The command must
# name the check or set subcommand, contain no substitution, redirection, or
# chaining (so nothing rides along past the wall, e.g. `budget.sh check $(npm t)`
# or `npm t && budget.sh check`), AND resolve to this Nanostack install's own
# bin/budget.sh — a project's own bin/budget.sh on the same relative path is not
# trusted. A bare `budget.sh` (PATH-dependent) is never exempt.
BUDGET_MGMT=false
case "$CMD" in
  *'$('*|*'`'*|*'<'*|*'>'*|*'&&'*|*';'*|*'|'*|*'&'*) ;;
  *"
"*) ;;
  *)
    BUDGET_BIN="${CMD%% *}"                 # first token
    BUDGET_REST="${CMD#"$BUDGET_BIN"}"; BUDGET_REST="${BUDGET_REST# }"
    BUDGET_SUB="${BUDGET_REST%% *}"         # second token
    case "$BUDGET_SUB" in
      check|set) ;;
      *) BUDGET_BIN="" ;;
    esac
    case "$BUDGET_BIN" in
      */budget.sh) BUDGET_CAND="$BUDGET_BIN" ;;
      *) BUDGET_BIN="" ;;                    # bare name / not a budget.sh path
    esac
    if [ -n "$BUDGET_BIN" ]; then
      case "$BUDGET_CAND" in /*) ;; *) BUDGET_CAND="$PWD/$BUDGET_CAND" ;; esac
      if [ -f "$BUDGET_CAND" ] && [ -f "$NANOSTACK_ROOT/bin/budget.sh" ] \
         && [ "$BUDGET_CAND" -ef "$NANOSTACK_ROOT/bin/budget.sh" ]; then
        BUDGET_MGMT=true
      fi
    fi
    ;;
esac
if [ "$IS_ALLOWLISTED" != true ] && [ "$BUDGET_MGMT" != true ] && [ -z "${NANOSTACK_SKIP_BUDGET:-}" ]; then
  BUDGET_GATE="$(dirname "$0")/budget-gate.sh"
  if [ -x "$BUDGET_GATE" ]; then
    BGATE_OUTPUT=$("$BUDGET_GATE" 2>&1) || {
      echo "$BGATE_OUTPUT"
      exit 1
    }
  fi
fi

# ─── Tier 2: Allowlist short-circuit ───────────────────────
# A safe command exits here, AFTER the global gates above have run.
[ "$IS_ALLOWLISTED" = true ] && exit 0

# ─── Tier 2.5: In-project operations ────────────────────────
# If the command only touches files inside the current git repo,
# it's reviewable via version control. Let it through. Phase
# concurrency above already prevented in-project writes during a
# read phase, so this fast-path only fires when writes are allowed.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

if [ -n "$PROJECT_ROOT" ]; then
  # Commands that write files but stay in-project are Tier 2.5
  # We only check simple file-targeting commands, not pipes or chains
  case "$CMD" in
    # Skip tier 2.5 for chained/piped commands (too hard to analyze)
    *\|*|*\;*|*\&\&*) ;;
    *)
      # If command references files, check they're all in-project
      # Extract paths that look like file references
      ALL_IN_PROJECT=true
      for token in $CMD; do
        # Skip flags and the command itself
        case "$token" in
          -*|"$CMD_BASE") continue ;;
        esac
        # If it looks like a path and exists or starts with project root
        if [ -e "$token" ] || [[ "$token" == /* ]]; then
          REAL_PATH=$(realpath "$token" 2>/dev/null) || REAL_PATH="$token"
          case "$REAL_PATH" in
            "$PROJECT_ROOT"*) ;; # in project
            *) ALL_IN_PROJECT=false ;;
          esac
        fi
      done
      # Don't auto-pass if command has no file args (could be anything)
      if [ "$ALL_IN_PROJECT" = true ] && echo "$CMD" | grep -qE '/|\./' ; then
        exit 0
      fi
      ;;
  esac
fi

# ─── Tier 3: Warn patterns ──────────────────────────────────
# Block patterns already ran at Tier 1.5 before the in-project
# fast-path; only warn patterns need checking here.

WARN_PATTERNS=$(jq -r '.tiers.warn.rules[] | .pattern' "$RULES_FILE" 2>/dev/null)

# Fast pre-check for warn rules
WARN_COMBINED=$(echo "$WARN_PATTERNS" | paste -sd'|' -)
if [ -n "$WARN_COMBINED" ] && echo "$CMD" | grep -qiE -- "$WARN_COMBINED" 2>/dev/null; then
  WARN_IDX=0
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    if echo "$CMD" | grep -qiE -- "$PATTERN" 2>/dev/null; then
      RULE=$(jq -c ".tiers.warn.rules[$WARN_IDX]" "$RULES_FILE")
      ID=$(echo "$RULE" | jq -r '.id')
      DESC=$(echo "$RULE" | jq -r '.description')
      CATEGORY=$(echo "$RULE" | jq -r '.category')

      echo "WARNING [$ID] $DESC"
      echo "Category: $CATEGORY"
      echo "Command: $(redact_secrets "$CMD")"
      echo ""
      echo "Proceeding. Consider the impact."
      exit 0
    fi
    WARN_IDX=$((WARN_IDX + 1))
  done <<< "$WARN_PATTERNS"
fi

# ─── Audit trail ────────────────────────────────────────────
# Append every evaluated command to .nanostack/audit.log (non-blocking).
# Store path and helper already resolved at the top of this script so
# the log line is consistent with the blocked-path helper above.
audit_trail_append allowed ""

# No rules matched. Allow.
exit 0
