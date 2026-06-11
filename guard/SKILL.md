---
name: guard
description: Use when working near production, sensitive systems, or destructive operations. Activates on-demand safety hooks that block dangerous commands. Supports modes — careful (warn), freeze (guided, keeps writes within scope), unfreeze (remove restrictions). Triggers on /guard, /careful, /freeze, /unfreeze.
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

**What it does:** Asks the agent to keep its file writes (Edit, Write) within a
chosen scope for the rest of the session. This is a guided instruction the agent
follows, not a hook-enforced block: unlike the secret and system-path denylist
in `check-write.sh`, the Write/Edit hook does not currently reject an
out-of-scope write. Treat freeze as agent-level discipline, not a wall.

When the user says `/freeze` or `/guard freeze`:
1. Ask which directories/files are in scope (or accept them as arguments)
2. Store the scope in `guard/config.json`
3. For the remainder of the session, keep Edit and Write operations within the
   frozen scope and decline anything outside it

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

When you are about to write outside the frozen scope, decline and say so (the
hook does not stop the write for you, so this is on the agent to honor):
```
🔒 GUARD FREEZE: declining write outside the frozen scope
File: {{path}}
Reason: not in the allowed scope
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

`guard/bin/check-dangerous.sh` runs every Bash call through a layered check pipeline. The order is deliberate: block rules run first so commands whose binary is on the allowlist (`cat`, `find`, `head`, `tail`) still get matched against known-bad patterns (e.g. `cat .env`, `find . -delete`).

**Block rules** (run first, no exceptions). Matched against the full command string. The current rule counts are loaded from `guard/rules.json`; this doc does not hand-maintain them.

**Allowlist.** Commands like `git status`, `ls`, `jq` short-circuit when no block rule matched.

**Phase-aware concurrency.** When a session is active and the current phase declares `concurrency: read` (built-in or custom), write commands are blocked with category `concurrency-safety`. The active phase's `SKILL.md` is resolved through `bin/lib/phases.sh` so custom phases get the same protection as built-in ones. Detection covers more than the obvious utilities: output redirection to anything except `/dev/*`, in-place editors (`sed -i`, `perl -i`), `tee`/`truncate`/`patch`/`install`, inline interpreter code (`python -c`, `node -e`, `sh -c`, whose quoted body is invisible to pattern checks), and git worktree mutations (`stash`, `restore`, `checkout`, `merge`, `rebase`, `apply`, `clean`). Quoted segments are stripped first so a read like `awk '$3 > 5' file` is never mistaken for redirection. The regression lock is `ci/e2e-read-phase-writes.sh`.

**In-project fast-path.** Operations that only touch files inside the current git repo pass through. Reviewable via version control. Runs after the concurrency check so an in-project `touch ./foo` cannot bypass a read-phase block.

**Sprint phase gate.** Blocks `git commit` / `git push` until the required-before-ship ancestors of the active `phase_graph` have completed. The built-in sprint defaults to review + security + qa; custom graphs gate on their own ancestor list.

**Budget gate.** Blocks all commands when the configured budget is exceeded. A small set of safe reads (`git status`, `git diff`, `ls`, `cat`) stay runnable so you can inspect and save work behind the wall. This gate is a cost cap, not a sandbox: it does not defend against a repository whose own git config runs helper programs (`diff.external`, textconv, `core.fsmonitor`, filters, hooks), since those run on any git command regardless of the gate. Command-line vectors that turn a read into command execution (`-c`, `--ext-diff`, `--output`, `--exec-path=`) are rejected from the read exemption.

**Warn rules.** Final pass: matched commands are allowed but flagged in the output so the user is reminded what they're doing.

When a command is blocked, guard suggests a safer alternative instead of just failing:

```
BLOCKED [G-007] Force push overwrites remote history
Category: history-destruction
Command: git push --force origin main

Safer alternative: git push --force-with-lease (safer, fails if remote changed)
```

### Configurable rules

Rules live in `guard/rules.json`. Each rule has an ID, regex pattern, category, description, and (for block rules) a safer alternative. The shipped categories include mass-deletion, history-destruction, database-destruction, infra-destruction, production-access, remote-code-execution, security-degradation, and safety-bypass. Run `jq '[.tiers.block.rules[].id] | length' guard/rules.json` (or the equivalent for warn rules) to inspect the live counts; the CI lint job derives them from this file.

Users can add custom rules by editing `guard/rules.json`.

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
