#!/usr/bin/env bash
# init-project.sh — Initialize a project for nanostack
# Creates .claude/settings.json with permissions for uninterrupted autopilot
# and .gitignore entry for .nanostack/
# Usage: Run once in any project directory
set -e

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CLAUDE_DIR="$PROJECT_ROOT/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Nanostack Project Init"
echo "======================"
echo "Project: $PROJECT_ROOT"
echo ""

# Create .claude directory
mkdir -p "$CLAUDE_DIR"

# Create or merge settings.json
if [ -f "$SETTINGS" ]; then
  # Merge permissions into existing settings
  EXISTING=$(cat "$SETTINGS")
  UPDATED=$(echo "$EXISTING" | jq '
    .permissions.allow = ((.permissions.allow // []) + [
      "Bash(mkdir:*)",
      "Bash(chmod:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(rm:*)",
      "Bash(git:*)",
      "Bash(go:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(node:*)",
      "Bash(python*:*)",
      "Bash(pip:*)",
      "Bash(cargo:*)",
      "Bash(jq:*)",
      "Bash(curl:*)",
      "Bash(grep:*)",
      "Bash(find:*)",
      "Bash(wc:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(sort:*)",
      "Bash(sed:*)",
      "Bash(awk:*)",
      "Bash(~/.claude/skills/nanostack/bin/*:*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)"
    ] | unique)
  ')
  echo "$UPDATED" | jq '.' > "$SETTINGS"
  echo "Updated: $SETTINGS (merged permissions)"
else
  # Create new settings
  cat > "$SETTINGS" << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)",
      "Bash(chmod:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(rm:*)",
      "Bash(git:*)",
      "Bash(go:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(node:*)",
      "Bash(python*:*)",
      "Bash(pip:*)",
      "Bash(cargo:*)",
      "Bash(jq:*)",
      "Bash(curl:*)",
      "Bash(grep:*)",
      "Bash(find:*)",
      "Bash(wc:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(sort:*)",
      "Bash(sed:*)",
      "Bash(awk:*)",
      "Bash(~/.claude/skills/nanostack/bin/*:*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)"
    ]
  }
}
EOF
  echo "Created: $SETTINGS"
fi

# Add .nanostack/ to .gitignore if not already there
GITIGNORE="$PROJECT_ROOT/.gitignore"
if [ -f "$GITIGNORE" ]; then
  if ! grep -q '\.nanostack/' "$GITIGNORE" 2>/dev/null; then
    echo "" >> "$GITIGNORE"
    echo "# Nanostack artifacts" >> "$GITIGNORE"
    echo ".nanostack/" >> "$GITIGNORE"
    echo "Updated: .gitignore (added .nanostack/)"
  fi
else
  cat > "$GITIGNORE" << 'EOF'
# Nanostack artifacts
.nanostack/
EOF
  echo "Created: .gitignore"
fi

echo ""
echo "Done. Claude Code will no longer ask for permission on common operations."
echo "Restart Claude Code in this project to apply."
