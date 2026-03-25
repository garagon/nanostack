#!/usr/bin/env bash
# init-config.sh — Initialize or read nanostack project config
# Usage: init-config.sh [--interactive]
# Without --interactive: outputs current config or empty JSON
# With --interactive: prompts user via stdout questions (for agent to parse)
set -e

CONFIG="$HOME/.nanostack/config.json"

# If config exists, output it and exit
if [ -f "$CONFIG" ]; then
  cat "$CONFIG"
  exit 0
fi

# No config yet
if [ "$1" != "--interactive" ]; then
  echo '{}'
  exit 0
fi

# Interactive mode — create config directory
mkdir -p "$HOME/.nanostack"

# Detect installed agents
AGENTS="[]"
command -v claude >/dev/null 2>&1 && AGENTS=$(echo "$AGENTS" | jq '. + ["claude"]')
command -v codex >/dev/null 2>&1 && AGENTS=$(echo "$AGENTS" | jq '. + ["codex"]')
{ command -v kiro-cli >/dev/null 2>&1 || command -v kiro >/dev/null 2>&1; } && AGENTS=$(echo "$AGENTS" | jq '. + ["kiro"]')

# Detect project context from current directory
PROJECT_NAME=$(basename "$(pwd)")
HAS_PACKAGE_JSON=false
HAS_GO_MOD=false
HAS_PYTHON=false
HAS_DOCKER=false
[ -f "package.json" ] && HAS_PACKAGE_JSON=true
[ -f "go.mod" ] && HAS_GO_MOD=true
[ -f "requirements.txt" ] || [ -f "pyproject.toml" ] && HAS_PYTHON=true
[ -f "Dockerfile" ] && HAS_DOCKER=true

# Build config
jq -n \
  --arg name "$PROJECT_NAME" \
  --argjson agents "$AGENTS" \
  --argjson pkg "$HAS_PACKAGE_JSON" \
  --argjson gomod "$HAS_GO_MOD" \
  --argjson py "$HAS_PYTHON" \
  --argjson docker "$HAS_DOCKER" \
  --arg date "$(date -u +"%Y-%m-%d")" \
  '{
    schema_version: "1",
    project: $name,
    agents: $agents,
    detected: {
      node: $pkg,
      go: $gomod,
      python: $py,
      docker: $docker
    },
    preferences: {
      default_intensity: "standard",
      auto_save: true,
      conflict_precedence: "security > review > qa"
    },
    configured_at: $date
  }' > "$CONFIG"

cat "$CONFIG"
