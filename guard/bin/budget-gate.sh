#!/usr/bin/env bash
# budget-gate.sh — Hard budget enforcement in the guard pipeline
# Called by check-dangerous.sh at Tier 2.8.
# If a sprint budget is set and >= 95% spent, block ALL commands.
# Exit 0 = within budget (or no budget set). Exit 1 = blocked.
set -euo pipefail

GUARD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NANOSTACK_ROOT="$(cd "$GUARD_DIR/.." && pwd)"
BUDGET_SH="$NANOSTACK_ROOT/bin/budget.sh"

# Skip if no budget script
[ -x "$BUDGET_SH" ] || exit 0

# Skip if explicitly overridden
[ -n "${NANOSTACK_SKIP_BUDGET:-}" ] && exit 0

RESULT=$("$BUDGET_SH" check 2>/dev/null) || exit 0
ACTION=$(echo "$RESULT" | jq -r '.action // "continue"' 2>/dev/null) || exit 0

if [ "$ACTION" = "stop" ]; then
  SPENT=$(echo "$RESULT" | jq -r '.spent_usd // "?"')
  MAX=$(echo "$RESULT" | jq -r '.max_usd // "?"')
  PCT=$(echo "$RESULT" | jq -r '.pct // "?"')
  echo "BLOCKED [BUDGET] Sprint budget exceeded (${PCT}%)"
  echo "Category: cost-control"
  echo "Spent: \$${SPENT} / \$${MAX}"
  echo ""
  echo "Action: save your work and stop the sprint. Run \`bin/budget.sh check\` for details, or raise the limit with \`bin/budget.sh set --max-usd N\`."
  echo "Bypass: NANOSTACK_SKIP_BUDGET=1   (use sparingly)"
  exit 1
fi
