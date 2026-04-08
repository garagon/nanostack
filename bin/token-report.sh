#!/usr/bin/env bash
# token-report.sh — Token usage report from Claude Code session logs
# Usage:
#   token-report.sh                     Summary for current project
#   token-report.sh --all               All projects
#   token-report.sh --since 7d          Last 7 days
#   token-report.sh --since 2026-04-01  Since date
#   token-report.sh --json              JSON output
#   token-report.sh --top 10            Top N costliest sessions
#   token-report.sh --subagents         Show subagent breakdown
#   token-report.sh --check             Anomaly detection
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANALYZER="$SCRIPT_DIR/token-analyzer.py"

if [ ! -f "$ANALYZER" ]; then
  echo "error: token-analyzer.py not found at $ANALYZER" >&2
  exit 1
fi

# Resolve Claude Code project directory for current workspace
ARGS=()
HAS_ALL=false
HAS_PROJECT_DIR=false

for arg in "$@"; do
  [ "$arg" = "--all" ] && HAS_ALL=true
  [ "$arg" = "--project-dir" ] && HAS_PROJECT_DIR=true
  ARGS+=("$arg")
done

if ! $HAS_ALL && ! $HAS_PROJECT_DIR; then
  # Auto-resolve project directory from cwd
  PROJECT_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"
  PROJECT_NAME=$(basename "$(pwd)")
  ARGS+=("--project-dir" "$PROJECT_DIR" "--project-name" "$PROJECT_NAME")
fi

python3 "$ANALYZER" "${ARGS[@]}"
