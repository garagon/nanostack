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
        # without naming a write utility. Detection runs on a shared
        # normalization (CMD_RON): quoting must not change the verdict,
        # so simple quoted tokens are UNQUOTED ("-c" is the same flag
        # as -c, "tmp" the same ref, "out.txt" the same target,
        # "/dev/null" the same exemption), while quoted segments with
        # spaces or shell metacharacters (code bodies, `grep 'a->b'`
        # patterns) become an inert placeholder. Allowlisted safe reads
        # never reach this tier.
        CMD_RON=$(printf '%s' "$CMD" \
          | sed "s/[$]\x27/\x27/g" \
          | sed "s/'\([-a-zA-Z0-9._/=]*\)'/\1/g" \
          | sed 's/"\([-a-zA-Z0-9._/=]*\)"/\1/g' \
          | sed "s/'[^']*'/QUOTEDARG/g; s/\"[^\"]*\"/QUOTEDARG/g")
        # CMD_SUB is the normalization the awk classifiers (interpreter,
        # git, package-manager) consume. It is built from CMD, not
        # CMD_RON, because command substitution stays ACTIVE inside
        # double quotes (`echo "$(git checkout main)"` runs the
        # checkout), so a double-quoted segment is only collapsed to an
        # inert placeholder when it has no `$` or backtick; otherwise its
        # quotes are stripped and the inner command survives. Single
        # quotes always disable substitution, so single-quoted bodies
        # collapse. Substitution and backtick boundaries become a bare
        # `(` token, and shell operators are space-padded, so a command
        # nested in `$(...)` or written without spaces around operators
        # (`git diff&&git checkout`) sits at its own command position.
        # The redirection scan keeps using CMD_RON, where literal `>`
        # inside double quotes stays hidden.
        # `env -S "python3 -c ..."` tells env to split the quoted string
        # into a command, so unquote the -S argument first; the inner
        # command then sits at a command position for the classifiers.
        _SUB_BT=$(printf '\140')
        _SUB_BS=$(printf '\134')
        CMD_SUB=$(printf '%s' "$CMD" \
          | sed "s/${_SUB_BS}${_SUB_BS}[$](/XX/g; s/${_SUB_BS}${_SUB_BS}[$]/X/g; s/${_SUB_BS}${_SUB_BS}${_SUB_BT}/X/g" \
          | sed "s/[$]\x27/\x27/g; s/[$]\"/\"/g" \
          | sed "s/${_SUB_BS}${_SUB_BS}${_SUB_BS}${_SUB_BS}/@@BS@@/g" \
          | sed "s/${_SUB_BS}${_SUB_BS} /_/g" \
          | sed "s/${_SUB_BS}${_SUB_BS}[;&|()]/X/g" \
          | sed "s/@@BS@@/${_SUB_BS}${_SUB_BS}/g" \
          | sed "s/\"--split-string\"/-S/g; s/'--split-string'/-S/g; s/--split-string[ =]/-S /g; s/--split-string/-S/g; s/\"-S\"/-S/g; s/'-S'/-S/g" \
          | sed "s/-S[[:space:]]*\"\([^\"]*\)\"/-S \1/g; s/-S[[:space:]]*'\([^']*\)'/-S \1/g" \
          | sed "s/${_SUB_BT}/ ( /g" \
          | sed "s/'\([-a-zA-Z0-9._/=]*\)'/\1/g" \
          | sed 's/"\([-a-zA-Z0-9._/=]*\)"/\1/g' \
          | sed "s/\"\([A-Za-z_][A-Za-z0-9_]*=\)[^\"]*\"/\1QUOTEDARG/g" \
          | sed "s/'\([A-Za-z_][A-Za-z0-9_]*=\)[^']*'/\1QUOTEDARG/g" \
          | sed "s/'[^']*'/QUOTEDARG/g" \
          | sed 's/"\([^"]*[$]([^"]*\)"/\1/g' \
          | sed 's/"[^"]*"/QUOTEDARG/g' \
          | sed 's/[$]( / ( /g; s/[$](/ ( /g' \
          | sed 's/&/ \& /g; s/|/ | /g; s/;/ ; /g; s/(/ ( /g; s/)/ ) /g; s/<</ << /g')

        # (a) Output redirection to anything except /dev/*. Bare fd
        #     dups (>&2, 2>&1) have no path target and never match the
        #     extraction; process substitution >(...) is an output
        #     pipe. [[ ... ]] and (( ... )) are comparison contexts
        #     where > is not a redirection; drop them before scanning.
        if [ -z "$RO_REASON" ]; then
          # Drop heredoc bodies (their text is data, not shell syntax, so
          # `cat <<EOF\n a > b \nEOF` is not a redirection), then the
          # escaped \> / \< (POSIX `[ a \> b ]`) and the [[ ]] / (( ))
          # comparison contexts.
          CMD_ROQ=$(printf '%s' "$CMD_RON" | awk '
            {
              if (skip) { if ($0 ~ ("^[[:space:]]*" delim "[[:space:]]*$")) skip = 0; next }
              if (match($0, /<<-?[[:space:]]*[\\'"'"'"]?[^[:space:]<>|&;()]+/)) {
                d = substr($0, RSTART, RLENGTH); gsub(/<<-?[[:space:]]*/, "", d); gsub(/[\\'"'"'"]/, "", d); delim = d; skip = 1
              }
              print
            }' | sed -E 's/\\\\/@@BS@@/g; s/\\[<>]//g; s/@@BS@@/\\/g; s/\[\[[^]]*\]\]//g' \
            | awk '
            # Remove balanced (( ... )) arithmetic contexts (and the $((...))
            # expansion form), which may nest parens: (( (a+1) > b )). A
            # non-balanced regex leaves the trailing > for the redirect scan.
            {
              s = $0; n = length(s); out = ""; i = 1
              while (i <= n) {
                if (substr(s, i, 2) == "((") {
                  depth = 2; j = i + 2
                  while (j <= n && depth > 0) {
                    cj = substr(s, j, 1)
                    if (cj == "(") depth++
                    else if (cj == ")") depth--
                    j++
                  }
                  i = j; continue
                }
                out = out substr(s, i, 1); i++
              }
              print out
            }' \
            | sed -E 's/[0-9]*>&[0-9]+//g; s/[0-9]*[<>]&-//g')
          # fd dups (2>&1, >&2) were removed above, so every remaining
          # redirection (>, >>, &>, >&file, >|) targets a file -- even a
          # numeric filename like `> 1`.
          RO_TARGETS=$(printf '%s' "$CMD_ROQ" | grep -oE '(&>>?|[0-9]*>>?\|?|>&)[[:space:]]*[^[:space:]&;|<>()]+' | sed -E 's/^(&>>?|[0-9]*>>?\|?|>&)[[:space:]]*//' || true)
          if [ -n "$RO_TARGETS" ]; then
            while IFS= read -r RO_TGT; do
              [ -z "$RO_TGT" ] && continue
              # Only genuine device sinks are exempt; a target that walks
              # out of /dev via `..` (e.g. /dev/../tmp/out) writes a real
              # file and is not exempt.
              case "$RO_TGT" in
                */../*|*/..) RO_REASON="output redirection to '$RO_TGT'"; break ;;
                /dev/null|/dev/stdout|/dev/stderr|/dev/zero|/dev/fd/[0-9]*|/dev/std[a-z]*) ;;
                *) RO_REASON="output redirection to '$RO_TGT'"; break ;;
              esac
            done <<EOF
$RO_TARGETS
EOF
          fi
          case "$CMD_ROQ" in *'>('*) RO_REASON="process substitution output" ;; esac
        fi

        # (b) In-place editors and write utilities.
        # sed/perl -i can sit anywhere among the args (after the script
        # in `sed -e '...' -i file`), so scan every arg up to the next
        # operator for an in-place flag rather than requiring it right
        # after the leading options. `-i`/`--in-place` only ever means
        # in-place for these tools, so position does not matter.
        # Write utilities (tee/truncate/ln/install/patch/dd) and the
        # in-place editors (sed/perl/ruby -i) must be the INVOKED command,
        # not an argument: `npm run install` and `printf install` are not
        # the install utility. is_cmd_pos anchors the match to a command
        # position (start, after an operator, or after a wrapper). ruby
        # is also an interpreter below; its -i form mutates while -pe/-ne
        # stream idioms stay usable.
        if [ -z "$RO_REASON" ] && printf '%s' "$CMD_SUB" | awk '
            function basename(s) { sub(/.*\//, "", s); return s }
            function is_cmd_pos(i,    bnd, j, t, tb) {
              # Forward walk from the last operator boundary, consuming
              # wrappers and their option-arguments (timeout -s KILL 5,
              # sudo -u user) plus env-assignments; the token at i is a
              # command position only if nothing else runs before it.
              bnd = 1
              for (j = i - 1; j >= 1; j--)
                if ($j ~ /^(\||\|\||&&|;|&|\(|\))$/ || $j ~ /[|;&()]$/ || $j ~ /^-(exec|execdir|ok|okdir)$/ || $j == "eval" || $j ~ /^(if|then|while|until|do|else|elif|\{|!)$/) { bnd = j + 1; break }
              j = bnd
              while (j < i) {
                t = $j; tb = t; sub(/.*\//, "", tb)
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { j++; continue }
                if (tb ~ /^(command|exec|nohup|setsid|time)$/) { j++; continue }
                if (tb ~ /^(env|sudo|doas|timeout|nice|stdbuf|ionice|chrt|watch|xargs)$/) {
                  j++
                  while (j < i && $j ~ /^-/) {
                    if ($j ~ /^(-u|--unset|-C|--chdir|-g|--group|-p|-U|-r|-t|-h|--user|-s|--signal|-k|--kill-after|--adjustment|-n|--interval|-I|-P|-d|--delimiter|-E|--eofstr|-a|--arg-file|-L|--max-args|--max-procs|--replace)$/) j++
                    j++
                  }
                  if (j < i && $j !~ /^-/ && tb ~ /^(timeout|nice|stdbuf|ionice|chrt)$/) j++
                  continue
                }
                if (tb == "npx" || tb == "bunx") { j++; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package|--node-options|--node-arg)$/) j++; j++ } continue }
                if (tb ~ /^(npm|pnpm|yarn|bun)$/ && $(j + 1) ~ /^(exec|dlx|x)$/) { j += 2; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package)$/) j++; j++ } continue }
                if (tb ~ /^(bundle|bundler)$/ && $(j + 1) == "exec") { j += 2; continue }
                if (t ~ /^-/) { j++; continue }
                return 0
              }
              return (j == i) ? 1 : 0
            }
            {
              for (i = 1; i <= NF; i++) {
                b = basename($i)
                if (!is_cmd_pos(i)) continue
                if (b == "patch") {
                  dr = 0
                  for (k = i + 1; k <= NF; k++) {
                    if ($k ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                    if ($k == "--dry-run" || $k == "-C" || $k == "--check") dr = 1
                  }
                  if (!dr) { found = 1; exit }
                  continue
                }
                if (b ~ /^(tee|truncate|ln|install|dd)$/) { found = 1; exit }
                if (b == "sed" || b == "perl" || b == "ruby") {
                  for (k = i + 1; k <= NF; k++) {
                    t = $k
                    if (t ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                    if ((t !~ /^--/ && t ~ /^-[a-zA-Z0-9]*i[^[:space:]]*$/) || t ~ /^--in-place/) { found = 1; exit }
                  }
                }
              }
            }
            END { exit(found ? 0 : 1) }
          '; then
          RO_REASON="in-place edit or write utility"
        fi

        # (b2) Package-manager subcommands that write dependency trees or
        #      lockfiles. An awk parser skips leading options and
        #      workspace selectors (`pnpm --filter app add`, `yarn
        #      workspace app add`) before classifying the subcommand, and
        #      stops at script-runners (`npm run X`) so a script named
        #      like a subcommand is not misread. Read subcommands a qa
        #      phase needs (test, build, run, ls, vet, check) stay
        #      allowed; only the mutating ones block.
        if [ -z "$RO_REASON" ] && printf '%s' "$CMD_SUB" | awk '
            function basename(s) { sub(/.*\//, "", s); return s }
            function is_cmd_pos(i,    bnd, j, t, tb) {
              # Forward walk from the last operator boundary, consuming
              # wrappers and their option-arguments (timeout -s KILL 5,
              # sudo -u user) plus env-assignments; the token at i is a
              # command position only if nothing else runs before it.
              bnd = 1
              for (j = i - 1; j >= 1; j--)
                if ($j ~ /^(\||\|\||&&|;|&|\(|\))$/ || $j ~ /[|;&()]$/ || $j ~ /^-(exec|execdir|ok|okdir)$/ || $j == "eval" || $j ~ /^(if|then|while|until|do|else|elif|\{|!)$/) { bnd = j + 1; break }
              j = bnd
              while (j < i) {
                t = $j; tb = t; sub(/.*\//, "", tb)
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { j++; continue }
                if (tb ~ /^(command|exec|nohup|setsid|time)$/) { j++; continue }
                if (tb ~ /^(env|sudo|doas|timeout|nice|stdbuf|ionice|chrt|watch|xargs)$/) {
                  j++
                  while (j < i && $j ~ /^-/) {
                    if ($j ~ /^(-u|--unset|-C|--chdir|-g|--group|-p|-U|-r|-t|-h|--user|-s|--signal|-k|--kill-after|--adjustment|-n|--interval|-I|-P|-d|--delimiter|-E|--eofstr|-a|--arg-file|-L|--max-args|--max-procs|--replace)$/) j++
                    j++
                  }
                  if (j < i && $j !~ /^-/ && tb ~ /^(timeout|nice|stdbuf|ionice|chrt)$/) j++
                  continue
                }
                if (tb == "npx" || tb == "bunx") { j++; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package|--node-options|--node-arg)$/) j++; j++ } continue }
                if (tb ~ /^(npm|pnpm|yarn|bun)$/ && $(j + 1) ~ /^(exec|dlx|x)$/) { j += 2; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package)$/) j++; j++ } continue }
                if (tb ~ /^(bundle|bundler)$/ && $(j + 1) == "exec") { j += 2; continue }
                if (t ~ /^-/) { j++; continue }
                return 0
              }
              return (j == i) ? 1 : 0
            }
            function pm_scan(name, start,    k, t, a) {
              for (k = start; k <= NF; k++) {
                t = $k
                if (t ~ /^(&&|\|\||;|\||&|\(|\))$/) return ""
                if (name ~ /^(npm|pnpm|yarn|bun)$/) {
                  if (t == "--filter" || t == "-F" || t == "-w" || t == "--workspace" || t == "-C" || t == "--dir" || t == "--prefix" || t == "--cwd" || t == "--scope") { k++; continue }
                  if (t == "workspace" || t == "workspaces") { k++; continue }
                  # config/cache/version are namespaces: the nested verb
                  # or argument decides. `npm version` alone prints; with
                  # a bump keyword or semver it writes package.json + tag.
                  if (t == "config") { if ($(k + 1) ~ /^(set|delete|rm|edit)$/) return "mutate"; return "" }
                  if (t == "cache") { if ($(k + 1) ~ /^(clean|rm|delete|add|prune)$/) return "mutate"; return "" }
                  if (t == "version") { if ($(k + 1) ~ /^(major|minor|patch|premajor|preminor|prepatch|prerelease|from-git)$/ || $(k + 1) ~ /^v?[0-9]/) return "mutate"; return "" }
                  if (t == "pkg") { if ($(k + 1) ~ /^(set|delete|rm)$/) return "mutate"; return "" }
                  if (t ~ /^(init|create|pack|publish)$/) return "mutate"
                  if (t == "audit") { if ($(k + 1) == "fix") return "mutate"; return "" }
                  if (t ~ /^(run|run-script|exec|test|start|ls|list|view|info|show|outdated|why|search|ping|whoami|help|dlx)$/) return ""
                  if (t ~ /^(ci|i|add|remove|rm|uninstall|un|update|up|upgrade|dedupe|prune|rebuild|link|unlink|install|import|publish)$/) return "mutate"
                } else if (name == "go") {
                  if (t == "get" || t == "install" || t == "generate" || t == "fmt" || t == "clean") return "mutate"
                  if (t == "mod") { if ($(k + 1) ~ /^(tidy|edit|vendor|download|init)$/) return "mutate"; return "" }
                  if (t == "env") { for (a = k + 1; a <= NF; a++) { if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break; if ($a == "-w" || $a == "-u") return "mutate" } return "" }
                  if (t ~ /^(test|build|run|vet|list|version|doc|tool)$/) return ""
                } else if (name ~ /^pip[0-9.]*$/) {
                  if (t ~ /^(install|uninstall|download|wheel)$/) return "mutate"
                  if (t == "config") { if ($(k + 1) ~ /^(set|unset|edit)$/) return "mutate"; return "" }
                  if (t ~ /^(list|show|freeze|check|search|help|inspect)$/) return ""
                } else if (name == "cargo") {
                  if (t ~ /^(add|remove|install|update|uninstall|init|new|publish|generate-lockfile|vendor|yank|fix|clean)$/) return "mutate"
                  if (t == "fmt") { for (a = k + 1; a <= NF; a++) { if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break; if ($a == "--check" || $a == "--dry-run") return "" } return "mutate" }
                  if (t == "clippy") { for (a = k + 1; a <= NF; a++) { if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break; if ($a == "--fix") return "mutate" } return "" }
                  if (t ~ /^(test|build|check|run|doc|tree|metadata|bench)$/) return ""
                } else if (name == "gem") {
                  if (t ~ /^(install|uninstall|update)$/) return "mutate"
                  if (t ~ /^(list|search|info|which|env|help|contents)$/) return ""
                } else if (name == "bundle") {
                  if (t ~ /^(install|update|add)$/) return "mutate"
                  if (t == "config") { if ($(k + 1) ~ /^(set|unset)$/) return "mutate"; return "" }
                  if (t ~ /^(exec|show|list|info|check|help)$/) return ""
                }
              }
              return ""
            }
            {
              for (i = 1; i <= NF; i++) {
                b = basename($i)
                # `python -m pip install` is pip by another name, even with
                # leading python options. The module flag clusters with
                # other no-arg short flags (python3 -Im pip, -Ompip), so a
                # cluster carrying m is treated as the module selector and
                # the rest of the token (or the next token) is the module.
                if (b ~ /^python[0-9.]*$/ && is_cmd_pos(i)) {
                  jj = i + 1
                  while (jj <= NF && $jj ~ /^-/) {
                    if ($jj == "-m" || $jj == "--module") {
                      if ($(jj + 1) == "pip" && pm_scan("pip", jj + 2) == "mutate") { found = 1; exit }
                      break
                    }
                    if ($jj !~ /^--/ && $jj ~ /^-[bdEiIOPqRsSuvxBt]*m/) {
                      rest = substr($jj, index($jj, "m") + 1)
                      if (rest != "") {
                        if (rest == "pip" && pm_scan("pip", jj + 1) == "mutate") { found = 1; exit }
                      } else if ($(jj + 1) == "pip" && pm_scan("pip", jj + 2) == "mutate") { found = 1; exit }
                      break
                    }
                    if ($jj == "-W" || $jj == "-X" || $jj == "-Q" || $jj == "--check-hash-based-pycs") jj += 2; else jj++
                  }
                }
                if (b ~ /^(npm|pnpm|yarn|bun|go|pip[0-9.]*|cargo|gem|bundle)$/ && is_cmd_pos(i)) {
                  if (pm_scan(b, i + 1) == "mutate") { found = 1; exit }
                }
              }
            }
            END { exit(found ? 0 : 1) }
          '; then
          RO_REASON="package-manager dependency write"
        fi

        # (b3) Active command substitutions execute even inside double
        #      quotes, so a write hidden in `$(...)` / backticks runs.
        #      Recurse the guard on each substitution body (depth-guarded)
        #      so the same detectors apply; a body that blocks blocks the
        #      whole command.
        if [ -z "$RO_REASON" ] && [ "${NANOSTACK_GUARD_DEPTH:-0}" -lt 3 ]; then
          # Extract each top-level $(...) body with paren balance (so a
          # nested `$(printf x > $(pwd)/out.txt)` yields the whole outer
          # body, not just the inner $(pwd)), plus backtick bodies. The
          # recursion then re-extracts any nested substitution from each
          # body.
          _SQ=$(printf '\047')
          _BS=$(printf '\134')
          # An even number of backslashes before $( leaves the
          # substitution active (echo \\$(cmd) runs cmd), so collapse \\
          # pairs to a placeholder first; only a remaining single backslash
          # truly escapes the following $(/$/backtick.
          SUBST_BODIES=$(printf '%s' "$CMD" | sed "s/${_BS}${_BS}${_BS}${_BS}/@@BS@@/g" | sed "s/${_BS}${_BS}[$](/XX/g; s/${_BS}${_BS}[$]/X/g; s/${_BS}${_BS}${_SUB_BT}/X/g" | sed "s/@@BS@@/${_BS}${_BS}/g" | awk '
            # Quote-aware: a $(...) inside single quotes is inert and is
            # skipped, but inside double quotes it stays active and is
            # extracted WITH its inner quotes intact, so a nested
            # eval \47git checkout\47 reaches the recursion undamaged.
            {
              s = $0; n = length(s); i = 1; q = ""
              while (i <= n) {
                c = substr(s, i, 1)
                if (q == "\47") { if (c == "\47") q = ""; i++; continue }
                if (q == "" && c == "\47") { q = "\47"; i++; continue }
                if (q == "\42" && c == "\42") { q = ""; i++; continue }
                if (q == "" && c == "\42") { q = "\42"; i++; continue }
                if (c == "$" && substr(s, i + 1, 1) == "(") {
                  # Arithmetic expansion $((...)) starts with $(( and runs
                  # no command, so balance the parens and skip it instead
                  # of recursing on the inert comparison body.
                  if (substr(s, i + 2, 1) == "(") {
                    depth = 0; j = i + 1
                    while (j <= n) {
                      cj = substr(s, j, 1)
                      if (cj == "(") depth++
                      else if (cj == ")") { depth--; if (depth == 0) break }
                      j++
                    }
                    i = j + 1; continue
                  }
                  # Quote-aware paren balance: a ) inside quotes is data,
                  # not a substitution close, so printf ")" > out does not
                  # truncate the body before the redirection.
                  depth = 1; j = i + 2; body = ""; bq = ""
                  while (j <= n && depth > 0) {
                    cj = substr(s, j, 1)
                    if (bq != "") { if (cj == bq) bq = ""; body = body cj; j++; continue }
                    if (cj == "\47" || cj == "\42") { bq = cj; body = body cj; j++; continue }
                    if (cj == "(") depth++
                    else if (cj == ")") { depth--; if (depth == 0) break }
                    body = body cj; j++
                  }
                  print body; i = j + 1; continue
                }
                if (c == "`") {
                  j = i + 1; body = ""
                  while (j <= n && substr(s, j, 1) != "`") { body = body substr(s, j, 1); j++ }
                  print body; i = j + 1; continue
                }
                i++
              }
            }' 2>/dev/null || true)
          # `eval "..."` runs its argument as a command after the hook, so
          # the quoted body is a command to recurse on, not inert text.
          # eval runs its argument after one round of unescaping; grab
          # the remainder after `eval` (quoted or not), strip surrounding
          # quotes, and unescape one backslash level so `eval printf x \>
          # out` recurses as `printf x > out`.
          # Quote-aware: only `eval` appearing OUTSIDE quotes at a command
          # position (start or after an operator) is the shell builtin; an
          # `eval` inside single/double quotes is inert data (e.g. an awk
          # program that prints the word "eval"), so it is skipped.
          EVAL_BODIES=$(printf '%s' "$CMD" | awk '
            {
              s = $0; n = length(s); i = 1; cmdpos = 1
              while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\47") { j = i + 1; while (j <= n && substr(s, j, 1) != "\47") j++; i = j + 1; cmdpos = 0; continue }
                if (c == "\42") { j = i + 1; while (j <= n && substr(s, j, 1) != "\42") j++; i = j + 1; cmdpos = 0; continue }
                if (c ~ /[;|&(){}]/ || c == "\n") { cmdpos = 1; i++; continue }
                if (c == " " || c == "\t") { i++; continue }
                w = ""; k = i
                while (k <= n) { ck = substr(s, k, 1); if (ck == " " || ck == "\t" || ck == "\n" || ck ~ /[;|&(){}\47\42]/) break; w = w ck; k++ }
                if (w == "eval" && cmdpos) {
                  body = ""; m = k; bq = ""
                  while (m <= n) {
                    cm = substr(s, m, 1)
                    if (bq != "") { if (cm == bq) bq = ""; body = body cm; m++; continue }
                    if (cm == "\47" || cm == "\42") { bq = cm; body = body cm; m++; continue }
                    if (cm == ";" || cm == "|" || cm == "&") break
                    body = body cm; m++
                  }
                  print body; i = m; cmdpos = 1; continue
                }
                # Wrappers (command/builtin/exec) and env-assignments keep
                # the next word at a command position, so command eval ...
                # and FOO=1 eval ... are still recognised.
                cmdpos = (w ~ /^(command|builtin|exec|nohup|setsid|time)$/ || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) ? 1 : 0
                i = k
              }
            }' 2>/dev/null | awk '
            # eval removes one level of quoting before re-parsing, so a
            # quoted operator (eval echo x \47>\47 out) becomes an active
            # redirection. Strip one quoting level here so the recursion
            # sees the operators eval would expose; quotes nested inside
            # another quote (grep "\47x > y\47") survive and stay inert.
            {
              s = $0; n = length(s); out = ""; i = 1
              while (i <= n) {
                c = substr(s, i, 1)
                # ANSI-C ($\47...\47) and locale ($"...") quoting: bash drops
                # the leading $ and the quotes, then runs the contents.
                if (c == "$" && (substr(s, i + 1, 1) == "\47" || substr(s, i + 1, 1) == "\42")) { i++; continue }
                if (c == "\47") { i++; while (i <= n && substr(s, i, 1) != "\47") { out = out substr(s, i, 1); i++ } i++; continue }
                if (c == "\42") { i++; while (i <= n && substr(s, i, 1) != "\42") { ch = substr(s, i, 1); if (ch == "\134" && i < n) { i++; out = out substr(s, i, 1); i++; continue } out = out ch; i++ } i++; continue }
                if (c == "\134" && i < n) { i++; out = out substr(s, i, 1); i++; continue }
                out = out c; i++
              }
              print out
            }' 2>/dev/null || true)
          # An eval whose argument comes from an active $()/backtick runs a
          # command we cannot statically recover (eval "$(printf 'git
          # checkout -b tmp')"). The producer alone reads, but eval executes
          # the generated text, so treat such eval bodies as unsafe.
          if [ -z "$RO_REASON" ] && printf '%s' "$EVAL_BODIES" | grep -qE '[$]\(|`' 2>/dev/null; then
            RO_REASON="eval of generated command"
          fi
          SUBST_BODIES=$(printf '%s\n%s' "$SUBST_BODIES" "$EVAL_BODIES")
          if [ -n "$SUBST_BODIES" ]; then
            while IFS= read -r _body; do
              [ -z "$_body" ] && continue
              if ! NANOSTACK_GUARD_DEPTH=$(( ${NANOSTACK_GUARD_DEPTH:-0} + 1 )) "$0" "$_body" >/dev/null 2>&1; then
                RO_REASON="write inside command substitution or eval"
                break
              fi
            done <<EOF
$SUBST_BODIES
EOF
          fi
        fi

        # (c) Inline interpreter code. A one-liner can write through any
        #     API, and its quoted body is a placeholder by now, so the
        #     flags decide. The parser walks each interpreter's OWN
        #     option run, consuming option-arguments (`python -W ignore`,
        #     `node -r ./hook`) so a value is never mistaken for the
        #     script boundary, and stops at `-m module`, a bare script
        #     file, or a subcommand. Inside that run, the code entry
        #     point (`-c` for shells/python, `-e`/`--eval`/`-p` for
        #     node, `eval` subcommand for deno/bun, `-r` for php, a lone
        #     `-` or `<<` for stdin) means inline code. perl/ruby keep
        #     the stream idioms `-pe`/`-ne` usable: only a standalone
        #     `-e` is code there. Interpreters are only classified at a
        #     command position (start, after an operator, or after a
        #     wrapper) so `grep python3 -c file` (count) is not misread.
        if [ -z "$RO_REASON" ] && printf '%s' "$CMD_SUB" | awk '
            function basename(s) { sub(/.*\//, "", s); return s }
            # A command position is the start, just after an operator, or
            # after a run of wrappers / env-assignments. Walk backward so
            # `env FOO=1 python3`, `timeout 5 python3`, and `FOO=1 sudo
            # python3` are recognised; `grep python3 ...` is not.
            function is_cmd_pos(i,    bnd, j, t, tb) {
              # Forward walk from the last operator boundary, consuming
              # wrappers and their option-arguments (timeout -s KILL 5,
              # sudo -u user) plus env-assignments; the token at i is a
              # command position only if nothing else runs before it.
              bnd = 1
              for (j = i - 1; j >= 1; j--)
                if ($j ~ /^(\||\|\||&&|;|&|\(|\))$/ || $j ~ /[|;&()]$/ || $j ~ /^-(exec|execdir|ok|okdir)$/ || $j == "eval" || $j ~ /^(if|then|while|until|do|else|elif|\{|!)$/) { bnd = j + 1; break }
              j = bnd
              while (j < i) {
                t = $j; tb = t; sub(/.*\//, "", tb)
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { j++; continue }
                if (tb ~ /^(command|exec|nohup|setsid|time)$/) { j++; continue }
                if (tb ~ /^(env|sudo|doas|timeout|nice|stdbuf|ionice|chrt|watch|xargs)$/) {
                  j++
                  while (j < i && $j ~ /^-/) {
                    if ($j ~ /^(-u|--unset|-C|--chdir|-g|--group|-p|-U|-r|-t|-h|--user|-s|--signal|-k|--kill-after|--adjustment|-n|--interval|-I|-P|-d|--delimiter|-E|--eofstr|-a|--arg-file|-L|--max-args|--max-procs|--replace)$/) j++
                    j++
                  }
                  if (j < i && $j !~ /^-/ && tb ~ /^(timeout|nice|stdbuf|ionice|chrt)$/) j++
                  continue
                }
                if (tb == "npx" || tb == "bunx") { j++; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package|--node-options|--node-arg)$/) j++; j++ } continue }
                if (tb ~ /^(npm|pnpm|yarn|bun)$/ && $(j + 1) ~ /^(exec|dlx|x)$/) { j += 2; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package)$/) j++; j++ } continue }
                if (tb ~ /^(bundle|bundler)$/ && $(j + 1) == "exec") { j += 2; continue }
                if (t ~ /^-/) { j++; continue }
                return 0
              }
              return (j == i) ? 1 : 0
            }
            # Inline code can attach to the flag (`perl -e'code'` ->
            # token -eQUOTEDARG), so the code-flag tests match a prefix,
            # not an exact token. The double-dash guard keeps `--eval`
            # forms explicit and stops `--experimental-*` matching `-e`.
            function code(name, gi,    j, t) {
              j = gi + 1
              while (j <= NF) {
                t = $j
                # A lone dash, a heredoc, or an explicit stdin pseudo-file
                # all run caller-supplied code from stdin.
                if (t == "-" || t ~ /^<</ || t == "/dev/stdin" || t ~ /^\/dev\/fd\/[0-9]+$/) return 1
                # Input process substitution feeds generated code: a `<`
                # whose source is `<(...)` (after operator spacing: `<`
                # then `(`, or `< <` then `(`) executes the inner output.
                # A plain `< file` redirect is a reviewable file (bare).
                if (t == "<" || t == "<(") {
                  if ($(j + 1) == "(" || t == "<(" || ($(j + 1) == "<" && $(j + 2) == "(")) return 1
                  return 2
                }
                if (t !~ /^-/) {
                  if ((name == "deno" || name == "bun") && t == "eval") return 1
                  return 0
                }
                if (name ~ /^(sh|bash|zsh|ksh|dash)$/) {
                  if (t !~ /^--/ && t ~ /^-[a-zA-Z]*c/) return 1
                  if (t == "-O" || t == "+O" || t == "--rcfile" || t == "--init-file") { j += 2; continue }
                  if (t == "-s" || (t !~ /^--/ && t ~ /^-[a-zA-Z]*s/)) return 2
                  j++; continue
                }
                if (name ~ /^python/) {
                  if (t == "-m" || t == "--module") return 0
                  if (t !~ /^--/ && t ~ /^-[a-zA-Z]*c/) return 1
                  if (t == "-W" || t == "-X" || t == "-Q" || t == "--check-hash-based-pycs") { j += 2; continue }
                  j++; continue
                }
                if (name == "node" || name == "bun") {
                  if (t == "-r" || t == "--require" || t == "-C" || t == "--conditions" || t == "--loader" || t == "--experimental-loader" || t == "--import") { j += 2; continue }
                  if (t !~ /^--/ && t ~ /^-[a-zA-Z]*[ep]/) return 1
                  if (t == "--eval" || t ~ /^--eval=/ || t == "--print" || t == "--exec") return 1
                  j++; continue
                }
                if (name == "deno") {
                  if ((t !~ /^--/ && t ~ /^-e/) || t == "--eval" || t ~ /^--eval=/) return 1
                  j++; continue
                }
                if (name == "perl") {
                  # Clustered short flags: -e/-E is inline code, but -pe/-ne
                  # keep the documented sed-like stream idiom allowed.
                  if (t !~ /^--/ && t ~ /^-[A-Za-z]*[eE]/ && t !~ /[pn]/) return 1
                  if (t == "-I" || t == "-C") { j += 2; continue }
                  j++; continue
                }
                if (name == "ruby") {
                  # Ruby -E is an encoding flag, so only a clustered lower
                  # -e (without the -ne/-pe stream loop) is inline code.
                  if (t !~ /^--/ && t ~ /^-[A-Za-z]*e/ && t !~ /[pn]/) return 1
                  if (t == "-r" || t == "-I" || t == "-C" || t == "-E") { j += 2; continue }
                  j++; continue
                }
                if (name == "php") {
                  if (t !~ /^--/ && t ~ /^-[rRFBE]/) return 1
                  j++; continue
                }
                j++
              }
              # Reached the end with no script file, -m module, or code
              # flag: a bare interpreter. Harmless interactively, but
              # reading code from a pipe (return 2, checked by is_piped).
              return 2
            }
            # True when the command at i is the receiving end of a pipe.
            function is_piped(i,    bnd, j) {
              bnd = 1
              for (j = i - 1; j >= 1; j--)
                if ($j ~ /^(\||\|\||&&|;|&|\(|\))$/ || $j ~ /[|;&()]$/ || $j ~ /^-(exec|execdir|ok|okdir)$/ || $j == "eval" || $j ~ /^(if|then|while|until|do|else|elif|\{|!)$/) { bnd = j + 1; break }
              return (bnd >= 2 && $(bnd - 1) ~ /\|$/) ? 1 : 0
            }
            {
              for (i = 1; i <= NF; i++) {
                b = basename($i)
                if (b ~ /^(python[0-9.]*|node|deno|bun|ruby|perl|php|bash|sh|zsh|ksh|dash)$/ && is_cmd_pos(i)) {
                  r = code(b, i)
                  if (r == 1) { found = 1; exit }
                  if (r == 2 && is_piped(i)) { found = 1; exit }
                }
                # source <(...) and . <(...) execute the process
                # substitution output as shell code, so a write hidden in
                # the generated script runs.
                if ((b == "source" || $i == ".") && is_cmd_pos(i)) {
                  for (k = i + 1; k <= NF; k++) {
                    if ($k ~ /^(&&|\|\||;|\||&)$/) break
                    if ($k == "<(" || ($k == "<" && $(k + 1) == "(")) { found = 1; exit }
                  }
                }
              }
            }
            END { exit(found ? 0 : 1) }
          '; then
          RO_REASON="inline interpreter code"
        fi
        # Code piped into a BARE interpreter (no script file, no -m
        # module): `cat <<EOF | python3`, `curl ... | sh`, `echo code |
        # node` all execute the upstream output as code. A bare
        # interpreter is the receiving end of a single pipe followed by
        # only flags before the next operator or end. An interpreter with
        # a script file or -m runs that and reads the pipe as data, so it
        # stays allowed. Heredoc bodies are dropped first (they belong to
        # the upstream command's stdin, not the interpreter's args) so a
        # flattened body does not make the interpreter look non-bare.
        if [ -z "$RO_REASON" ]; then
          CMD_NOHD=$(printf '%s' "$CMD_RON" | awk '
            {
              if (skip) { if ($0 ~ ("^[[:space:]]*" delim "[[:space:]]*$")) skip = 0; next }
              if (match($0, /<<-?[[:space:]]*[\\'"'"'"]?[A-Za-z0-9_][A-Za-z0-9_.-]*/)) {
                d = substr($0, RSTART, RLENGTH)
                gsub(/<<-?[[:space:]]*[\\'"'"'"]?/, "", d)
                delim = d; skip = 1
              }
              print
            }' | tr '\n' ' ')
          if printf '%s' "$CMD_NOHD" | grep -qE '[^|]\|[[:space:]]*((([^[:space:]]*/)?(env|time|nice|nohup|stdbuf|ionice|setsid|chrt|sudo|doas|command|exec|watch|xargs|timeout)[[:space:]]+([0-9][^[:space:]]*[[:space:]]+)?)|([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+))*([^[:space:]]*/)?(python[0-9.]*|node|deno|bun|ruby|perl|php|bash|sh|zsh|ksh|dash)([[:space:]]+-[^[:space:]]+)*[[:space:]]*($|[|;&])'; then
            RO_REASON="code piped into a bare interpreter"
          fi
        fi

        # (d) Git worktree and ref mutations beyond add/commit/push/
        #     reset. A single awk pass finds the git invocation, skips
        #     git's global options (and their arguments), reads the
        #     subcommand, then classifies. `git merge-base main HEAD`
        #     is a read and must not match `merge`; `git switch -c tmp`
        #     mutates and must. branch/tag need every argument scanned,
        #     not just the first: `git branch -v tmp` still creates a
        #     ref behind a display flag, while `git branch --contains
        #     HEAD` is a filtered list (the positional is consumed by
        #     the read filter).
        if [ -z "$RO_REASON" ]; then
          case "$CMD_SUB" in
            *git*)
              GIT_VERDICT=$(printf '%s' "$CMD_SUB" | awk '
                function basename(s) { sub(/.*\//, "", s); return s }
                # Only a git token at a command position is an invocation;
                # `printf git checkout` or `python3 process.py git ...`
                # carry git as an argument and must not be classified.
                function is_cmd_pos(i,    bnd, j, t, tb) {
                  bnd = 1
                  for (j = i - 1; j >= 1; j--)
                    if ($j ~ /^(\||\|\||&&|;|&|\(|\))$/ || $j ~ /[|;&()]$/ || $j ~ /^-(exec|execdir|ok|okdir)$/ || $j == "eval" || $j ~ /^(if|then|while|until|do|else|elif|\{|!)$/) { bnd = j + 1; break }
                  j = bnd
                  while (j < i) {
                    t = $j; tb = t; sub(/.*\//, "", tb)
                    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { j++; continue }
                    if (tb ~ /^(command|exec|nohup|setsid|time)$/) { j++; continue }
                    if (tb ~ /^(env|sudo|doas|timeout|nice|stdbuf|ionice|chrt|watch|xargs)$/) {
                      j++
                      while (j < i && $j ~ /^-/) {
                        if ($j ~ /^(-u|--unset|-C|--chdir|-g|--group|-p|-U|-r|-t|-h|--user|-s|--signal|-k|--kill-after|--adjustment|-n|--interval|-I|-P|-d|--delimiter|-E|--eofstr|-a|--arg-file|-L|--max-args|--max-procs|--replace)$/) j++
                        j++
                      }
                      if (j < i && $j !~ /^-/ && tb ~ /^(timeout|nice|stdbuf|ionice|chrt)$/) j++
                      continue
                    }
                    if (tb == "npx" || tb == "bunx") { j++; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package|--node-options|--node-arg)$/) j++; j++ } continue }
                    if (tb ~ /^(npm|pnpm|yarn|bun)$/ && $(j + 1) ~ /^(exec|dlx|x)$/) { j += 2; while (j < i && $j ~ /^-/) { if ($j ~ /^(-p|--package)$/) j++; j++ } continue }
                    if (tb ~ /^(bundle|bundler)$/ && $(j + 1) == "exec") { j += 2; continue }
                    if (t ~ /^-/) { j++; continue }
                    return 0
                  }
                  return (j == i) ? 1 : 0
                }
                # Classify branch/tag args: a bare ref name with no list
                # flag creates a ref; delete/move/copy/annotate forms
                # mutate; list and filter flags (and the positional they
                # take) are reads. Tag adds -n (annotation listing).
                function classify_ref(start, istag,    k, t, listmode, mutshort) {
                  # Mutating short-flag letters differ: for branch d/D/m/M
                  # /c/C/f/u (delete/move/copy/force/upstream); for tag
                  # a/s/d/f/F/u/m (annotate/sign/delete/force/file/local
                  # -user/message). -a and -r are READS for branch (all
                  # /remotes) but -a CREATES for tag (annotated).
                  mutshort = istag ? "[adfFum]" : "[dDmMcCfu]"
                  listmode = 0
                  for (k = start; k <= NF; k++) {
                    t = $k
                    # A shell operator ends this invocation; a later git
                    # in the chain is classified on its own pass.
                    if (t ~ /^(&&|\|\||;|\||&|\(|\))$/ || t ~ /[|;&]$/) break
                    if (t ~ /^-/) {
                      if (t ~ /^--(delete|move|copy|edit-description|set-upstream-to|unset-upstream|force|create-reflog|annotate|sign)/) return "mutate"
                      if (t !~ /^--/ && t ~ ("^-[a-zA-Z]*" mutshort)) return "mutate"
                      if (t == "-l" || t == "--list") { listmode = 1; continue }
                      if (!istag && (t == "-r" || t == "--remotes" || t == "-a" || t == "--all")) { listmode = 1; continue }
                      if (istag && t ~ /^-n[0-9]*$/) { listmode = 1; continue }
                      if (istag && (t == "-v" || t == "--verify")) { listmode = 1; continue }
                      if (t ~ /^--(contains|no-contains|merged|no-merged|points-at)/) { listmode = 1; continue }
                      # Output/format flags take a value; consume it so the
                      # value is not read as a new ref name. The = form
                      # carries its own value and consumes nothing.
                      if (t == "--format" || t == "--sort" || t == "--color" || t == "--column" || t == "--abbrev" || t == "--points-at") { k++; continue }
                      continue
                    }
                    if (!listmode) return "mutate"
                  }
                  return "read"
                }
                # Classify one git invocation starting at the git token
                # index gi. Returns "mutate:<sub>" or "" (read / n/a).
                function classify_git(gi,    j, gc, a, hc, ha, cr, cpos) {
                  j = gi + 1
                  while (j <= NF) {
                    # -c key=val / --config-env / --exec-path can inject an
                    # alias, pager, or external helper that executes code,
                    # so they are never a safe read (matching the allowlist).
                    if ($j == "-c" || $j == "--config-env" || $j == "--exec-path" || $j ~ /^--exec-path=/ || $j ~ /^--config-env=/) return "mutate:config-injection"
                    if ($j == "-C" || $j == "--git-dir" || $j == "--work-tree" || $j == "--namespace") { j += 2; continue }
                    if ($j ~ /^-/) { j++; continue }
                    break
                  }
                  if (j > NF) return ""
                  gc = $j
                  # git apply --check / --stat / --numstat / --summary
                  # validate a patch without touching the worktree.
                  if (gc == "apply") {
                    hc = 0; ha = 0
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a == "--apply") ha = 1
                      if ($a == "--check" || $a == "--stat" || $a == "--numstat" || $a == "--summary") hc = 1
                    }
                    # --apply forces application even alongside a report
                    # flag; only a check/stat flag without --apply is read.
                    if (!ha && hc) return ""
                    return "mutate:apply"
                  }
                  if (gc == "clean") {
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a == "--dry-run" || ($a !~ /^--/ && $a ~ /^-[a-z]*n/)) return ""
                    }
                    return "mutate:clean"
                  }
                  if (gc ~ /^(checkout|switch|restore|am|merge|rebase|cherry-pick|revert|pull)$/) return "mutate:" gc
                  # Baseline writes (add/reset/commit/push/stage) were caught
                  # by a substring check that misses global options like
                  # git -C . reset; classify them here so the options are
                  # consumed first.
                  if (gc ~ /^(add|reset|commit|push|stage|restore-staged)$/) return "mutate:" gc
                  if (gc == "format-patch") return "mutate:" gc
                  if (gc == "diff" || gc == "show" || gc == "log") {
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a == "-o" || $a == "--output" || $a ~ /^--output=/) return "mutate:" gc
                      if ($a == "--ext-diff") return "mutate:" gc
                    }
                    return ""
                  }
                  if (gc == "stash" || gc == "worktree") {
                    if ($(j + 1) == "list" || $(j + 1) == "show") return ""
                    return "mutate:" gc
                  }
                  if (gc == "sparse-checkout") {
                    if ($(j + 1) == "list") return ""
                    return "mutate:" gc
                  }
                  if (gc == "archive") {
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a == "-o" || $a ~ /^-o./ || $a == "--output" || $a ~ /^--output=/) return "mutate:" gc
                    }
                    return ""
                  }
                  if (gc == "bisect") {
                    if ($(j + 1) ~ /^(log|view|visualize|help)$/) return ""
                    return "mutate:" gc
                  }
                  if (gc == "reflog") {
                    if ($(j + 1) ~ /^(expire|delete|drop)$/) return "mutate:" gc
                    return ""
                  }
                  if (gc == "maintenance") {
                    if ($(j + 1) ~ /^(run|start|stop|register|unregister)$/) return "mutate:" gc
                    return ""
                  }
                  if (gc ~ /^(write-tree|commit-tree|mktag|mktree|pack-refs)$/) return "mutate:" gc
                  if (gc == "hash-object") {
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a == "-w") return "mutate:" gc
                    }
                    return ""
                  }
                  if (gc == "branch" || gc == "tag") {
                    if (classify_ref(j + 1, (gc == "tag")) == "mutate") return "mutate:" gc
                    return ""
                  }
                  if (gc == "fetch") {
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a == "--dry-run") return ""
                    }
                    return "mutate:fetch"
                  }
                  if (gc ~ /^(mv|rm|init|clone|gc|repack|prune|update-ref|update-index|checkout-index|notes|replace|filter-branch|filter-repo|lfs|fast-import|symbolic-ref)$/) return "mutate:" gc
                  if (gc == "config") {
                    cr = 0; cpos = 0
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a ~ /^(--get|--get-all|--get-regexp|--list|-l|--get-urlmatch|--name-only|--get-color|--get-colorbool|get|list)$/) { cr = 1; continue }
                      if ($a == "set" || $a == "unset" || $a == "--add" || $a == "--unset" || $a == "--unset-all" || $a == "--replace-all" || $a == "--rename-section" || $a == "--remove-section" || $a == "--edit" || $a == "-e") return "mutate:config"
                      if ($a == "--file" || $a == "-f" || $a == "--blob" || $a == "--type" || $a == "-t" || $a == "--default") { a++; continue }
                      if ($a ~ /^-/) continue
                      cpos++
                    }
                    if (cr) return ""
                    if (cpos >= 2) return "mutate:config"
                    return ""
                  }
                  if (gc == "remote") {
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a ~ /^(add|remove|rm|rename|set-url|set-head|set-branches|prune|update)$/) return "mutate:remote"
                    }
                    return ""
                  }
                  if (gc == "submodule") {
                    for (a = j + 1; a <= NF; a++) {
                      if ($a ~ /^(&&|\|\||;|\||&|\(|\))$/) break
                      if ($a ~ /^(add|update|init|sync|set-url|set-branch|deinit|absorbgitdirs|foreach)$/) return "mutate:submodule"
                    }
                    return ""
                  }
                  return ""
                }
                {
                  # Scan EVERY git invocation across all lines: a chained or
                  # multiline read-then-mutate (git diff && git checkout, or
                  # git status\ngit checkout) must still block, so the read
                  # verdict is only emitted in END if no record mutated.
                  for (i = 1; i <= NF; i++) {
                    if ((basename($i) == "git") && is_cmd_pos(i)) {
                      r = classify_git(i)
                      if (r != "") { print r; found = 1; exit }
                    }
                  }
                }
                END { if (!found) print "read" }' || true)
              case "$GIT_VERDICT" in
                mutate:branch|mutate:tag) RO_REASON="git ref mutation (git ${GIT_VERDICT#mutate:})" ;;
                mutate:*) RO_REASON="git worktree mutation (git ${GIT_VERDICT#mutate:})" ;;
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
