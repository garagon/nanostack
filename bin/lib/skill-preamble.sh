#!/usr/bin/env bash
# skill-preamble.sh — defensive telemetry init for any nanostack skill.
#
# Usage from a SKILL.md:
#   _P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
#   [ -f "$_P" ] && . "$_P" <skill-name>
#   unset _P
#
# Responsibilities:
#   - Respect all three telemetry kill switches (env var, marker file,
#     file removal). Any one of them makes this a no-op.
#   - Source bin/lib/telemetry.sh if present.
#   - Call nano_telemetry_init and nano_telemetry_pending_write with the
#     skill name.
#
# This file never prompts the user. The opt-in prompt lives in think/SKILL.md
# because it runs once per install; pre-existing users and anyone whose
# first skill is not /think stay at tier=off until they opt in manually
# via `nanostack-config set telemetry ...`.

_nano_skill_name="${1:-unknown}"

# Kill switch 1: environment variable.
if [ -n "${NANOSTACK_NO_TELEMETRY:-}" ]; then
  unset _nano_skill_name
  return 0 2>/dev/null || true
fi

# Kill switch 2: user-level marker file. NANO_TEL_HOME override respected so
# sysadmins testing in a sandbox dir hit the expected path.
if [ -f "${NANO_TEL_HOME:-$HOME/.nanostack}/.telemetry-disabled" ]; then
  unset _nano_skill_name
  return 0 2>/dev/null || true
fi

# Kill switch 3 (implicit): if telemetry.sh is missing, the source below
# is a no-op and none of the nano_telemetry_* functions ever become defined.
# Check the sibling directory first (dev / vendored installs) then the
# standard install path. This keeps tests and production on the same path
# logic without special-casing.
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
  nano_telemetry_init 2>/dev/null
  command -v nano_telemetry_pending_write >/dev/null 2>&1 && \
    nano_telemetry_pending_write "$_nano_skill_name" 2>/dev/null

  # Persist init state to disk so skill-finalize.sh can restore it in a
  # separate shell invocation. In agents like Claude Code each Bash tool
  # call starts a fresh process with no inherited env; without this file
  # the finalize step cannot link to the pending marker written here.
  # One file per skill name; accumulates only if finalize never runs (which
  # the pruner in telemetry.sh cleans up after 7 days).
  if command -v nano_telemetry_init >/dev/null 2>&1 && \
     [ -n "${NANO_TEL_SESSION_ID:-}" ]; then
    _nano_state_dir="${NANO_TEL_HOME:-$HOME/.nanostack}"
    _nano_state_file="$_nano_state_dir/.active-$_nano_skill_name.env"
    mkdir -p "$_nano_state_dir" 2>/dev/null
    {
      printf 'NANO_TEL_SESSION_ID=%s\n' "$NANO_TEL_SESSION_ID"
      printf 'NANO_TEL_START_EPOCH=%s\n' "$NANO_TEL_START_EPOCH"
      printf 'NANO_TEL_TIER=%s\n' "$NANO_TEL_TIER"
      printf 'NANO_TEL_INSTALLATION_ID=%s\n' "${NANO_TEL_INSTALLATION_ID:-}"
    } > "$_nano_state_file" 2>/dev/null
    chmod 600 "$_nano_state_file" 2>/dev/null
    unset _nano_state_dir _nano_state_file
  fi
fi

unset _nano_tel_lib _nano_skill_dir _nano_skill_name
