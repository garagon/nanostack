#!/usr/bin/env bash
# Generate .nanostack/stack.json with detected or default stack preferences.
# Usage:
#   bin/init-stack.sh           # project-level (.nanostack/stack.json)
#   bin/init-stack.sh --global  # user-level (~/.nanostack/stack.json)
set -e

GLOBAL=0
if [ "${1:-}" = "--global" ]; then
  GLOBAL=1
fi

if [ "$GLOBAL" -eq 1 ]; then
  TARGET_DIR="$HOME/.nanostack"
else
  # Find project root
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  TARGET_DIR="$ROOT/.nanostack"
fi

TARGET="$TARGET_DIR/stack.json"
mkdir -p "$TARGET_DIR"

if [ -f "$TARGET" ]; then
  echo "stack.json already exists: $TARGET"
  echo "Edit it directly or delete it to regenerate."
  exit 0
fi

# Detect stack from project files
detect_stack() {
  local detected="{}"

  # Node/TypeScript projects
  if [ -f "package.json" ]; then
    local pkg
    pkg=$(cat package.json 2>/dev/null)

    # Framework
    if echo "$pkg" | grep -q '"next"'; then
      detected=$(echo "$detected" | jq '.web.framework = "Next.js"')
    elif echo "$pkg" | grep -q '"remix"'; then
      detected=$(echo "$detected" | jq '.web.framework = "Remix"')
    elif echo "$pkg" | grep -q '"nuxt"'; then
      detected=$(echo "$detected" | jq '.web.framework = "Nuxt"')
    elif echo "$pkg" | grep -q '"svelte"'; then
      detected=$(echo "$detected" | jq '.web.framework = "SvelteKit"')
    fi

    # CSS
    if echo "$pkg" | grep -q '"tailwindcss"'; then
      detected=$(echo "$detected" | jq '.web.css = "Tailwind"')
    fi

    # ORM
    if echo "$pkg" | grep -q '"prisma"'; then
      detected=$(echo "$detected" | jq '.web.orm = "Prisma"')
    elif echo "$pkg" | grep -q '"drizzle-orm"'; then
      detected=$(echo "$detected" | jq '.web.orm = "Drizzle"')
    fi

    # Database
    if echo "$pkg" | grep -q '"@supabase/supabase-js"'; then
      detected=$(echo "$detected" | jq '.web.database = "Supabase"')
    fi

    # Auth
    if echo "$pkg" | grep -q '"@clerk"'; then
      detected=$(echo "$detected" | jq '.web.auth = "Clerk"')
    elif echo "$pkg" | grep -q '"better-auth"'; then
      detected=$(echo "$detected" | jq '.web.auth = "Better-Auth"')
    fi

    # Testing
    if echo "$pkg" | grep -q '"vitest"'; then
      detected=$(echo "$detected" | jq '.web.testing = "Vitest"')
    fi
  fi

  # Go projects
  if [ -f "go.mod" ]; then
    detected=$(echo "$detected" | jq '.go = {}')
    local gomod
    gomod=$(cat go.mod 2>/dev/null)

    if echo "$gomod" | grep -q 'chi'; then
      detected=$(echo "$detected" | jq '.go.http = "Chi"')
    elif echo "$gomod" | grep -q 'fiber'; then
      detected=$(echo "$detected" | jq '.go.http = "Fiber"')
    fi

    if echo "$gomod" | grep -q 'cobra'; then
      detected=$(echo "$detected" | jq '.go.cli = "Cobra"')
    fi

    if echo "$gomod" | grep -q 'bubbletea'; then
      detected=$(echo "$detected" | jq '.go.tui = "Bubble Tea"')
    fi
  fi

  # Python projects
  if [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
    detected=$(echo "$detected" | jq '.python = {}')
    local reqs=""
    [ -f "requirements.txt" ] && reqs=$(cat requirements.txt 2>/dev/null)
    [ -f "pyproject.toml" ] && reqs="$reqs $(cat pyproject.toml 2>/dev/null)"

    if echo "$reqs" | grep -qi 'django'; then
      detected=$(echo "$detected" | jq '.python.web = "Django"')
    elif echo "$reqs" | grep -qi 'fastapi'; then
      detected=$(echo "$detected" | jq '.python.web = "FastAPI"')
    elif echo "$reqs" | grep -qi 'flask'; then
      detected=$(echo "$detected" | jq '.python.web = "Flask"')
    fi

    if echo "$reqs" | grep -qi 'sqlalchemy'; then
      detected=$(echo "$detected" | jq '.python.database = "SQLAlchemy"')
    fi
  fi

  echo "$detected"
}

# Detect or use empty template
DETECTED=$(detect_stack)

# Check if anything was detected
KEYS=$(echo "$DETECTED" | jq 'keys | length')

if [ "$KEYS" -gt 0 ] && [ "$DETECTED" != "{}" ]; then
  echo "Detected stack:"
  echo "$DETECTED" | jq '.'
  echo ""
  echo "Saving to: $TARGET"
  echo "$DETECTED" | jq '.' > "$TARGET"
else
  echo "No stack detected. Creating template."
  cat > "$TARGET" << 'TEMPLATE'
{
  "web": {
    "framework": "",
    "auth": "",
    "database": "",
    "orm": "",
    "hosting": "",
    "css": ""
  }
}
TEMPLATE
  echo "Template saved to: $TARGET"
  echo "Edit it with your preferred stack. Empty values use nanostack defaults."
fi

echo ""
echo "The agent reads this file when planning new projects."
echo "Categories you leave empty or omit will use nanostack defaults."
