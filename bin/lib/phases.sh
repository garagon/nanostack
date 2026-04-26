#!/usr/bin/env bash
# phases.sh — Shared phase registry for nanostack lifecycle scripts.
#
# Source this library so every script (save-artifact, restore-context,
# resolve, sprint-journal, analytics, discard-sprint, conductor) sees
# the same view of which phases exist for the current project.
#
# Phases come from two places:
#   - The immutable core list (think, plan, review, qa, security, ship).
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

NANO_CORE_PHASES_LIST="think plan review qa security ship"
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
  return 0
}

# Returns the phase_graph as a JSON array of {name, depends_on}. If
# config has a valid phase_graph, returns it. Otherwise returns the
# canonical default graph that mirrors conductor/bin/sprint.sh:
# think -> plan -> build -> review/qa/security (parallel) -> ship.
# An invalid phase_graph in config falls back to the default and emits
# a stderr warning so a malformed config never produces an invalid
# topology downstream.
nano_phase_graph_json() {
  local config
  config=$(_nano_phases_resolve_config "${1:-}") || true
  local default_graph='[{"name":"think","depends_on":[]},{"name":"plan","depends_on":["think"]},{"name":"build","depends_on":["plan"]},{"name":"review","depends_on":["build"]},{"name":"qa","depends_on":["build"]},{"name":"security","depends_on":["build"]},{"name":"ship","depends_on":["review","qa","security"]}]'
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
  local roots=""
  if [ -n "$config" ] && command -v jq >/dev/null 2>&1; then
    roots=$(jq -r '.skill_roots // [] | .[]' "$config" 2>/dev/null)
  fi
  local default_roots=".nanostack/skills $HOME/.claude/skills $HOME/.agents/skills"
  for root in $roots $default_roots; do
    case "$root" in
      "~/"*) root="$HOME/${root#~/}" ;;
    esac
    if [ -d "$root/$phase" ] && [ -f "$root/$phase/SKILL.md" ]; then
      printf '%s\n' "$root/$phase"
      return 0
    fi
  done
  return 1
}
