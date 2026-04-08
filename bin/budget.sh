#!/usr/bin/env bash
# budget.sh — Token budget enforcement for sprint cost control
# Usage:
#   budget.sh set --max-usd 15 --model opus-4
#   budget.sh check --input-tokens 150000 --output-tokens 30000
#   budget.sh status
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"
source "$SCRIPT_DIR/lib/pricing.sh"

SESSION_FILE="$NANOSTACK_STORE/session.json"

# ─── set ────────────────────────────────────────────────────
cmd_set() {
  local max_usd="" model="sonnet-4"
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-usd) max_usd="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ -z "$max_usd" ] && { echo "Usage: budget.sh set --max-usd <amount> [--model <model>]" >&2; exit 1; }

  if [ ! -f "$SESSION_FILE" ]; then
    echo "ERROR: no active session. Run 'session.sh init' first." >&2
    exit 1
  fi

  jq \
    --argjson max "$max_usd" \
    --arg model "$model" \
    '.budget.max_usd = $max | .budget.model = $model' "$SESSION_FILE" > "${SESSION_FILE}.tmp"
  mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

  echo "OK: budget set to \$$max_usd ($model)"
}

# ─── check ──────────────────────────────────────────────────
cmd_check() {
  local input_tokens=0 output_tokens=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --input-tokens) input_tokens="$2"; shift 2 ;;
      --output-tokens) output_tokens="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ ! -f "$SESSION_FILE" ]; then
    echo '{"action":"continue","reason":"no_session"}'
    exit 0
  fi

  local max_usd model prev_input prev_output
  max_usd=$(jq -r '.budget.max_usd // "null"' "$SESSION_FILE")
  model=$(jq -r '.budget.model // "sonnet-4"' "$SESSION_FILE")
  prev_input=$(jq -r '.budget.tokens_input // 0' "$SESSION_FILE")
  prev_output=$(jq -r '.budget.tokens_output // 0' "$SESSION_FILE")

  # No budget set: always continue
  if [ "$max_usd" = "null" ]; then
    echo '{"action":"continue","reason":"no_budget_set"}'
    exit 0
  fi

  local total_input=$((prev_input + input_tokens))
  local total_output=$((prev_output + output_tokens))

  # Calculate cost
  local price_pair
  price_pair=$(pricing "$model")
  local input_price output_price
  input_price=$(echo "$price_pair" | cut -d' ' -f1)
  output_price=$(echo "$price_pair" | cut -d' ' -f2)

  # Cost in USD: (tokens / 1M) * price_per_M
  # Use awk for floating point
  local spent_usd pct action reason
  spent_usd=$(awk "BEGIN { printf \"%.2f\", ($total_input / 1000000.0) * $input_price + ($total_output / 1000000.0) * $output_price }")
  pct=$(awk "BEGIN { printf \"%d\", ($spent_usd / $max_usd) * 100 }")

  if [ "$pct" -ge 95 ]; then
    action="stop"
    reason="budget_exceeded"
  elif [ "$pct" -ge 80 ]; then
    action="warn"
    reason="budget_warning"
  else
    action="continue"
    reason=""
  fi

  # Update session with new totals
  jq \
    --argjson input "$total_input" \
    --argjson output "$total_output" \
    --argjson spent "$spent_usd" \
    '.budget.tokens_input = $input | .budget.tokens_output = $output | .budget.spent_usd = $spent' "$SESSION_FILE" > "${SESSION_FILE}.tmp"
  mv "${SESSION_FILE}.tmp" "$SESSION_FILE"

  jq -n \
    --argjson spent "$spent_usd" \
    --argjson max "$max_usd" \
    --argjson pct "$pct" \
    --arg action "$action" \
    --arg reason "$reason" \
    --arg model "$model" \
    '{spent_usd: $spent, max_usd: $max, pct: $pct, action: $action, reason: $reason, model: $model}'
}

# ─── status ─────────────────────────────────────────────────
cmd_status() {
  if [ ! -f "$SESSION_FILE" ]; then
    echo '{"active":false}'
    exit 0
  fi

  jq '.budget' "$SESSION_FILE"
}

# ─── dispatch ───────────────────────────────────────────────
CMD="${1:-status}"
shift || true

case "$CMD" in
  set)    cmd_set "$@" ;;
  check)  cmd_check "$@" ;;
  status) cmd_status "$@" ;;
  *)
    echo "Usage: budget.sh <set|check|status>" >&2
    exit 1
    ;;
esac
