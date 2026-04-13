#!/usr/bin/env bash
# about.sh — Generate compact self-description for agents
# Writes .nanostack/ABOUT.md with skills, flow, key commands.
# Any agent (Cursor, Codex, Claude Code) can read this to understand nanostack.
#
# Usage: about.sh          Generate/update ABOUT.md
#        about.sh --print   Print to stdout instead of file
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/store-path.sh"

NANOSTACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRINT_ONLY=false
[ "${1:-}" = "--print" ] && PRINT_ONLY=true

# Count available data
SOLUTIONS=$(find "$NANOSTACK_STORE/know-how/solutions" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
BRIEFS=$(find "$NANOSTACK_STORE/know-how/briefs" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
SESSIONS=$(find "$NANOSTACK_STORE/sessions" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
HAS_CONFIG="no"
[ -f "$NANOSTACK_STORE/config.json" ] && HAS_CONFIG="yes"

DOC="# Nanostack

Sprint quality framework. Turns your AI agent into an engineering team.

## Flow

\`\`\`
/think → /nano → build → /review → /security → /qa → /ship
\`\`\`

## Skills

| Command | What it does |
|---------|-------------|
| /think | Challenge assumptions, find the starting point. --autopilot for full sprint. --retro to reflect. |
| /nano | Turn idea into implementation plan with file names and risks. |
| /review | Two-pass code review: structural + adversarial. |
| /security | OWASP Top 10 + STRIDE audit. |
| /qa | Test the app: browser, API, CLI, or debug mode. |
| /ship | Create PR, verify CI, generate sprint journal. |
| /compound | Document what you learned. Runs after /ship. |
| /guard | Safety guardrails. Blocks dangerous commands. |
| /feature | Fast sprint: skips /think, runs plan through ship. |

## Key Scripts

| Script | What it does |
|--------|-------------|
| bin/resolve.sh <phase> | Load context for a phase (artifacts, solutions, config, goal). |
| bin/session.sh init | Start a sprint session. Add --goal for business context. |
| bin/find-solution.sh <query> | Search past solutions by keyword, tag, or file. |
| bin/sprint-metrics.sh | Git stats + cycle time (used by /think --retro and /nano). |
| bin/doctor.sh | Know-how health check. |
| bin/capture-failure.sh | Log what went wrong (no /compound needed). |

## State

All data in \`.nanostack/\`:
- Artifacts: \`.nanostack/<phase>/<timestamp>.json\`
- Solutions: \`.nanostack/know-how/solutions/{bug,pattern,decision}/\`
- Briefs: \`.nanostack/know-how/briefs/\`
- Audit log: \`.nanostack/audit.log\`

## This Project

- Solutions: $SOLUTIONS
- Briefs: $BRIEFS
- Sprints completed: $SESSIONS
- Configured: $HAS_CONFIG
"

if $PRINT_ONLY; then
  echo "$DOC"
else
  mkdir -p "$NANOSTACK_STORE"
  echo "$DOC" > "$NANOSTACK_STORE/ABOUT.md"
  echo "$NANOSTACK_STORE/ABOUT.md"
fi
