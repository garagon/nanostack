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

## Response

Print this directly:

```
nanostack
Make your AI agent think first.

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
  /launch                Deploy to production. Hosting, domain, SSL, monitoring.
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

github.com/garagon/nanostack
```

If the user asks about a specific skill, invoke it: use Skill tool with the skill name. Don't explain the skill yourself — let the skill's own SKILL.md handle it.
