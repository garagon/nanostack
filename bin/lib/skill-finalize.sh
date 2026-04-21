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
# This file is a thin wrapper around nano_telemetry_finalize that tolerates
# a missing telemetry helper. If telemetry.sh was not sourced (kill switch
# active, file removed, etc.), nano_telemetry_finalize will not be defined
# and this file becomes a no-op.

_nano_skill_name="${1:-unknown}"
_nano_skill_outcome="${2:-success}"

command -v nano_telemetry_finalize >/dev/null 2>&1 && \
  nano_telemetry_finalize "$_nano_skill_name" "$_nano_skill_outcome" 2>/dev/null

unset _nano_skill_name _nano_skill_outcome
