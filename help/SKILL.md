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
Nanostack Skills
================

Getting started:
  /nano-run          First-time setup. Configures your project conversationally.

The sprint (run in order):
  /think             Challenge the idea before building. Scope decisions.
  /nano              Plan the implementation. Files, steps, risks.
  build              You or the agent writes the code.
  /review            Two-pass code review. Scope drift detection.
  /security          OWASP Top 10 + STRIDE audit. Graded A-F.
  /qa                Test it. Browser, API, CLI, or debug.
  /ship              Create PR, verify CI, generate sprint journal.

Shortcuts:
  /think --autopilot Run the full sprint automatically after approval.
  /feature <desc>    Add a feature with plan → build → review → security → qa → ship.

After shipping:
  /compound          Document what you learned. Future sprints find it automatically.

Safety:
  /guard             Block dangerous commands. /freeze locks edits to one directory.

Team:
  /conductor         Parallel sprints across multiple agents/terminals.

Modes (for /review, /security, /qa):
  --quick            Only the obvious. For small changes.
  --standard         Default. For normal work.
  --thorough         Flag everything. For auth, payments, infra.

Update:
  /nano-update       Pull latest version of nanostack.
```

If the user asks about a specific skill, invoke it: use Skill tool with the skill name. Don't explain the skill yourself — let the skill's own SKILL.md handle it.
