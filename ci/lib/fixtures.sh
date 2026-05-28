#!/usr/bin/env bash
# fixtures.sh — Shared fixture builders for nanostack CI harnesses.
#
# Harness Architecture vNext PR 2 (2026-05-28). Several suites built the
# same fixtures by hand: a temp git project, a .nanostack store, valid /
# tampered / missing-integrity artifacts, custom-phase config, sessions.
# When the integrity/hash setup drifts from production, negative tests can
# end up testing a fixture quirk instead of real behavior. This library is
# the single fixture surface; the artifact hashing here reuses the SAME
# canonical path as production (bin/lib/portable.sh's nano_sha256 over
# `jq -Sc 'del(.integrity)'`), so a "verified" fixture verifies under
# bin/lib/artifact-trust.sh exactly as a save-artifact.sh output would.
#
# Source AFTER ci/lib/harness.sh (fixtures use the suite's $NH_TMP root).
# portable.sh is sourced here if the caller has not already loaded it.
#
# Public API:
#   nf_new_git_project <name>                 -> echoes the project path
#   nf_new_store <project_path>               -> mkdir store, echoes path
#   nf_export_store <project_path>            -> export NANOSTACK_STORE, echo
#   nf_save_artifact <phase> <json>           -> real save-artifact.sh, echo path
#   nf_write_artifact <store> <phase> <trust_state> <timestamp> <project>
#                                             -> hand-write an artifact, echo path
#   nf_register_custom_phase <store> <phase> <concurrency>
#   nf_register_phase_graph <store> <json_graph>
#   nf_write_session <store> <workspace> [current_phase]
#   nf_install_example_stack <project> <stack_path>
#
# Trust states for nf_write_artifact: verified | integrity_missing |
# integrity_mismatch.

if [ "${_NF_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_NF_LOADED=1

_NF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NF_REPO="$(cd "$_NF_DIR/../.." && pwd)"
# Canonical hashing comes from production's portable.sh, never a parallel
# shasum/sha256sum branch re-implemented per harness.
if ! declare -F nano_sha256 >/dev/null 2>&1; then
  [ -f "$_NF_REPO/bin/lib/portable.sh" ] && . "$_NF_REPO/bin/lib/portable.sh"
fi
NF_SAVE="$_NF_REPO/bin/save-artifact.sh"

# A temp git project under the suite's $NH_TMP. Does not cd or export;
# the caller decides (use nf_export_store for the store env). Echoes path.
nf_new_git_project() {
  local name="${1:?nf_new_git_project requires a name}"
  local proj="${NH_TMP:?nf_new_git_project requires nh_init first}/$name"
  mkdir -p "$proj"
  ( cd "$proj" && git init -q && git config user.email ci@nf.test && git config user.name ci )
  printf '%s' "$proj"
}

nf_new_store() {
  local store="${1:?nf_new_store requires a project path}/.nanostack"
  mkdir -p "$store"
  printf '%s' "$store"
}

nf_export_store() {
  export NANOSTACK_STORE="${1:?nf_export_store requires a project path}/.nanostack"
  mkdir -p "$NANOSTACK_STORE"
  printf '%s' "$NANOSTACK_STORE"
}

# Write an artifact through the real save-artifact.sh path (validates +
# stamps integrity). Honors the current NANOSTACK_STORE. Echoes the path.
nf_save_artifact() {
  "$NF_SAVE" "${1:?phase}" "${2:?json}"
}

# Hand-write an artifact in a chosen trust state at a chosen filename
# timestamp. Used to exercise trust/freshness paths in isolation. The
# "verified" hash is the production canonical hash, so the file passes
# nano_artifact_trust without a parallel hashing contract.
nf_write_artifact() {
  local store="${1:?store}" phase="${2:?phase}" mode="${3:?trust_state}"
  local ts="${4:?timestamp}" project="${5:?project}"
  mkdir -p "$store/$phase"
  local out="$store/$phase/$ts.json" body
  body=$(printf '{"phase":"%s","project":"%s","summary":"x"}' "$phase" "$project")
  case "$mode" in
    verified)
      local h
      h=$(printf '%s' "$body" | jq -Sc 'del(.integrity)' | nano_sha256 | cut -d' ' -f1)
      printf '%s' "$body" | jq --arg h "$h" '. + {integrity:$h}' > "$out"
      ;;
    integrity_missing)
      printf '%s' "$body" > "$out"
      ;;
    integrity_mismatch)
      printf '%s' "$body" \
        | jq '. + {integrity:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}' > "$out"
      ;;
    *)
      echo "nf_write_artifact: unknown trust state '$mode' (verified|integrity_missing|integrity_mismatch)" >&2
      return 1
      ;;
  esac
  printf '%s' "$out"
}

# Register a custom phase: write its SKILL.md (with concurrency) under the
# store's skills/ and add it to config.json custom_phases (merge-safe).
nf_register_custom_phase() {
  local store="${1:?store}" phase="${2:?phase}" conc="${3:?concurrency}"
  mkdir -p "$store/skills/$phase"
  printf '%s\n' '---' "name: $phase" "description: custom phase $phase" \
    "concurrency: $conc" '---' 'Body.' > "$store/skills/$phase/SKILL.md"
  local cfg="$store/config.json"
  if [ -f "$cfg" ]; then
    jq --arg p "$phase" '.custom_phases = ((.custom_phases // []) + [$p] | unique)' \
      "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  else
    jq -n --arg p "$phase" '{custom_phases:[$p]}' > "$cfg"
  fi
}

# Set the phase_graph in the store's config.json (merge-safe).
nf_register_phase_graph() {
  local store="${1:?store}" graph="${2:?json_graph}" cfg
  cfg="$store/config.json"
  if [ -f "$cfg" ]; then
    jq --argjson g "$graph" '.phase_graph = $g' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  else
    jq -n --argjson g "$graph" '{phase_graph:$g}' > "$cfg"
  fi
}

# Write a session.json. With a current_phase, seeds a single in_progress
# phase_log entry (enough for the guard concurrency check and to mark a
# sprint active for the phase gate). Without one, writes an empty log.
nf_write_session() {
  local store="${1:?store}" ws="${2:?workspace}" phase="${3:-}"
  if [ -n "$phase" ]; then
    jq -n --arg w "$ws" --arg p "$phase" \
      '{workspace:$w, current_phase:$p, phase_log:[{phase:$p, status:"in_progress"}]}' \
      > "$store/session.json"
  else
    jq -n --arg w "$ws" '{workspace:$w, phase_log:[]}' > "$store/session.json"
  fi
}

# Copy an example custom-stack into a project's store skills/ so a suite
# can exercise an installed third-party stack.
nf_install_example_stack() {
  local project="${1:?project}" stack="${2:?stack_path}"
  local store="$project/.nanostack"
  mkdir -p "$store/skills"
  cp -R "$stack"/. "$store/skills/" 2>/dev/null || cp -R "$stack" "$store/skills/"
  printf '%s' "$store/skills"
}
