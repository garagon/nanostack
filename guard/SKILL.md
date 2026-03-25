---
name: guard
description: Use when working near production, sensitive systems, or destructive operations. Activates on-demand safety hooks that block dangerous commands. Supports modes — careful (warn), freeze (block writes outside scope), unfreeze (remove restrictions). Triggers on /guard, /careful, /freeze, /unfreeze.
hooks:
  PreToolUse:
    - matcher: Bash
      command: "./guard/bin/check-dangerous.sh"
---

# /guard — Safety Guardrails

You have activated safety guardrails. These protect against accidental destructive operations during this session.

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

`guard/bin/check-dangerous.sh` receives the Bash command as input and exits non-zero if the command matches a dangerous pattern. The hook system calls this automatically on every Bash tool use while /guard is active.

The script checks for:
- Force operations (--force, -f with destructive commands)
- Mass deletion (rm -rf, find -delete)
- Git history destruction (reset --hard, push --force, rebase on shared branches)
- Database destruction (DROP, TRUNCATE, DELETE without WHERE)
- Container/infra destruction (kubectl delete, docker rm)
- Production environment access (production, prod in connection strings)

## Gotchas

- **Guard is session-scoped.** It activates when you invoke `/guard` and lasts until the session ends. It does not persist across sessions. This is intentional — always-on guardrails train people to ignore them.
- **Careful mode warns, it does not block.** The user can always say "yes, proceed." The point is to force a conscious decision, not to prevent all risk.
- **Freeze mode is for focus, not security.** It prevents accidental edits to unrelated files during debugging. It's not an access control mechanism.
- **Don't guard trivial operations.** `rm` on a single test file is not dangerous. `rm -rf /` is. The script is calibrated for genuinely destructive patterns.
- **The script is a first line, not the only line.** Use your judgment too. A command that passes the script but clearly targets production should still be flagged.
