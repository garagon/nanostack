---
name: guard
description: Use when working near production, sensitive systems, or destructive operations. Activates on-demand safety hooks that block dangerous commands. Supports modes — careful (warn), freeze (block writes outside scope), unfreeze (remove restrictions). Triggers on /guard, /careful, /freeze, /unfreeze.
concurrency: exclusive
depends_on: []
summary: "Safety guardrails. Blocks dangerous commands near production or sensitive systems."
estimated_tokens: 200
hooks:
  PreToolUse:
    - matcher: Bash
      command: "./guard/bin/check-dangerous.sh"
---

# /guard — Safety Guardrails

You have activated safety guardrails. These protect against accidental destructive operations during this session.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" guard
unset _P
```

## Modes

The user may activate a specific mode. If no mode is specified, default to **careful**.

### Careful Mode (default)

**What it does:** Warns before any potentially destructive operation but does not block.

When you detect a destructive operation, pause and present:

```
⚠️  GUARD: Potentially destructive operation detected
Operation: {{what you're about to do}}
Impact: {{what could go wrong}}
Reversible: {{yes/no — if yes, how}}

Proceed? [y/n]
```

Use `AskUserQuestion` to get explicit confirmation before proceeding.

**Destructive operations include:**
- `rm -rf`, `rm -r` on directories
- `git reset --hard`, `git push --force`, `git branch -D`
- `DROP TABLE`, `DELETE FROM` without WHERE, `TRUNCATE`
- `kubectl delete`, `docker rm`, `docker system prune`
- Writing to production configs or `.env` files
- Modifying CI/CD pipeline files
- Any operation the `guard/bin/check-dangerous.sh` script flags

### Freeze Mode

**What it does:** Blocks all file writes (Edit, Write) outside of a specified scope.

When the user says `/freeze` or `/guard freeze`:
1. Ask which directories/files are in scope (or accept them as arguments)
2. Store the scope in `guard/config.json`
3. For the remainder of the session, block any Edit or Write operation outside the frozen scope

```json
// guard/config.json
{
  "mode": "freeze",
  "allowed_paths": [
    "src/feature/**",
    "tests/feature/**"
  ],
  "frozen_at": "2025-01-01T00:00:00Z"
}
```

When a write is attempted outside scope:
```
🔒 GUARD FREEZE: Write blocked
File: {{path}}
Reason: Not in allowed scope
Allowed: {{list of allowed paths}}

To unfreeze: /unfreeze
```

### Unfreeze Mode

**What it does:** Removes freeze restrictions.

When the user says `/unfreeze` or `/guard unfreeze`:
1. Remove the freeze config
2. Confirm guardrails are now in careful mode (not fully off)

```
🔓 GUARD: Freeze lifted. Returning to careful mode.
```

## The Check Script

`guard/bin/check-dangerous.sh` uses a three-tier permission system inspired by [Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode):

**Tier 1: Allowlist.** Commands like `git status`, `ls`, `cat`, `jq` skip all checks. Safe by definition.

**Tier 2: In-project.** Operations that only touch files inside the current git repo pass through. They're reviewable via version control.

**Tier 3: Pattern matching.** Everything else is checked against block and warn rules in `guard/rules.json`.

When a command is blocked, guard suggests a safer alternative instead of just failing:

```
BLOCKED [G-007] Force push overwrites remote history
Category: history-destruction
Command: git push --force origin main

Safer alternative: git push --force-with-lease (safer, fails if remote changed)
```

### Configurable rules

Rules live in `guard/rules.json`. 28 block rules and 9 warn rules ship by default across 7 categories: mass-deletion, history-destruction, database-destruction, infra-destruction, production-access, remote-code-execution, security-degradation, safety-bypass.

Users can add custom rules by editing `guard/rules.json`. Each rule has an ID, regex pattern, category, description, and (for block rules) a safer alternative.

## Telemetry finalize

Before returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" guard success
unset _F
```

Pass `abort` or `error` instead of `success` if guard did not complete normally.

## Gotchas

- **Guard is session-scoped.** It activates when you invoke `/guard` and lasts until the session ends. It does not persist across sessions. This is intentional — always-on guardrails train people to ignore them.
- **Careful mode warns, it does not block.** The user can always say "yes, proceed." The point is to force a conscious decision, not to prevent all risk.
- **Freeze mode is for focus, not security.** It prevents accidental edits to unrelated files during debugging. It's not an access control mechanism.
- **Don't guard trivial operations.** `rm` on a single test file is not dangerous. `rm -rf /` is. The script is calibrated for genuinely destructive patterns.
- **The script is a first line, not the only line.** Use your judgment too. A command that passes the script but clearly targets production should still be flagged.
