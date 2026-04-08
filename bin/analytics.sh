#!/usr/bin/env bash
# analytics.sh — Local usage stats from your nanostack artifacts
# Usage: analytics.sh [--month YYYY-MM] [--json]
# No remote calls. Reads .nanostack/ only.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

STORE="$NANOSTACK_STORE"
KNOW_HOW="$NANOSTACK_STORE/know-how"
MONTH="$(date +"%Y-%m")"
JSON_OUTPUT=false
OBSIDIAN_OUTPUT=false
TOKENS_OUTPUT=false

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=true ;;
    --obsidian) OBSIDIAN_OUTPUT=true ;;
    --tokens) TOKENS_OUTPUT=true ;;
    --month) ;; # handled below
    *)
      # Check if previous arg was --month
      if [ "${prev_arg:-}" = "--month" ]; then
        MONTH="$arg"
      fi
      ;;
  esac
  prev_arg="$arg"
done

if [ ! -d "$STORE" ]; then
  echo "No nanostack data found. Artifacts auto-save after each skill run."
  exit 0
fi

# Count artifacts per phase
count_phase() {
  local phase="$1"
  local dir="$STORE/$phase"
  local count=0
  [ -d "$dir" ] || { echo 0; return; }
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if jq -e --arg m "$MONTH" '.timestamp // .date | startswith($m)' "$f" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Collect stats
THINK=$(count_phase think)
PLAN=$(count_phase plan)
REVIEW=$(count_phase review)
QA=$(count_phase qa)
SECURITY=$(count_phase security)
SHIP=$(count_phase ship)
TOTAL=$((THINK + PLAN + REVIEW + QA + SECURITY + SHIP))

# Mode breakdown from review/qa/security
count_mode() {
  local phase="$1"
  local mode="$2"
  local dir="$STORE/$phase"
  local count=0
  [ -d "$dir" ] || { echo 0; return; }
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if jq -e --arg m "$MONTH" --arg mode "$mode" \
      '(.timestamp // .date | startswith($m)) and .mode == $mode' "$f" >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

QUICK=$(( $(count_mode review quick) + $(count_mode qa quick) + $(count_mode security quick) ))
STANDARD=$(( $(count_mode review standard) + $(count_mode qa standard) + $(count_mode security standard) ))
THOROUGH=$(( $(count_mode review thorough) + $(count_mode qa thorough) + $(count_mode security thorough) ))

# Security score trend
LAST_SECURITY=""
if [ -d "$STORE/security" ]; then
  LAST_FILE=$(find "$STORE/security" -name "*.json" 2>/dev/null | sort -r | head -1)
  if [ -n "$LAST_FILE" ]; then
    LAST_SECURITY=$(jq -r '.summary.total_findings // "n/a"' "$LAST_FILE" 2>/dev/null)
  fi
fi

# Fetch token data if requested (Claude Code only — skips silently on other agents)
TOKEN_JSON=""
if $TOKENS_OUTPUT; then
  TOKEN_REPORT="$SCRIPT_DIR/token-report.sh"
  if [ -x "$TOKEN_REPORT" ]; then
    # Filter to current month
    MONTH_START="${MONTH}-01"
    TOKEN_JSON=$("$TOKEN_REPORT" --json --since "$MONTH_START" 2>/dev/null) || TOKEN_JSON=""
    # Skip if analyzer returned a skip status (non-Claude-Code agent)
    if echo "$TOKEN_JSON" | jq -e '.status == "skipped"' >/dev/null 2>&1; then
      TOKEN_JSON=""
    fi
  fi
fi

if $JSON_OUTPUT; then
  BASE_JSON=$(jq -n \
    --arg month "$MONTH" \
    --argjson think "$THINK" \
    --argjson plan "$PLAN" \
    --argjson review "$REVIEW" \
    --argjson qa "$QA" \
    --argjson security "$SECURITY" \
    --argjson ship "$SHIP" \
    --argjson total "$TOTAL" \
    --argjson quick "$QUICK" \
    --argjson standard "$STANDARD" \
    --argjson thorough "$THOROUGH" \
    --arg last_security "$LAST_SECURITY" \
    '{
      month: $month,
      sprints: { think: $think, plan: $plan, review: $review, qa: $qa, security: $security, ship: $ship, total: $total },
      modes: { quick: $quick, standard: $standard, thorough: $thorough },
      last_security_findings: $last_security
    }')

  if [ -n "$TOKEN_JSON" ] && $TOKENS_OUTPUT; then
    # Merge token data into output
    TOKENS_BLOCK=$(echo "$TOKEN_JSON" | jq '{
      total: .tokens.total,
      input: .tokens.input,
      cache_creation: .tokens.cache_creation,
      cache_read: .tokens.cache_read,
      output: .tokens.output,
      cost_usd: .cost_usd,
      cache_efficiency_pct: .cache_efficiency_pct,
      subagent_pct: .subagent_pct,
      avg_per_session: .avg_per_session
    }' 2>/dev/null) || TOKENS_BLOCK=""

    if [ -n "$TOKENS_BLOCK" ]; then
      echo "$BASE_JSON" | jq --argjson tokens "$TOKENS_BLOCK" '. + {tokens: $tokens}'
    else
      echo "$BASE_JSON"
    fi
  else
    echo "$BASE_JSON"
  fi
  exit 0
fi

echo "Nanostack Analytics ($MONTH)"
echo "═══════════════════════════════"
echo ""
echo "  Sprint phases"
echo "  ─────────────"
echo "  think       $THINK"
echo "  plan        $PLAN"
echo "  review      $REVIEW"
echo "  qa          $QA"
echo "  security    $SECURITY"
echo "  ship        $SHIP"
echo "  total       $TOTAL"
echo ""
echo "  Intensity modes"
echo "  ───────────────"
echo "  quick       $QUICK"
echo "  standard    $STANDARD"
echo "  thorough    $THOROUGH"

if [ -n "$LAST_SECURITY" ] && [ "$LAST_SECURITY" != "n/a" ]; then
  echo ""
  echo "  Last security audit: $LAST_SECURITY findings"
fi

# Token usage section
if $TOKENS_OUTPUT && [ -n "$TOKEN_JSON" ]; then
  TOK_TOTAL=$(echo "$TOKEN_JSON" | jq -r '.tokens.total // 0')
  TOK_COST=$(echo "$TOKEN_JSON" | jq -r '.cost_usd // 0')
  TOK_CACHE=$(echo "$TOKEN_JSON" | jq -r '.cache_efficiency_pct // 0')
  TOK_SUB=$(echo "$TOKEN_JSON" | jq -r '.subagent_pct // 0')
  TOK_AVG=$(echo "$TOKEN_JSON" | jq -r '.avg_per_session // 0')
  TOK_SESSIONS=$(echo "$TOKEN_JSON" | jq -r '.sessions // 0')

  echo ""
  echo "  Token usage ($MONTH)"
  echo "  ─────────────────────"
  printf "  total tokens  %'d\n" "$TOK_TOTAL"
  echo "  est. cost     \$$TOK_COST"
  echo "  cache eff.    ${TOK_CACHE}%"
  echo "  subagent %    ${TOK_SUB}%"
  printf "  avg/session   %'d\n" "$TOK_AVG"
  echo "  sessions      $TOK_SESSIONS"
fi

echo ""
if [ "$TOTAL" -eq 0 ]; then
  echo "  No data yet. Artifacts auto-save after each skill run."
fi

# Obsidian dashboard output
if $OBSIDIAN_OUTPUT; then
  DASHBOARD="$KNOW_HOW/dashboard.md"
  mkdir -p "$KNOW_HOW"
  {
    echo "# Nanostack Dashboard"
    echo ""
    echo "---"
    echo "tags: [dashboard, analytics, $MONTH]"
    echo "---"
    echo ""
    echo "Generated: $(date +"%Y-%m-%d %H:%M")"
    echo ""
    echo "## Sprint Phases ($MONTH)"
    echo ""
    echo "| Phase | Count |"
    echo "|-------|-------|"
    echo "| think | $THINK |"
    echo "| plan | $PLAN |"
    echo "| review | $REVIEW |"
    echo "| qa | $QA |"
    echo "| security | $SECURITY |"
    echo "| ship | $SHIP |"
    echo "| **total** | **$TOTAL** |"
    echo ""
    echo "## Intensity Modes"
    echo ""
    echo "| Mode | Count |"
    echo "|------|-------|"
    echo "| quick | $QUICK |"
    echo "| standard | $STANDARD |"
    echo "| thorough | $THOROUGH |"
    echo ""
    if [ -n "$LAST_SECURITY" ] && [ "$LAST_SECURITY" != "n/a" ]; then
      echo "## Security"
      echo ""
      echo "Last audit: **$LAST_SECURITY findings**"
      echo ""
    fi
    if $TOKENS_OUTPUT && [ -n "$TOKEN_JSON" ]; then
      TOK_TOTAL=$(echo "$TOKEN_JSON" | jq -r '.tokens.total // 0')
      TOK_COST=$(echo "$TOKEN_JSON" | jq -r '.cost_usd // 0')
      TOK_CACHE=$(echo "$TOKEN_JSON" | jq -r '.cache_efficiency_pct // 0')
      TOK_SUB=$(echo "$TOKEN_JSON" | jq -r '.subagent_pct // 0')
      TOK_SESSIONS=$(echo "$TOKEN_JSON" | jq -r '.sessions // 0')

      echo "## Token Usage ($MONTH)"
      echo ""
      echo "| Metric | Value |"
      echo "|--------|-------|"
      printf "| Total tokens | %'d |\n" "$TOK_TOTAL"
      echo "| Est. cost | \$$TOK_COST |"
      echo "| Cache efficiency | ${TOK_CACHE}% |"
      echo "| Subagent % | ${TOK_SUB}% |"
      echo "| Sessions | $TOK_SESSIONS |"
      echo ""
    fi
    echo "## Recent Journals"
    echo ""
    if [ -d "$KNOW_HOW/journal" ]; then
      ls -t "$KNOW_HOW/journal"/*.md 2>/dev/null | head -5 | while read -r f; do
        NAME=$(basename "$f" .md)
        echo "- [[$NAME]]"
      done
    else
      echo "No sprint journals yet. Run \`bin/sprint-journal.sh\` after a sprint."
    fi
    echo ""
    echo "---"
    echo ""
    echo "Related: [[learnings/from-building]] | [[reference/conflict-precedents]]"
  } > "$DASHBOARD"
  echo "Dashboard: $DASHBOARD"
fi
