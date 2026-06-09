#!/usr/bin/env bash
# phases.sh — Shared phase registry for nanostack lifecycle scripts.
#
# Source this library so every script (save-artifact, restore-context,
# resolve, sprint-journal, analytics, discard-sprint, conductor) sees
# the same view of which phases exist for the current project.
#
# Phases come from two places:
#   - The immutable core list (think, plan, review, security, qa, ship).
#   - The .custom_phases array in .nanostack/config.json (project) or
#     ~/.nanostack/config.json (global fallback).
#
# Custom phase names must match ^[a-z][a-z0-9-]*$. Invalid names are
# silently dropped with a stderr warning; the lifecycle scripts must
# keep working even when config is malformed.
#
# Public functions:
#   nano_core_phases                 # echoes the six built-in phases
#   nano_custom_phases [config]      # echoes registered custom phases
#   nano_all_phases    [config]      # echoes core + custom (deduped)
#   nano_phase_exists  <name> [cfg]  # exit 0 if known
#   nano_phase_kind    <name> [cfg]  # echoes core | custom | unknown
#   nano_phase_graph_json [cfg]      # echoes phase_graph JSON array
#   nano_phase_skill_path <name> [cfg] # echoes resolved skill dir or exit 1

# Idempotent guard: skip if already sourced in this shell.
if [ "${_NANO_PHASES_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NANO_PHASES_LOADED=1

NANO_CORE_PHASES_LIST="think plan review security qa ship"
NANO_PHASE_NAME_RE='^[a-z][a-z0-9-]*$'

# Resolve config path. Order: explicit arg, $NANOSTACK_STORE/config.json,
# then ~/.nanostack/config.json. Returns 1 if none exists.
_nano_phases_resolve_config() {
  local explicit="${1:-}"
  if [ -n "$explicit" ] && [ -f "$explicit" ]; then
    printf '%s\n' "$explicit"; return 0
  fi
  if [ -n "${NANOSTACK_STORE:-}" ] && [ -f "$NANOSTACK_STORE/config.json" ]; then
    printf '%s\n' "$NANOSTACK_STORE/config.json"; return 0
  fi
  if [ -n "${HOME:-}" ] && [ -f "$HOME/.nanostack/config.json" ]; then
    printf '%s\n' "$HOME/.nanostack/config.json"; return 0
  fi
  return 1
}

nano_core_phases() {
  printf '%s\n' "$NANO_CORE_PHASES_LIST"
}

nano_custom_phases() {
  local config
  config=$(_nano_phases_resolve_config "${1:-}") || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local raw
  raw=$(jq -r '.custom_phases // [] | .[]' "$config" 2>/dev/null) || return 0
  [ -z "$raw" ] && return 0
  local result=""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    case " $NANO_CORE_PHASES_LIST " in
      *" $name "*) continue ;;
    esac
    if ! printf '%s' "$name" | grep -qE "$NANO_PHASE_NAME_RE"; then
      printf 'phases: rejecting invalid custom phase name "%s"\n' "$name" >&2
      continue
    fi
    case " $result " in
      *" $name "*) continue ;;
    esac
    if [ -z "$result" ]; then result="$name"; else result="$result $name"; fi
  done <<< "$raw"
  [ -n "$result" ] && printf '%s\n' "$result"
  return 0
}

nano_all_phases() {
  local custom
  custom=$(nano_custom_phases "${1:-}")
  if [ -n "$custom" ]; then
    printf '%s %s\n' "$NANO_CORE_PHASES_LIST" "$custom"
  else
    printf '%s\n' "$NANO_CORE_PHASES_LIST"
  fi
}

nano_phase_exists() {
  local name="${1:?nano_phase_exists requires a phase name}"
  local all
  all=$(nano_all_phases "${2:-}")
  case " $all " in
    *" $name "*) return 0 ;;
    *) return 1 ;;
  esac
}

nano_phase_kind() {
  local name="${1:?nano_phase_kind requires a phase name}"
  case " $NANO_CORE_PHASES_LIST " in
    *" $name "*) printf 'core\n'; return 0 ;;
  esac
  local custom
  custom=$(nano_custom_phases "${2:-}")
  case " $custom " in
    *" $name "*) printf 'custom\n'; return 0 ;;
  esac
  printf 'unknown\n'
  return 1
}

# Internal: graph nodes accept core phases plus the conductor's "build"
# stage (which produces no artifact and is not in nano_core_phases).
_NANO_GRAPH_BUILTIN_NODES="$NANO_CORE_PHASES_LIST build"

_nano_graph_node_known() {
  local name="$1" config="${2:-}"
  case " $_NANO_GRAPH_BUILTIN_NODES " in
    *" $name "*) return 0 ;;
  esac
  local custom
  custom=$(nano_custom_phases "$config")
  case " $custom " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

# Validates a phase_graph JSON array. Each entry must have a string
# .name matching the phase regex AND known to the registry (core,
# custom, or the conductor's "build" stage). Every .depends_on[] entry
# must reference a name that appears elsewhere in the same graph.
# Returns 0 on success, 1 on failure (silently — caller emits the user
# warning).
_nano_phase_graph_is_valid() {
  local graph="$1" config="${2:-}"
  command -v jq >/dev/null 2>&1 || return 1
  echo "$graph" | jq -e '
    type == "array"
    and length > 0
    and all(
      .[];
      (.name | type == "string")
      and (.depends_on | type == "array")
      and (.depends_on | all(type == "string"))
    )
  ' >/dev/null 2>&1 || return 1
  # Duplicate names are nonsensical: which entry's depends_on wins for
  # the same phase? Reject up front so conductor scheduling never has
  # to disambiguate.
  if ! echo "$graph" | jq -e '([.[].name] | unique | length) == length' >/dev/null 2>&1; then
    return 1
  fi
  local names dep_targets
  names=$(echo "$graph" | jq -r '.[].name')
  dep_targets=$(echo "$graph" | jq -r '[.[].name] | join("\n")')
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! printf '%s' "$name" | grep -qE "$NANO_PHASE_NAME_RE"; then
      return 1
    fi
    if ! _nano_graph_node_known "$name" "$config"; then
      return 1
    fi
  done <<< "$names"
  local deps
  deps=$(echo "$graph" | jq -r '.[].depends_on[]?')
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if ! echo "$dep_targets" | grep -qFx "$dep"; then
      return 1
    fi
  done <<< "$deps"
  # Cycle detection via Kahn's algorithm. Iteratively strip zero-deps
  # nodes; if no progress is possible while nodes remain, a cycle
  # exists. Conductor relies on the graph being a DAG so the topological
  # batching never deadlocks.
  if ! echo "$graph" | jq -e '
    def acyclic:
      . as $g
      | reduce range(0; $g | length + 1) as $_ (
          $g;
          if length == 0 then .
          else
            ([.[] | select(.depends_on | length == 0) | .name]) as $leaves
            | if ($leaves | length) == 0 then null
              else
                [.[]
                  | select(.name as $n | ($leaves | index($n)) | not)
                  | .depends_on |= map(select(. as $d | ($leaves | index($d)) | not))
                ]
              end
          end
        )
      | . != null and length == 0;
    acyclic
  ' >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Returns the phase_graph as a JSON array of {name, depends_on}. If
# config has a valid phase_graph, returns it. Otherwise returns the
# canonical default graph that mirrors conductor/bin/sprint.sh:
# think -> plan -> build -> review/security/qa (parallel) -> ship.
# An invalid phase_graph in config falls back to the default and emits
# a stderr warning so a malformed config never produces an invalid
# topology downstream.
nano_phase_graph_json() {
  local config
  config=$(_nano_phases_resolve_config "${1:-}") || true
  # Node order under `review`/`security`/`qa` follows the canonical
  # sprint order published everywhere user-facing (README, release
  # notes, /feature, next-step.sh): review -> security -> qa -> ship.
  # Next-phase walks graph order, so the graph IS the progression
  # contract. required_before_ship ends up as ["review","security",
  # "qa"] (graph-derived order), matching the legacy fallback in
  # bin/next-step.sh; consumers that need set semantics work either
  # way. An earlier form of this graph kept qa before security, which
  # contradicted the public copy on every release surface — the
  # reconcile-canonical-sprint-order PR aligned runtime to the docs.
  local default_graph='[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"review","depends_on":["build"]},{"name":"security","depends_on":["build"]},{"name":"qa","depends_on":["build"]},{"name":"ship","depends_on":["review","security","qa"]}]'
  if [ -n "$config" ] && command -v jq >/dev/null 2>&1; then
    local graph
    graph=$(jq -c '.phase_graph // empty' "$config" 2>/dev/null)
    if [ -n "$graph" ] && [ "$graph" != "null" ]; then
      if _nano_phase_graph_is_valid "$graph" "$config"; then
        printf '%s\n' "$graph"
        return 0
      fi
      printf 'phases: rejecting invalid phase_graph in config; using default graph\n' >&2
    fi
  fi
  printf '%s\n' "$default_graph"
}

# Compute the ready phases for a phase_graph given the set of phases
# that have already been completed (and optionally the phases currently
# in_progress). A phase is "ready" when every entry in its depends_on
# is in the completed set AND the phase itself is neither completed nor
# in_progress. Returns the ready phase names, one per line, in the
# graph's declared order so callers that need a single "next_phase"
# pick the first line.
#
# The conductor's "build" stage produces no session-tracked artifact
# (developers do the work, no phase-complete call lands), so the helper
# treats "build" as auto-satisfied for dependency checks unless the
# caller passes it explicitly in completed. Without that escape hatch,
# the default sprint graph (review/security/qa depend on build) would
# never advance.
#
# Arguments:
#   $1  graph JSON array of {name, depends_on}
#   $2  completed JSON array of phase names
#   $3  in_progress JSON array of phase names (optional, defaults to [])
#
# PR 4 of the 2026-05-10 architecture audit: replaces the hardcoded
# next-phase case statement in bin/session.sh with registry-aware
# traversal so custom workflow stacks get the same lifecycle support
# as the built-in sprint.
nano_phase_ready_from_graph() {
  local graph="${1:?nano_phase_ready_from_graph requires a graph JSON argument}"
  local completed="${2:-[]}"
  local in_progress="${3:-[]}"
  command -v jq >/dev/null 2>&1 || return 1
  # IN() is used instead of `index()` because some jq builds (1.6 on
  # macOS in particular) refuse `array | index(.field)` when the field
  # is computed inside a .[] context, while IN() accepts the stream
  # syntax cleanly. The filter does not need the returned position,
  # only set membership.
  #
  # "build" is auto-promoted into the satisfied set, but ONLY when its
  # own depends_on entries are all satisfied. Without that gate the
  # default sprint graph (review/security/qa depend on build, build
  # depends on plan) would report review/security/qa as ready right
  # after /think completes, even though /plan has not run yet.
  echo "$graph" | jq -r \
    --argjson done "$completed" \
    --argjson active "$in_progress" \
    '
    . as $graph
    | $done as $base
    # Auto-promote "build" when its declared deps (if any) are all
    # already completed AND build itself is not currently in_progress.
    # The in_progress check is the load-bearing piece: a caller can
    # record the build handoff with session.sh phase-start build, and
    # treating that as satisfied would unblock review/security/qa
    # while build is still running. Codex caught the racy promotion
    # on the PR 4 sixth review pass. Treat a "build"-less graph as a
    # no-op for this step.
    | (
        ($graph | map(select(.name == "build")) | first // null) as $build_node
        | if $build_node == null then $base
          else
            ($build_node.depends_on // []) as $bdeps
            | if (($bdeps | all(. as $d | $base | any(. == $d)))
                  and (($active | any(. == "build")) | not))
              then ($base + ["build"] | unique)
              else $base
              end
          end
      ) as $satisfied
    | [.[]
        | select(
            (.name | IN($satisfied[]) | not)
            and (.name | IN($active[]) | not)
            and ((.depends_on // []) | all(. as $d | $satisfied | any(. == $d)))
          )
        | .name
      ]
    | .[]
    ' 2>/dev/null
}

# Topologically sort a phase_graph and emit the phase names, one per
# line. Uses Kahn's algorithm (the same shape as the cycle check in
# the validator). The graph is assumed valid; pass a graph that has
# already been validated, or call _nano_phase_graph_is_valid first.
# Returns 1 if the graph contains a cycle (no progress possible).
nano_phase_graph_sort() {
  local graph="${1:?nano_phase_graph_sort requires a graph JSON argument}"
  command -v jq >/dev/null 2>&1 || return 1
  echo "$graph" | jq -er '
    def topo_sort:
      . as $g
      | reduce range(0; ($g | length) + 1) as $_ (
          {sorted: [], remaining: $g};
          .remaining as $r
          | if ($r | length) == 0 then .
            else
              ($r | [.[] | select(.depends_on | length == 0) | .name]) as $leaves
              | if ($leaves | length) == 0 then null
                else
                  {
                    sorted: (.sorted + $leaves),
                    remaining: [
                      $r[]
                      | select(.name as $n | ($leaves | index($n)) | not)
                      | .depends_on |= map(select(. as $d | ($leaves | index($d)) | not))
                    ]
                  }
                end
            end
        )
      | if . == null then error("cycle") else .sorted end;
    topo_sort | .[]
  ' 2>/dev/null
}

# Best-effort skill-path resolution. Core phases live one directory
# above bin/ (the nanostack repo). Custom phases live under skill_roots
# from config, falling back to .nanostack/skills, ~/.claude/skills,
# ~/.agents/skills. Returns the directory path on stdout, exit 1 if
# nothing matches.
nano_phase_skill_path() {
  local phase="${1:?nano_phase_skill_path requires a phase name}"
  local config
  config=$(_nano_phases_resolve_config "${2:-}") || true
  local repo_root="${NANOSTACK_ROOT:-}"
  if [ -z "$repo_root" ]; then
    repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || repo_root=""
  fi
  case " $NANO_CORE_PHASES_LIST " in
    *" $phase "*)
      if [ -n "$repo_root" ] && [ -d "$repo_root/$phase" ]; then
        printf '%s\n' "$repo_root/$phase"
        return 0
      fi
      return 1
      ;;
  esac

  # Membership in nano_custom_phases is the trust boundary: only an
  # explicitly registered custom phase is allowed to search user-owned
  # skill roots (skill_roots, store/skills, ~/.claude/skills, ~/.agents/
  # skills). An unregistered phase that happens to share a name with an
  # unrelated user-installed skill must NOT be silently shadowed,
  # otherwise the bundled `feature`/`doctor` read-only behavior could
  # be overridden by an arbitrary same-named directory. Codex flagged
  # this on the PR 1 sixth pass.
  local is_registered_custom=0
  local _custom_list
  _custom_list=$(nano_custom_phases "$config" 2>/dev/null)
  case " $_custom_list " in
    *" $phase "*) is_registered_custom=1 ;;
  esac

  if [ "$is_registered_custom" = "0" ]; then
    # Not core, not registered as custom — fall back to repo-bundled
    # non-core skills only. This preserves the old raw lookup behavior
    # for feature/doctor/help/compound/start while preventing shadowing
    # by unrelated user-installed skills with the same directory name.
    if [ -n "$repo_root" ] && [ -d "$repo_root/$phase" ] && [ -f "$repo_root/$phase/SKILL.md" ]; then
      printf '%s\n' "$repo_root/$phase"
      return 0
    fi
    return 1
  fi

  # Build a newline-delimited candidate list so paths with spaces (a
  # $HOME like "Hello World" or a store under "My Drive") survive
  # iteration. Previous form was a single space-separated string fed
  # into `for root in $list`, which silently dropped split halves and
  # made guard concurrency a no-op for those users. Codex caught this
  # while reviewing the registry-aware guard tier.
  local candidates=""
  _phases_append_root() {
    local candidate="$1"
    # Both early returns are successful no-ops, not errors. A bare
    # `return` would inherit the previous test's exit status (1 when
    # the candidate is non-empty), and callers running under `set -e`
    # would treat the helper as failed. Codex caught this on the
    # PR 1 second pass with the standard $NANOSTACK_STORE == config_dir
    # case where the dedup branch fires.
    [ -z "$candidate" ] && return 0
    # Dedup: skip if the exact path is already on the list.
    case $'\n'"$candidates"$'\n' in
      *$'\n'"$candidate"$'\n'*) return 0 ;;
    esac
    if [ -z "$candidates" ]; then
      candidates="$candidate"
    else
      candidates="$candidates"$'\n'"$candidate"
    fi
    return 0
  }

  # 1. Configured skill_roots (user override), newline-separated from jq.
  if [ -n "$config" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      _phases_append_root "$line"
    done < <(jq -r '.skill_roots // [] | .[]' "$config" 2>/dev/null)
  fi
  # 2. <store>/skills — same path bin/create-skill.sh writes to. This is
  #    the load-bearing one: a scaffold from a git subdir or a no-git
  #    project lives here, not under cwd/.nanostack.
  if [ -n "${NANOSTACK_STORE:-}" ]; then
    _phases_append_root "$NANOSTACK_STORE/skills"
  fi
  # 3. <config-dir>/skills — covers a global config under $HOME/.nanostack
  #    that the resolver picked up via _nano_phases_resolve_config.
  if [ -n "$config" ]; then
    local config_dir
    config_dir=$(dirname "$config")
    _phases_append_root "$config_dir/skills"
  fi
  # 4. cwd-relative .nanostack/skills (legacy, retained for back-compat).
  _phases_append_root ".nanostack/skills"
  # 5. $HOME/.claude/skills + $HOME/.agents/skills (agent install
  #    locations for skills shipped outside .nanostack).
  _phases_append_root "$HOME/.claude/skills"
  _phases_append_root "$HOME/.agents/skills"

  while IFS= read -r root; do
    [ -z "$root" ] && continue
    case "$root" in
      "~/"*) root="$HOME/${root#~/}" ;;
    esac
    if [ -d "$root/$phase" ] && [ -f "$root/$phase/SKILL.md" ]; then
      unset -f _phases_append_root
      printf '%s\n' "$root/$phase"
      return 0
    fi
  done <<< "$candidates"
  unset -f _phases_append_root
  return 1
}

# Resolve a phase's declared concurrency from its skill's SKILL.md
# frontmatter. Echoes the value (typically "read", "write", or
# "exclusive") and returns 0 when found. Returns 1 with NO output when
# the phase, its skill directory, its SKILL.md, or the concurrency
# field cannot be resolved.
#
# Both built-in and registered custom phases resolve through
# nano_phase_skill_path, so a custom read-only phase gets the same
# treatment as the built-in ones. The lookup deliberately FAILS OPEN
# (returns 1, no output) on a missing or malformed skill: the guard
# hooks call this on every tool invocation, and a bad custom skill must
# never brick tool use. Callers treat a non-zero return as "no
# read-only constraint applies", preserving pre-helper behavior.
nano_phase_concurrency() {
  local phase="${1:-}"
  [ -n "$phase" ] || return 1
  local skill_dir
  skill_dir=$(nano_phase_skill_path "$phase" "${2:-}" 2>/dev/null) || return 1
  [ -n "$skill_dir" ] && [ -f "$skill_dir/SKILL.md" ] || return 1
  # Parse concurrency only from a CLOSED frontmatter block. A malformed
  # SKILL.md that opens '---' but never closes it must fail open: awk
  # buffers the value and emits it only after it has seen the closing
  # delimiter, so a stray 'concurrency:' line in the body of an unclosed
  # block can never enforce a read-only phase.
  local conc
  conc=$(awk '
    NR==1 && $0 !~ /^---[[:space:]]*$/ { exit }
    NR==1 { next }
    /^---[[:space:]]*$/ { closed=1; exit }
    /^concurrency:/ && !found { val=$0; sub(/^concurrency:[[:space:]]*/, "", val); found=1 }
    END { if (closed && found) print val }
  ' "$skill_dir/SKILL.md" 2>/dev/null)
  conc=$(printf '%s' "$conc" | tr -d '[:space:]')
  [ -n "$conc" ] || return 1
  printf '%s\n' "$conc"
  return 0
}

# Resolve the active session's current phase and its concurrency.
# Reads the session JSON from $1 (default $NANOSTACK_STORE/session.json)
# and emits a single tab-delimited record:
#   <phase><TAB><concurrency>
#
# Returns 0 ONLY when an active current_phase exists and its concurrency
# resolves. Returns 1 (no output) when there is no session, no current
# phase, the current phase is the conductor's no-skill "build" stage, or
# the concurrency cannot be resolved. Stays silent on every non-active
# state because the Bash and Write/Edit guard hooks call this on every
# tool invocation — this is the single shared lookup that keeps the two
# hooks from drifting on what "read-only phase" means.
nano_active_phase_concurrency() {
  local session="${1:-${NANOSTACK_STORE:-}/session.json}"
  [ -n "$session" ] && [ -f "$session" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local phase
  phase=$(jq -r '.current_phase // ""' "$session" 2>/dev/null)
  [ -n "$phase" ] && [ "$phase" != "null" ] && [ "$phase" != "build" ] || return 1
  local conc
  conc=$(nano_phase_concurrency "$phase") || return 1
  printf '%s\t%s\n' "$phase" "$conc"
  return 0
}
