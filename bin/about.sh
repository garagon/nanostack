#!/usr/bin/env bash
# about.sh — Generate compact self-description for agents
# Writes .nanostack/ABOUT.md with skills, flow, key commands.
# Verified adapters: Claude Code, Cursor, OpenAI Codex, OpenCode, Gemini CLI.
# Adapter capabilities live in adapters/<host>.json.
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

# Adapter list: read names from adapters/*.json so this stays in sync
# with the single source of truth. Falls back to the canonical five if
# the adapters directory is missing. `paste -sd ', '` alternates the
# delimiter byte-by-byte on macOS, so we use awk for a clean
# comma-space join.
ADAPTER_LIST=""
if [ -d "$NANOSTACK_ROOT/adapters" ]; then
  ADAPTER_LIST=$(find "$NANOSTACK_ROOT/adapters" -maxdepth 1 -name "*.json" -type f 2>/dev/null \
    | sed 's|.*/||; s|\.json$||' | sort | awk 'NR>1{printf ", "} {printf "%s",$0} END{print ""}')
fi
[ -z "$ADAPTER_LIST" ] && ADAPTER_LIST="claude, codex, cursor, gemini, opencode"

DOC="# Nanostack

Local workflow framework for AI coding agents. The built-in sprint plus a framework for declaring your own custom workflow stacks. Verified adapters: $ADAPTER_LIST.

## Flow

\`\`\`
/think → /nano → build → /review → /security → /qa → /ship
\`\`\`

## Skills

| Command | What it does |
|---------|-------------|
| /think | Refine a rough idea through questions and alternatives, find the starting point. --autopilot for full sprint. --retro to reflect. |
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
| bin/render-artifact.sh <phase> | Render core and registered custom phase artifacts, sprint journals, and custom stack DAGs as local HTML under \`.nanostack/visual/\`. Optional, JSON stays canonical. |

## Custom workflow stacks

Declare your own phases in \`.nanostack/config.json\` (\`custom_phases\` + \`phase_graph\`) and put the skill under \`<store>/skills/<name>/\`. Conductor scheduling, guard concurrency, the artifact contract, session lifecycle, next-step output, and the resolver all consume the same phase registry. See \`reference/custom-stack-contract.md\` and \`examples/custom-stack-template/compliance-release/\`.

## State

All data in \`.nanostack/\`:
- Artifacts: \`.nanostack/<phase>/<timestamp>.json\` with SHA-256 integrity field.
- Solutions: \`.nanostack/know-how/solutions/{bug,pattern,decision}/\`
- Briefs: \`.nanostack/know-how/briefs/\`
- Audit log: \`.nanostack/audit.log\`
- Visual artifacts (optional): \`.nanostack/visual/\` (HTML views derived from JSON; safe to delete)

There is no Nanostack cloud. Telemetry is opt-in and documented in \`TELEMETRY.md\`.

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
