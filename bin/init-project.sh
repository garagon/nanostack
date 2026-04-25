#!/usr/bin/env bash
# init-project.sh — Initialize a project for nanostack
# Creates .claude/settings.json with permissions for uninterrupted autopilot
# and .gitignore entry for .nanostack/
# Usage: Run once in any project directory
#
# Permission model:
#   New installs receive narrow rm permissions (.nanostack/** and /tmp/**).
#   Anything outside those paths prompts the user. The defense-in-depth
#   story is documented in SECURITY.md under "Permission model".
#
#   When merging into an existing .claude/settings.json, we only ADD
#   entries; we never remove what the user already has. Existing installs
#   with Bash(rm:*) keep it until the user opts into narrowing manually.
#   /nano-doctor surfaces a warning when broad rm is present in settings.
set -e

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CLAUDE_DIR="$PROJECT_ROOT/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Nanostack Project Init"
echo "======================"
echo "Project: $PROJECT_ROOT"
echo ""

# Create .nanostack directory (needed for session.json and artifacts)
mkdir -p "$PROJECT_ROOT/.nanostack"

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
      "Bash(rm:.nanostack/**)",
      "Bash(rm:/tmp/**)",
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
  # Create new settings. Fresh installs get the PreToolUse hooks wired
  # automatically so Bash, Write, and Edit all pass through the guard.
  # Existing installs are left alone; see SECURITY.md for the manual
  # wire-up and /nano-doctor for a warning when the hooks are missing.
  _GUARD_CHECK_DANGEROUS="$HOME/.claude/skills/nanostack/guard/bin/check-dangerous.sh"
  _GUARD_CHECK_WRITE="$HOME/.claude/skills/nanostack/guard/bin/check-write.sh"
  cat > "$SETTINGS" << EOF
{
  "permissions": {
    "allow": [
      "Bash(mkdir:*)",
      "Bash(chmod:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(rm:.nanostack/**)",
      "Bash(rm:/tmp/**)",
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
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "$_GUARD_CHECK_DANGEROUS"}]
      },
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{"type": "command", "command": "$_GUARD_CHECK_WRITE"}]
      }
    ]
  }
}
EOF
  echo "Created: $SETTINGS (with PreToolUse hooks for Bash, Write, Edit)"
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
