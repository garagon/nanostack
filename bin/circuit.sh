#!/usr/bin/env bash
# circuit.sh — Circuit breaker to prevent infinite retry loops
# Usage:
#   circuit.sh fail --tag "hypothesis-xss" [--max 3]
#   circuit.sh success
#   circuit.sh status
#   circuit.sh reset
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

CIRCUIT_FILE="$NANOSTACK_STORE/circuit.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Initialize circuit file if missing
ensure_circuit() {
  if [ ! -f "$CIRCUIT_FILE" ]; then
    jq -n '{consecutive_failures: 0, max_failures: 3, state: "closed", last_tag: null, history: []}' > "$CIRCUIT_FILE"
  fi
}

# ─── fail ───────────────────────────────────────────────────
cmd_fail() {
  local tag="" max=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag) tag="$2"; shift 2 ;;
      --max) max="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ -z "$tag" ] && { echo "Usage: circuit.sh fail --tag <tag> [--max N]" >&2; exit 1; }

  ensure_circuit

  local last_tag
  last_tag=$(jq -r '.last_tag // ""' "$CIRCUIT_FILE")

  # New tag = pivot detected, reset counter
  if [ "$last_tag" != "$tag" ] && [ -n "$last_tag" ]; then
    jq --arg tag "$tag" --argjson max "$max" --arg date "$NOW" \
      '.consecutive_failures = 1 | .last_tag = $tag | .max_failures = $max | .state = "closed" |
       .history = (.history + [{"tag": $tag, "at": $date, "type": "fail"}] | .[-20:])' \
      "$CIRCUIT_FILE" > "${CIRCUIT_FILE}.tmp"
    mv "${CIRCUIT_FILE}.tmp" "$CIRCUIT_FILE"
  else
    jq --arg tag "$tag" --argjson max "$max" --arg date "$NOW" \
      '.consecutive_failures += 1 | .last_tag = $tag | .max_failures = $max |
       .history = (.history + [{"tag": $tag, "at": $date, "type": "fail"}] | .[-20:]) |
       if .consecutive_failures >= .max_failures then .state = "open" else . end' \
      "$CIRCUIT_FILE" > "${CIRCUIT_FILE}.tmp"
    mv "${CIRCUIT_FILE}.tmp" "$CIRCUIT_FILE"
  fi

  # Output current state
  local state consecutive
  state=$(jq -r '.state' "$CIRCUIT_FILE")
  consecutive=$(jq -r '.consecutive_failures' "$CIRCUIT_FILE")

  jq -n \
    --arg state "$state" \
    --argjson consecutive "$consecutive" \
    --argjson max "$max" \
    --arg tag "$tag" \
    '{state: $state, consecutive: $consecutive, max: $max, tag: $tag} |
     if $state == "open" then . + {message: "\($max) consecutive failures on \($tag). Pivot or stop."} else . end'
}

# ─── success ────────────────────────────────────────────────
cmd_success() {
  ensure_circuit

  jq --arg date "$NOW" \
    '.consecutive_failures = 0 | .state = "closed" |
     .history = (.history + [{"tag": .last_tag, "at": $date, "type": "success"}] | .[-20:])' \
    "$CIRCUIT_FILE" > "${CIRCUIT_FILE}.tmp"
  mv "${CIRCUIT_FILE}.tmp" "$CIRCUIT_FILE"

  echo '{"state":"closed","consecutive":0}'
}

# ─── status ─────────────────────────────────────────────────
cmd_status() {
  ensure_circuit
  jq '{state, consecutive_failures, max_failures, last_tag}' "$CIRCUIT_FILE"
}

# ─── reset ──────────────────────────────────────────────────
cmd_reset() {
  jq -n '{consecutive_failures: 0, max_failures: 3, state: "closed", last_tag: null, history: []}' > "$CIRCUIT_FILE"
  echo '{"state":"closed","consecutive":0}'
}

# ─── dispatch ───────────────────────────────────────────────
CMD="${1:-status}"
shift || true

case "$CMD" in
  fail)    cmd_fail "$@" ;;
  success) cmd_success "$@" ;;
  status)  cmd_status "$@" ;;
  reset)   cmd_reset "$@" ;;
  *)
    echo "Usage: circuit.sh <fail|success|status|reset>" >&2
    exit 1
    ;;
esac
