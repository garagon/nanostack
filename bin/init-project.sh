#!/usr/bin/env bash
# init-project.sh — Initialize or repair a project for nanostack.
#
# Default behavior (no flag) creates .claude/settings.json when missing
# (with hooks and narrow rm rules) or merges permissions into an existing
# file without touching the existing hooks block. This matches the safe
# additive semantics shipped before v0.9 and stays backward compatible.
#
# Migration flags (added in v0.9) make the spec's "repair" pattern an
# explicit user choice instead of a silent rewrite. Every migration path
# backs up .claude/settings.json with a timestamped suffix before
# changing anything, and ends by re-running /nano-doctor so the user
# sees the new state without a separate command.
#
# Flags:
#   --check                Read-only diagnostic. Runs /nano-doctor and exits.
#   --repair               Add missing PreToolUse hooks AND add narrow rm
#                          rules. Additive: leaves any existing entries
#                          (including Bash(rm:*)) untouched. Safe to run
#                          on any project.
#   --migrate-hooks        Add missing PreToolUse hooks only.
#   --migrate-permissions  Narrow rm rules. Removes Bash(rm:*) and adds
#                          Bash(rm:.nanostack/**) + Bash(rm:/tmp/**).
#                          This is the only flag that removes anything.
#
# Permission model:
#   New installs receive narrow rm permissions (.nanostack/** and /tmp/**)
#   plus hooks wired for Bash, Write, Edit, MultiEdit. Existing installs
#   are left alone unless the user opts in via one of the migration flags.
#   See SECURITY.md "Permission model" for the full story.

set -e

# ─── Flags ─────────────────────────────────────────────────────────────

MODE="default"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)               MODE="check";               shift ;;
    --repair)              MODE="repair";              shift ;;
    --migrate-hooks)       MODE="migrate_hooks";       shift ;;
    --migrate-permissions) MODE="migrate_permissions"; shift ;;
    --help|-h)
      cat <<'HELP'
Usage: init-project.sh [FLAG]

  (no flag)              Create or merge .claude/settings.json safely.
  --check                Run /nano-doctor read-only and exit.
  --repair               Add missing hooks and narrow rm rules; never
                         removes existing entries. Re-runs doctor.
  --migrate-hooks        Add missing PreToolUse hooks only.
  --migrate-permissions  Narrow rm rules: remove Bash(rm:*) and add
                         Bash(rm:.nanostack/**) + Bash(rm:/tmp/**).

Every migration path backs up settings.json with a timestamp before
changing anything, and re-runs /nano-doctor at the end so you can see
the new state.
HELP
      exit 0 ;;
    *) shift ;;
  esac
done

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CLAUDE_DIR="$PROJECT_ROOT/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# Resolve nanostack tool paths. Try the script's own dir first (works for
# dev repos and any install layout that keeps init-project.sh in bin/),
# fall back to the standard install path.
_SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
_NANOSTACK_ROOT="$(cd "$_SCRIPT_DIR/.." 2>/dev/null && pwd)"
if [ -x "$_NANOSTACK_ROOT/bin/nano-doctor.sh" ]; then
  DOCTOR="$_NANOSTACK_ROOT/bin/nano-doctor.sh"
  GUARD_CHECK_DANGEROUS="$_NANOSTACK_ROOT/guard/bin/check-dangerous.sh"
  GUARD_CHECK_WRITE="$_NANOSTACK_ROOT/guard/bin/check-write.sh"
else
  DOCTOR="$HOME/.claude/skills/nanostack/bin/nano-doctor.sh"
  GUARD_CHECK_DANGEROUS="$HOME/.claude/skills/nanostack/guard/bin/check-dangerous.sh"
  GUARD_CHECK_WRITE="$HOME/.claude/skills/nanostack/guard/bin/check-write.sh"
fi

# ─── Helpers ───────────────────────────────────────────────────────────

backup_settings() {
  # Timestamped backup before any mutation. Returns 0 if there is nothing
  # to back up (no settings.json yet) so callers can chain unconditionally.
  [ -f "$SETTINGS" ] || return 0
  local backup="$SETTINGS.$(date +%Y%m%d-%H%M%S).bak"
  cp "$SETTINGS" "$backup"
  echo "  Backup: $backup"
}

run_doctor() {
  echo ""
  if [ -x "$DOCTOR" ]; then
    "$DOCTOR" || true
  else
    echo "  (nano-doctor not found at $DOCTOR; skipping post-flow check)"
  fi
}

has_hook() {
  local matcher="$1" needle="$2"
  jq -e --arg m "$matcher" --arg n "$needle" '
    (.hooks.PreToolUse // [])
    | any(
        (.matcher // "" | test($m))
        and ((.hooks // []) | any((.command // "") | contains($n)))
      )
  ' "$SETTINGS" >/dev/null 2>&1
}

add_hooks() {
  # Adds missing Bash and Write/Edit/MultiEdit PreToolUse matchers via jq.
  # Existing hooks are preserved. Returns 0 if nothing changed (idempotent),
  # 1 if a write occurred, so callers can decide whether to print or stay
  # silent.
  local need_bash=0 need_write=0
  has_hook 'Bash' 'check-dangerous.sh'  || need_bash=1
  has_hook 'Write|Edit' 'check-write.sh' || need_write=1
  if [ $need_bash -eq 0 ] && [ $need_write -eq 0 ]; then
    return 0
  fi
  local tmp="$SETTINGS.tmp.$$"
  jq \
    --arg bashcmd "$GUARD_CHECK_DANGEROUS" \
    --arg writecmd "$GUARD_CHECK_WRITE" \
    --argjson need_bash "$need_bash" \
    --argjson need_write "$need_write" '
      .hooks //= {}
      | .hooks.PreToolUse //= []
      | if $need_bash == 1 then
          .hooks.PreToolUse += [{
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": $bashcmd}]
          }]
        else . end
      | if $need_write == 1 then
          .hooks.PreToolUse += [{
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [{"type": "command", "command": $writecmd}]
          }]
        else . end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  [ $need_bash -eq 1 ]  && echo "  Added: PreToolUse hook for Bash"
  [ $need_write -eq 1 ] && echo "  Added: PreToolUse hook for Write|Edit|MultiEdit"
  return 1
}

add_narrow_rm() {
  # Adds Bash(rm:.nanostack/**) and Bash(rm:/tmp/**) via jq unique.
  # Existing entries (including Bash(rm:*)) are not removed. This is
  # the additive variant used by --repair.
  local before
  before=$(jq -r '.permissions.allow // [] | length' "$SETTINGS" 2>/dev/null)
  local tmp="$SETTINGS.tmp.$$"
  jq '
    .permissions //= {}
    | .permissions.allow = ((.permissions.allow // []) + [
        "Bash(rm:.nanostack/**)",
        "Bash(rm:/tmp/**)"
      ] | unique)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  local after
  after=$(jq -r '.permissions.allow // [] | length' "$SETTINGS" 2>/dev/null)
  if [ "$before" != "$after" ]; then
    echo "  Added: narrow rm rules (Bash(rm:.nanostack/**) and Bash(rm:/tmp/**))"
  fi
}

migrate_permissions() {
  # Remove Bash(rm:*) and add the narrow variants. This is the only path
  # that removes anything. Behavior matches the spec's
  # --migrate-permissions: an explicit, opt-in narrowing.
  local removed=0
  if jq -e '.permissions.allow // [] | any(. == "Bash(rm:*)")' "$SETTINGS" >/dev/null 2>&1; then
    removed=1
  fi
  local tmp="$SETTINGS.tmp.$$"
  jq '
    .permissions //= {}
    | .permissions.allow = (((.permissions.allow // []) - ["Bash(rm:*)"]) + [
        "Bash(rm:.nanostack/**)",
        "Bash(rm:/tmp/**)"
      ] | unique)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  [ "$removed" -eq 1 ] && echo "  Removed: Bash(rm:*)"
  echo "  Ensured: Bash(rm:.nanostack/**) and Bash(rm:/tmp/**)"
}

# ─── --check mode ──────────────────────────────────────────────────────

if [ "$MODE" = "check" ]; then
  if [ -x "$DOCTOR" ]; then
    exec "$DOCTOR"
  else
    echo "ERROR: nano-doctor not found at $DOCTOR. Reinstall nanostack." >&2
    exit 1
  fi
fi

echo "Nanostack Project Init"
echo "======================"
echo "Project: $PROJECT_ROOT"
echo ""

# ─── Migration modes (require existing settings) ───────────────────────

case "$MODE" in
  repair|migrate_hooks|migrate_permissions)
    if [ ! -f "$SETTINGS" ]; then
      echo "No $SETTINGS to migrate. Run init-project.sh without flags first." >&2
      exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "ERROR: jq is required for migration. Install with 'brew install jq' or 'apt install jq'." >&2
      exit 1
    fi
    backup_settings
    case "$MODE" in
      repair)
        add_hooks || true   # do not exit on idempotent no-op
        add_narrow_rm ;;
      migrate_hooks)
        add_hooks || true ;;
      migrate_permissions)
        migrate_permissions ;;
    esac
    run_doctor
    exit 0 ;;
esac

# ─── Default mode (create or merge) ────────────────────────────────────

# Create .nanostack directory (needed for session.json and artifacts)
mkdir -p "$PROJECT_ROOT/.nanostack"

# Create .claude directory
mkdir -p "$CLAUDE_DIR"

# Create or merge settings.json
if [ -f "$SETTINGS" ]; then
  # Merge permissions into existing settings. Hooks intentionally NOT
  # touched; users opt into the hook migration via --migrate-hooks or
  # --repair. Default stays backward compatible with installs that
  # predate v0.9.
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
  echo "Updated: $SETTINGS (merged permissions; hooks unchanged. Run --repair to add hooks.)"
else
  # Create new settings. Fresh installs get the PreToolUse hooks wired
  # automatically so Bash, Write, and Edit all pass through the guard.
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
        "hooks": [{"type": "command", "command": "$GUARD_CHECK_DANGEROUS"}]
      },
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{"type": "command", "command": "$GUARD_CHECK_WRITE"}]
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
