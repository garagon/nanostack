---
name: nano-help
description: Quick reference for all nanostack commands. Shows available skills, what each one does, and how to use them. Triggers on /nano-help.
concurrency: read
depends_on: []
summary: "Help and quick reference for nanostack skills."
estimated_tokens: 100
---

# /nano-help — Quick Reference

Show the user a concise overview of nanostack. No walls of text. Organized by what they want to do.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" nano-help
unset _P
```

## Response

Print this directly:

```
nanostack
Make your AI agent think first.

What do you want to do?

  Start a brand new project       → /think (or /think --autopilot)
  Add to a project that exists    → /feature <what to add>
  Already wrote code, check it    → /review  (then /security, /qa)
  Ready to save / publish         → /ship
  First time using nanostack      → /nano-run
  Not sure where to start         → /think (it helps you decide)

Reference — every command:

Getting started:
  /nano-run              First-time setup. Configures your project conversationally.
  /nano-help             You are here.

The sprint:
  /think                 Challenge the scope before building.
  /nano                  Plan the implementation. Files, steps, risks.
  build                  You or the agent writes the code.
  /review                Two-pass code review. Scope drift detection.
  /security              OWASP Top 10 + STRIDE audit. Graded A-F.
  /qa                    Test it. Browser, API, CLI, or debug.
  /ship                  Create PR, verify CI, generate sprint journal.

Shortcuts:
  /think --autopilot     Full sprint. Think, plan, build, review, audit, test, ship.
  /feature <description> Add a feature to an existing project with full sprint.

After shipping:
  /compound              Save what you learned. Future sprints find it automatically.

Safety:
  /guard                 Block dangerous commands. /freeze locks edits to a scope.

Team:
  /conductor             Parallel sprints across multiple agents or terminals.

Modes (for /review, /security, /qa):
  --quick                Small changes. Only the obvious.
  --standard             Default. Normal work.
  --thorough             Auth, payments, infra. Flag everything.

Update:
  /nano-update           Pull latest version.
  /nano-doctor           Diagnose install health (deps, perms, telemetry).

github.com/garagon/nanostack
```

If the user asks about a specific skill, invoke it: use Skill tool with the skill name. Don't explain the skill yourself — let the skill's own SKILL.md handle it.

## Telemetry finalize

Before returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" nano-help success
unset _F
```

Pass `abort` or `error` instead of `success` if help did not complete normally.
