#!/usr/bin/env bash
# skill-finalize.sh — defensive telemetry finalize for any nanostack skill.
#
# Usage from a SKILL.md:
#   _F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
#   [ -f "$_F" ] && . "$_F" <skill-name> <outcome>
#   unset _F
#
# Outcome is one of: success, error, abort, unknown. Defaults to success.
#
# Unlike a naive wrapper, this file CANNOT rely on nano_telemetry_finalize
# already being defined. In agents like Claude Code, each Bash tool call
# starts a fresh shell process with no inherited functions or env vars
# from the preamble's shell. This script therefore:
#   1. Respects the kill switches (env var, marker file) on its own.
#   2. Sources telemetry.sh from a sibling directory or the standard
#      install path.
#   3. Restores session state from the .active-<skill>.env file that
#      skill-preamble.sh wrote on disk. Without this restore, finalize
#      would work with an empty session_id and fail to clean up the
#      pending marker the preamble wrote.
#
# If any of the defensive paths fail (helper missing, kill switch active,
# state file missing), this file is a no-op and the skill continues
# normally. The pending marker pruner in telemetry.sh reaps orphan markers
# after 7 days.

_nano_skill_name="${1:-unknown}"
_nano_skill_outcome="${2:-success}"

# Kill switches. Same order and semantics as skill-preamble.sh so there is
# no scenario where the preamble runs but finalize is blocked (or vice versa).
if [ -n "${NANOSTACK_NO_TELEMETRY:-}" ]; then
  unset _nano_skill_name _nano_skill_outcome
  return 0 2>/dev/null || true
fi

if [ -f "${NANO_TEL_HOME:-$HOME/.nanostack}/.telemetry-disabled" ]; then
  unset _nano_skill_name _nano_skill_outcome
  return 0 2>/dev/null || true
fi

# Source telemetry.sh. Try sibling directory first (dev / vendored),
# then standard install path. Missing is fine — we no-op.
_nano_tel_lib=""
_nano_skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -n "$_nano_skill_dir" ] && [ -f "$_nano_skill_dir/telemetry.sh" ]; then
  _nano_tel_lib="$_nano_skill_dir/telemetry.sh"
elif [ -f "$HOME/.claude/skills/nanostack/bin/lib/telemetry.sh" ]; then
  _nano_tel_lib="$HOME/.claude/skills/nanostack/bin/lib/telemetry.sh"
fi

if [ -n "$_nano_tel_lib" ]; then
  # shellcheck disable=SC1090
  . "$_nano_tel_lib" 2>/dev/null

  # Restore session state written by skill-preamble.sh. The file is named
  # per-skill so parallel skills do not overwrite each other. We remove
  # the file after reading so it cannot accumulate; the pending marker
  # pruner handles the case where finalize never ran.
  _nano_state_file="${NANO_TEL_HOME:-$HOME/.nanostack}/.active-$_nano_skill_name.env"
  if [ -f "$_nano_state_file" ]; then
    # shellcheck disable=SC1090
    . "$_nano_state_file" 2>/dev/null
    rm -f "$_nano_state_file" 2>/dev/null
  fi

  command -v nano_telemetry_finalize >/dev/null 2>&1 && \
    nano_telemetry_finalize "$_nano_skill_name" "$_nano_skill_outcome" 2>/dev/null

  unset _nano_state_file
fi

unset _nano_tel_lib _nano_skill_dir _nano_skill_name _nano_skill_outcome
