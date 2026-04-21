#!/usr/bin/env bash
# telemetry.sh — Local-only opt-in telemetry helper.
# Sourced by skill preambles; writes append-only JSONL to the user's home.
# Zero network traffic in V5 Sprint 1; remote sync arrives in Sprint 3.
#
# Privacy contract (enforced by CI lint in .github/workflows/lint.yml):
# this file must never read machine identity, account identity, repo
# identity, or any path outside NANO_TEL_HOME. See TELEMETRY.md for the
# full list of what is never collected.
#
# The frozen v1 schema is declared here on a single machine-parseable
# line so CI can verify the jq filters below only use these fields.
# TELEMETRY_FIELDS_V1: v ts skill session_id nanostack_version os arch duration_s outcome error_class installation_id
#
# Enum whitelists:
#   os           {darwin, linux, unknown}
#   arch         {x86_64, arm64, unknown}
#   outcome      {success, error, abort, unknown}
#   error_class  {phase_timeout, save_failed, lint_error, resolver_error,
#                 budget_exceeded, user_abort, other}
#
# Usage from a skill preamble:
#   source ~/.claude/skills/nanostack/bin/lib/telemetry.sh
#   nano_telemetry_init                     # sets env vars, may prompt
#   nano_telemetry_pending_write "think"    # mark start
#   # ... skill runs ...
#   nano_telemetry_finalize "think" success # mark end, write event

# Never exit the parent shell on a telemetry error. The skill's flow wins.
# We intentionally avoid `set -e` at the top so a bad stat / write never
# aborts the caller.

# ─── Paths (user-scoped, NOT project-scoped) ───────────────────────────
# Telemetry lives in $HOME, not in the project's .nanostack/. Project
# store paths (NANOSTACK_STORE) are for sprint artifacts; telemetry is
# a user preference that spans projects.
NANO_TEL_HOME="${NANO_TEL_HOME:-$HOME/.nanostack}"
NANO_TEL_CONFIG="$NANO_TEL_HOME/user-config.json"
NANO_TEL_INSTALL_ID_FILE="$NANO_TEL_HOME/installation-id"
NANO_TEL_ANALYTICS_DIR="$NANO_TEL_HOME/analytics"
NANO_TEL_JSONL="$NANO_TEL_ANALYTICS_DIR/skill-usage.jsonl"
NANO_TEL_JSONL_MAX_BYTES=10485760  # 10 MB rotation threshold
NANO_TEL_PROMPTED_MARKER="$NANO_TEL_HOME/.telemetry-prompted"

# Resolve nanostack version from VERSION file next to this script's skill dir.
_nano_tel_version() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  if [ -n "$here" ] && [ -f "$here/VERSION" ]; then
    tr -d '[:space:]' < "$here/VERSION" 2>/dev/null
  elif [ -f "$HOME/.claude/skills/nanostack/VERSION" ]; then
    tr -d '[:space:]' < "$HOME/.claude/skills/nanostack/VERSION" 2>/dev/null
  else
    printf 'unknown'
  fi
}

# ─── UUID v4 generation with 3-level fallback ──────────────────────────
# Portable: uuidgen (macOS / coreutils) → /proc/sys/kernel/random/uuid
# (Linux) → manual hex format from /dev/urandom.
nano_uuid_v4() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]'
    return
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid 2>/dev/null
    return
  fi
  if [ -r /dev/urandom ]; then
    # Format 16 random bytes as 8-4-4-4-12 with v4 + RFC4122 variant bits.
    local hex
    hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ ${#hex} -lt 32 ] && return 1
    # Force version 4 (nibble 13 = 4) and variant 10xx (nibble 17 in {8,9,a,b}).
    local v4="${hex:0:12}4${hex:13:3}"
    local variant_nibble="${hex:16:1}"
    case "$variant_nibble" in
      0|1|2|3|4|5|6|7) variant_nibble="8" ;;
      8|9|a|b)         : ;;
      c|d|e|f)         variant_nibble="a" ;;
    esac
    local v4f="${v4}${variant_nibble}${hex:17:3}${hex:20:12}"
    printf '%s-%s-%s-%s-%s' \
      "${v4f:0:8}" "${v4f:8:4}" "${v4f:12:4}" "${v4f:16:4}" "${v4f:20:12}"
    return
  fi
  return 1
}

# ─── Config read / write ───────────────────────────────────────────────
# Config format: {"telemetry": "off|anonymous|community"}
nano_tel_get_tier() {
  if [ ! -f "$NANO_TEL_CONFIG" ]; then
    printf 'off'
    return
  fi
  local t
  t=$(jq -r '.telemetry // "off"' "$NANO_TEL_CONFIG" 2>/dev/null)
  case "$t" in
    off|anonymous|community) printf '%s' "$t" ;;
    *) printf 'off' ;;
  esac
}

# Inline mtime helper so telemetry.sh stays self-contained. Portability
# helpers live in bin/lib/portable.sh, but this file is sourced by skill
# preambles and we want zero cross-file dependencies on the privacy path.
_nano_tel_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Acquire a user-config lock via atomic mkdir. Returns 0 if acquired, 1
# otherwise. Stale locks (older than 30s) are reaped automatically: if
# they exist, a process either crashed mid-write or the system slept for
# longer than we wait. Either way the correct move is to reclaim.
_nano_tel_lock_acquire() {
  local lock="$NANO_TEL_HOME/.config-lock"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if mkdir "$lock" 2>/dev/null; then
      return 0
    fi
    if [ -d "$lock" ]; then
      local now age mt
      now=$(date +%s 2>/dev/null || echo 0)
      mt=$(_nano_tel_mtime "$lock")
      age=$(( now - mt ))
      if [ "$age" -gt 30 ] 2>/dev/null; then
        rmdir "$lock" 2>/dev/null
      fi
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  return 1
}

_nano_tel_lock_release() {
  rmdir "$NANO_TEL_HOME/.config-lock" 2>/dev/null
}

nano_tel_set_tier() {
  local new="$1"
  case "$new" in
    off|anonymous|community) ;;
    *) echo "ERROR: invalid tier '$new' (use off|anonymous|community)" >&2; return 1 ;;
  esac
  mkdir -p "$NANO_TEL_HOME" 2>/dev/null

  # Serialize concurrent set_tier calls. If the lock cannot be acquired
  # after ~3 seconds we proceed unlocked rather than blocking indefinitely;
  # this preserves UX at the cost of last-writer-wins in a pathological
  # edge case (two skills setting different tiers at the exact same time).
  local lock_held=0
  _nano_tel_lock_acquire && lock_held=1

  local existing='{}'
  [ -f "$NANO_TEL_CONFIG" ] && existing=$(cat "$NANO_TEL_CONFIG" 2>/dev/null)
  # Unique tmp per PID so two concurrent processes do not clobber each
  # other's in-flight write even if the lock above failed.
  local tmp="$NANO_TEL_CONFIG.tmp.$$"
  if ! printf '%s' "$existing" | jq --arg t "$new" '.telemetry = $t' \
       > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    [ $lock_held -eq 1 ] && _nano_tel_lock_release
    echo "ERROR: failed to write telemetry config (is jq installed?)" >&2
    return 1
  fi
  if ! mv "$tmp" "$NANO_TEL_CONFIG" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    [ $lock_held -eq 1 ] && _nano_tel_lock_release
    echo "ERROR: failed to persist telemetry config at $NANO_TEL_CONFIG" >&2
    return 1
  fi
  # Tier preference is user-scoped; restrict to owner so shared systems
  # do not expose another user's choice.
  chmod 600 "$NANO_TEL_CONFIG" 2>/dev/null
  [ $lock_held -eq 1 ] && _nano_tel_lock_release

  if [ "$new" = "community" ]; then
    [ ! -f "$NANO_TEL_INSTALL_ID_FILE" ] && _nano_tel_ensure_install_id
  else
    rm -f "$NANO_TEL_INSTALL_ID_FILE" 2>/dev/null
  fi
}

_nano_tel_ensure_install_id() {
  [ -f "$NANO_TEL_INSTALL_ID_FILE" ] && return 0
  local id
  id=$(nano_uuid_v4)
  [ -z "$id" ] && return 1
  mkdir -p "$NANO_TEL_HOME" 2>/dev/null
  printf '%s' "$id" > "$NANO_TEL_INSTALL_ID_FILE" 2>/dev/null
  chmod 600 "$NANO_TEL_INSTALL_ID_FILE" 2>/dev/null
}

# ─── Enum sanitizers ───────────────────────────────────────────────────
# Any value outside the whitelist collapses to a safe default. This
# prevents a surprising string from leaking to disk.
_nano_tel_os() {
  case "$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" in
    darwin) printf 'darwin' ;;
    linux)  printf 'linux' ;;
    *)      printf 'unknown' ;;
  esac
}

_nano_tel_arch() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)  printf 'x86_64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *)             printf 'unknown' ;;
  esac
}

_nano_tel_outcome() {
  case "$1" in
    success|error|abort|unknown) printf '%s' "$1" ;;
    *) printf 'unknown' ;;
  esac
}

_nano_tel_error_class() {
  case "$1" in
    phase_timeout|save_failed|lint_error|resolver_error|budget_exceeded|user_abort|other|"")
      printf '%s' "$1" ;;
    *) printf 'other' ;;
  esac
}

# ─── Pre-V5 detection ──────────────────────────────────────────────────
# Users who installed nanostack pre-V5 already have ~/.nanostack/ with
# content (sessions, config, etc.). They get default silent `off` — no
# prompt. New installs have an empty or missing ~/.nanostack/ on first
# skill run, which triggers the opt-in prompt (handled by the skill).
nano_tel_is_pre_v5_user() {
  # A user is pre-V5 if ~/.nanostack/ exists AND has content OTHER than
  # what this helper would create on a new install (the helper creates
  # user-config.json and analytics/). Anything else that pre-exists is
  # evidence of prior installation.
  [ -d "$NANO_TEL_HOME" ] || return 1
  local found_prior=0
  # Look for any file or dir that wasn't created by telemetry itself.
  while IFS= read -r entry; do
    local base
    base=$(basename "$entry")
    case "$base" in
      user-config.json|analytics|installation-id|.telemetry-prompted) : ;;
      *) found_prior=1; break ;;
    esac
  done < <(find "$NANO_TEL_HOME" -mindepth 1 -maxdepth 1 2>/dev/null)
  [ $found_prior -eq 1 ] && return 0 || return 1
}

# ─── Init (called at skill preamble) ───────────────────────────────────
# Sets the following env vars for the caller:
#   NANO_TEL_TIER            current tier: off|anonymous|community
#   NANO_TEL_SESSION_ID      PID-epoch session id
#   NANO_TEL_START_EPOCH     seconds epoch when this skill started
#   NANO_TEL_SKIP_PROMPT     1 if pre-V5 user, 0 if prompt is appropriate
#   NANO_TEL_INSTALLATION_ID UUID (community only; empty otherwise)
nano_telemetry_init() {
  mkdir -p "$NANO_TEL_HOME" 2>/dev/null
  mkdir -p "$NANO_TEL_ANALYTICS_DIR" 2>/dev/null
  # Restrict directory perms so other local users on shared systems cannot
  # list pending-* markers (which embed session_id) or read event logs.
  chmod 700 "$NANO_TEL_HOME" 2>/dev/null
  chmod 700 "$NANO_TEL_ANALYTICS_DIR" 2>/dev/null

  # Prune .pending-* markers older than 7 days regardless of current tier.
  # Stale markers from crashed sessions would otherwise accumulate forever
  # on installs that sit in `off`, and their context is too old to trust.
  _nano_tel_prune_old_markers

  # Decide if the caller should show the opt-in prompt.
  # Precedence: marker present → never prompt again. Pre-V5 install → silent
  # off + mark prompted. Otherwise (fresh V5 install) → caller should prompt.
  if [ -f "$NANO_TEL_PROMPTED_MARKER" ]; then
    NANO_TEL_SKIP_PROMPT=1
  elif nano_tel_is_pre_v5_user; then
    [ ! -f "$NANO_TEL_CONFIG" ] && nano_tel_set_tier off
    touch "$NANO_TEL_PROMPTED_MARKER" 2>/dev/null
    NANO_TEL_SKIP_PROMPT=1
  else
    NANO_TEL_SKIP_PROMPT=0
  fi

  NANO_TEL_TIER=$(nano_tel_get_tier)
  NANO_TEL_SESSION_ID="$$-$(date +%s 2>/dev/null || echo 0)"
  NANO_TEL_START_EPOCH=$(date +%s 2>/dev/null || echo 0)
  NANO_TEL_INSTALLATION_ID=""
  if [ "$NANO_TEL_TIER" = "community" ] && [ -f "$NANO_TEL_INSTALL_ID_FILE" ]; then
    NANO_TEL_INSTALLATION_ID=$(cat "$NANO_TEL_INSTALL_ID_FILE" 2>/dev/null)
  fi

  export NANO_TEL_TIER NANO_TEL_SESSION_ID NANO_TEL_START_EPOCH \
         NANO_TEL_SKIP_PROMPT NANO_TEL_INSTALLATION_ID
}

# Re-read tier + installation_id from disk. Called before every write so
# an opt-in that happens mid-skill (user picks 'community' at the prompt
# AFTER init has already run) is honored for subsequent events in the
# same skill run.
_nano_tel_refresh_tier() {
  NANO_TEL_TIER=$(nano_tel_get_tier)
  NANO_TEL_INSTALLATION_ID=""
  if [ "$NANO_TEL_TIER" = "community" ] && [ -f "$NANO_TEL_INSTALL_ID_FILE" ]; then
    NANO_TEL_INSTALLATION_ID=$(cat "$NANO_TEL_INSTALL_ID_FILE" 2>/dev/null)
  fi
}

# ─── Pending marker (crash detection) ──────────────────────────────────
# Written at skill start; cleared at skill end. If a skill crashes, the
# marker survives and the next invocation finalizes it as outcome=unknown.
nano_telemetry_pending_write() {
  local skill="$1"
  _nano_tel_refresh_tier
  [ "$NANO_TEL_TIER" = "off" ] && return 0
  local marker="$NANO_TEL_ANALYTICS_DIR/.pending-$NANO_TEL_SESSION_ID"
  mkdir -p "$NANO_TEL_ANALYTICS_DIR" 2>/dev/null
  printf '{"skill":"%s","session_id":"%s","ts":"%s"}' \
    "$skill" "$NANO_TEL_SESSION_ID" "$(_nano_tel_ts)" \
    > "$marker" 2>/dev/null
}

_nano_tel_ts() {
  # Valid ISO-8601 always. If `date` fails, fall back to epoch 0 rather
  # than an "unknown" sentinel so downstream validators do not reject.
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '1970-01-01T00:00:00Z'
}

_nano_tel_rotate_if_large() {
  [ -f "$NANO_TEL_JSONL" ] || return 0
  local size
  size=$(wc -c < "$NANO_TEL_JSONL" 2>/dev/null | tr -d ' ')
  [ -z "$size" ] && return 0
  if [ "$size" -gt "$NANO_TEL_JSONL_MAX_BYTES" ] 2>/dev/null; then
    mv "$NANO_TEL_JSONL" "$NANO_TEL_JSONL.prev" 2>/dev/null
  fi
}

# Drop .pending-* markers older than 7 days. Runs in init regardless of
# tier so markers do not accumulate across long `off` periods.
_nano_tel_prune_old_markers() {
  [ -d "$NANO_TEL_ANALYTICS_DIR" ] || return 0
  find "$NANO_TEL_ANALYTICS_DIR" -maxdepth 1 -name '.pending-*' -type f \
    -mtime +7 -delete 2>/dev/null || true
}

_nano_tel_finalize_stale_markers() {
  local self="$NANO_TEL_ANALYTICS_DIR/.pending-$NANO_TEL_SESSION_ID"
  [ -d "$NANO_TEL_ANALYTICS_DIR" ] || return 0
  local marker skill ts
  # Use find instead of a shell glob. Bash would need `shopt -s nullglob`
  # to avoid iterating the literal pattern when nothing matches; zsh throws
  # on unmatched globs by default. find handles both uniformly.
  while IFS= read -r marker; do
    [ -f "$marker" ] || continue
    [ "$marker" = "$self" ] && continue
    skill=$(jq -r '.skill // "unknown"' "$marker" 2>/dev/null)
    ts=$(jq -r '.ts // ""' "$marker" 2>/dev/null)
    [ -z "$ts" ] && ts=$(_nano_tel_ts)
    _nano_tel_write_event "$skill" "" "unknown" "other" "$ts"
    rm -f "$marker" 2>/dev/null
  done < <(find "$NANO_TEL_ANALYTICS_DIR" -maxdepth 1 -name '.pending-*' -type f 2>/dev/null)
}

# ─── Write a single event to the JSONL ─────────────────────────────────
_nano_tel_write_event() {
  local skill="$1" duration="$2" outcome="$3" error_class="$4" ts_override="$5"
  local ts os arch version
  ts="${ts_override:-$(_nano_tel_ts)}"
  os=$(_nano_tel_os)
  arch=$(_nano_tel_arch)
  version=$(_nano_tel_version)
  outcome=$(_nano_tel_outcome "$outcome")
  error_class=$(_nano_tel_error_class "$error_class")

  mkdir -p "$NANO_TEL_ANALYTICS_DIR" 2>/dev/null
  _nano_tel_rotate_if_large

  local jq_args=(
    -n
    --argjson v 1
    --arg ts "$ts"
    --arg skill "$skill"
    --arg session "$NANO_TEL_SESSION_ID"
    --arg version "$version"
    --arg os "$os"
    --arg arch "$arch"
    --arg outcome "$outcome"
  )
  local filter='{v:$v, ts:$ts, skill:$skill, session_id:$session,
                 nanostack_version:$version, os:$os, arch:$arch,
                 outcome:$outcome}'

  if [ -n "$duration" ]; then
    jq_args+=(--argjson duration "$duration")
    filter="$filter + {duration_s:\$duration}"
  else
    filter="$filter + {duration_s:null}"
  fi

  if [ -n "$error_class" ]; then
    jq_args+=(--arg err "$error_class")
    filter="$filter + {error_class:\$err}"
  else
    filter="$filter + {error_class:null}"
  fi

  if [ "$NANO_TEL_TIER" = "community" ] && [ -n "$NANO_TEL_INSTALLATION_ID" ]; then
    jq_args+=(--arg iid "$NANO_TEL_INSTALLATION_ID")
    filter="$filter + {installation_id:\$iid}"
  else
    filter="$filter + {installation_id:null}"
  fi

  local line
  line=$(jq -c "${jq_args[@]}" "$filter" 2>/dev/null)
  [ -z "$line" ] && return 0

  if [ "${NANO_TEL_DEBUG:-0}" = "1" ]; then
    printf '[telemetry:%s] %s\n' "$NANO_TEL_TIER" "$line" >&2
  fi

  # Ensure JSONL is owner-only before the first append. The file may
  # contain installation_id in community tier; defense-in-depth on shared
  # systems. chmod is idempotent and cheap, so run unconditionally.
  if [ ! -f "$NANO_TEL_JSONL" ]; then
    # Create with restrictive perms before any write.
    (umask 077 && : > "$NANO_TEL_JSONL") 2>/dev/null
  fi
  printf '%s\n' "$line" >> "$NANO_TEL_JSONL" 2>/dev/null
  chmod 600 "$NANO_TEL_JSONL" 2>/dev/null
}

# Fire-and-forget remote sync. Spawns telemetry-log.sh in the background
# and disowns so the parent skill never waits. All safety is inside the
# sender script: rate limit, tier check, kill switches, curl budget.
# Calling this function does not guarantee a send; the sender itself may
# exit silently for many reasons. That is by design.
_nano_tel_send_async() {
  # Respect the same three kill switches as the sender does. Checking here
  # avoids even spawning a process when telemetry is disabled, which is
  # cleaner for `ps` audits on enterprise systems. The marker path uses
  # NANO_TEL_HOME to respect the same env override the helper uses, so
  # a sysadmin testing disable behavior hits the expected path.
  [ -n "${NANOSTACK_NO_TELEMETRY:-}" ] && return 0
  [ -f "${NANO_TEL_HOME:-$HOME/.nanostack}/.telemetry-disabled" ] && return 0

  local sender
  sender="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/telemetry-log.sh"
  if [ ! -x "$sender" ]; then
    # Fallback: look in the standard install path. If neither exists, no send.
    sender="$HOME/.claude/skills/nanostack/bin/telemetry-log.sh"
    [ -x "$sender" ] || return 0
  fi

  # Background + detach. nohup + redirects mean the sender survives if the
  # parent exits and never writes to the parent's stdout/stderr.
  (nohup "$sender" >/dev/null 2>&1 &) >/dev/null 2>&1
  return 0
}

# ─── Finalize (called at skill end) ────────────────────────────────────
nano_telemetry_finalize() {
  local skill="$1" outcome="${2:-success}" error_class="${3:-}"
  _nano_tel_refresh_tier
  [ "$NANO_TEL_TIER" = "off" ] && {
    rm -f "$NANO_TEL_ANALYTICS_DIR/.pending-$NANO_TEL_SESSION_ID" 2>/dev/null
    return 0
  }
  local end duration
  end=$(date +%s 2>/dev/null || echo 0)
  if [ -n "$NANO_TEL_START_EPOCH" ] && [ "$NANO_TEL_START_EPOCH" -gt 0 ] 2>/dev/null; then
    duration=$(( end - NANO_TEL_START_EPOCH ))
    if [ "$duration" -lt 0 ] 2>/dev/null || [ "$duration" -gt 86400 ] 2>/dev/null; then
      duration=""
    fi
  else
    duration=""
  fi
  _nano_tel_write_event "$skill" "$duration" "$outcome" "$error_class" ""
  rm -f "$NANO_TEL_ANALYTICS_DIR/.pending-$NANO_TEL_SESSION_ID" 2>/dev/null
  _nano_tel_finalize_stale_markers

  # Trigger background sync to the Worker. Fire-and-forget; the sender
  # enforces its own rate limit (5 min between attempts) so calling this
  # on every skill completion does not generate traffic proportional.
  _nano_tel_send_async
}
