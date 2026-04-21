#!/usr/bin/env bash
# telemetry-config.sh — user-facing CLI for telemetry preferences.
# Usage:
#   telemetry-config.sh get [telemetry|installation-id|data-dir|all]
#   telemetry-config.sh set telemetry <off|anonymous|community>
#   telemetry-config.sh show-data [--full | --remote-preview]
#   telemetry-config.sh clear-data [--yes]
#   telemetry-config.sh status
#
# Reads / writes only $HOME/.nanostack/ paths. Never touches project state.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/telemetry.sh"

_usage() {
  cat >&2 <<'USAGE'
telemetry-config.sh — manage nanostack telemetry preferences

Subcommands:
  get [key]              Show current value. key: telemetry | installation-id | data-dir | all (default)
  set telemetry <tier>   Set tier. Valid: off | anonymous | community
  show-data [opt]        Print the local event log. opt: --full (no tail), --remote-preview (show what WOULD be sent)
  clear-data [--yes]     Delete the local JSONL log (irreversible)
  status                 Summary of tier + recent activity

All state lives in ~/.nanostack/. Nothing is sent over the network in this
release. See TELEMETRY.md in the skill directory for the privacy contract.
USAGE
}

_cmd_get() {
  local key="${1:-all}"
  case "$key" in
    telemetry)
      nano_tel_get_tier
      printf '\n'
      ;;
    installation-id)
      if [ -f "$NANO_TEL_INSTALL_ID_FILE" ]; then
        cat "$NANO_TEL_INSTALL_ID_FILE"
        printf '\n'
      else
        echo "(none — only community tier has an installation-id)"
      fi
      ;;
    data-dir)
      printf '%s\n' "$NANO_TEL_HOME"
      ;;
    all)
      local tier iid
      tier=$(nano_tel_get_tier)
      iid="(none)"
      [ -f "$NANO_TEL_INSTALL_ID_FILE" ] && iid=$(cat "$NANO_TEL_INSTALL_ID_FILE")
      cat <<EOF
tier:             $tier
installation-id:  $iid
data-dir:         $NANO_TEL_HOME
event-log:        $NANO_TEL_JSONL
EOF
      ;;
    *)
      echo "ERROR: unknown key '$key'" >&2
      _usage
      return 1
      ;;
  esac
}

_cmd_set() {
  local key="${1:-}" value="${2:-}"
  case "$key" in
    telemetry)
      nano_tel_set_tier "$value" || return 1
      echo "telemetry tier set to: $value"
      if [ "$value" = "community" ]; then
        echo "installation-id: $(cat "$NANO_TEL_INSTALL_ID_FILE" 2>/dev/null)"
      fi
      ;;
    *)
      echo "ERROR: only 'set telemetry <tier>' is supported" >&2
      _usage
      return 1
      ;;
  esac
}

_cmd_show_data() {
  local mode="${1:-}"
  if [ ! -f "$NANO_TEL_JSONL" ]; then
    echo "(no events recorded yet — tier may be 'off' or no skill has run)"
    return 0
  fi
  case "$mode" in
    --full)
      jq . "$NANO_TEL_JSONL" 2>/dev/null || cat "$NANO_TEL_JSONL"
      ;;
    --remote-preview)
      _cmd_remote_preview
      ;;
    '' )
      local lines=20
      echo "(showing last $lines events — use --full for everything)"
      tail -n "$lines" "$NANO_TEL_JSONL" | jq . 2>/dev/null || tail -n "$lines" "$NANO_TEL_JSONL"
      ;;
    *)
      echo "ERROR: unknown option '$mode'" >&2
      _usage
      return 1
      ;;
  esac
}

# Show what would be sent to the remote endpoint IF tier is not off.
# In V5 Sprint 1 nothing is sent; this is a dry-run preview of the shape.
_cmd_remote_preview() {
  local tier
  tier=$(nano_tel_get_tier)
  if [ "$tier" = "off" ]; then
    echo "(tier is 'off' — nothing would be sent)"
    return 0
  fi
  if [ ! -f "$NANO_TEL_JSONL" ]; then
    echo "(no events recorded — nothing to preview)"
    return 0
  fi
  echo "=== remote-preview for tier=$tier ==="
  echo "(reminder: V5 Sprint 1 does not send anything. This is a dry-run.)"
  echo
  local filter
  if [ "$tier" = "anonymous" ]; then
    # Anonymous tier drops session_id and installation_id on send.
    filter='del(.session_id, .installation_id)'
  else
    # Community keeps everything.
    filter='.'
  fi
  tail -n 20 "$NANO_TEL_JSONL" | jq -c "$filter" 2>/dev/null
}

_cmd_clear_data() {
  local confirm="${1:-}"
  if [ ! -f "$NANO_TEL_JSONL" ] && [ ! -f "$NANO_TEL_JSONL.prev" ]; then
    echo "(nothing to clear)"
    return 0
  fi
  if [ "$confirm" != "--yes" ]; then
    read -r -p "This deletes $NANO_TEL_JSONL and .prev. Continue? [y/N] " ans
    case "$ans" in
      y|Y|yes) : ;;
      *) echo "cancelled."; return 0 ;;
    esac
  fi
  rm -f "$NANO_TEL_JSONL" "$NANO_TEL_JSONL.prev"
  echo "local event log cleared."
}

_cmd_status() {
  local tier iid count
  tier=$(nano_tel_get_tier)
  iid="(none)"
  [ -f "$NANO_TEL_INSTALL_ID_FILE" ] && iid=$(cat "$NANO_TEL_INSTALL_ID_FILE")
  count=0
  [ -f "$NANO_TEL_JSONL" ] && count=$(wc -l < "$NANO_TEL_JSONL" 2>/dev/null | tr -d ' ')
  cat <<EOF
tier:             $tier
installation-id:  $iid
event count:      $count
event log:        $NANO_TEL_JSONL
EOF
  if [ "$count" -gt 0 ] 2>/dev/null; then
    echo
    echo "top skills (last 30 days):"
    local since
    since=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
         || echo '1970-01-01T00:00:00Z')
    jq -r --arg s "$since" 'select(.ts >= $s) | .skill' "$NANO_TEL_JSONL" 2>/dev/null \
      | sort | uniq -c | sort -rn | head -10
  fi
}

main() {
  local cmd="${1:-}"
  shift 2>/dev/null || true
  case "$cmd" in
    get)              _cmd_get "$@" ;;
    set)              _cmd_set "$@" ;;
    show-data)        _cmd_show_data "$@" ;;
    clear-data)       _cmd_clear_data "$@" ;;
    status)           _cmd_status ;;
    help|--help|-h|'') _usage ;;
    *)
      echo "ERROR: unknown subcommand '$cmd'" >&2
      _usage
      return 1
      ;;
  esac
}

main "$@"
