---
name: feature
description: Add a feature to an existing project with a full sprint. Skips /think diagnostic, goes straight to planning. Use when the user knows what they want and the project already exists. Triggers on /feature.
concurrency: read
depends_on: []
summary: "Fast sprint for incremental features. Reads existing artifacts, plans, builds, reviews, audits, ships."
estimated_tokens: 200
---

# /feature — Add a Feature

Fast path for adding a feature to an existing project. Skips the /think diagnostic (the user already knows what they want) and goes straight to planning with full project context.

## How it works

```
/feature Add JSON and CSV export for habit data backup
```

The agent:
1. Reads existing artifacts to understand the project
2. Plans the change (/nano)
3. Builds it
4. Reviews, audits, tests, ships (autopilot)

## Process

### 1. Load project context

Read the most recent artifacts to understand what exists:

```bash
~/.claude/skills/nanostack/bin/find-artifact.sh think 30
~/.claude/skills/nanostack/bin/find-artifact.sh plan 30
~/.claude/skills/nanostack/bin/find-artifact.sh ship 30
```

Read the checkpoint summaries from each. If no artifacts exist, read the codebase directly.

### 2. Plan the feature

Follow the full `/nano` process: evaluate scope, generate specs if needed, list planned files, identify risks. Read `plan/SKILL.md` for the detailed protocol.

After the plan is ready, save the artifact — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh plan '<json with phase, summary including planned_files array, context_checkpoint including summary, key_files, decisions_made, open_questions>'
```

Present the plan to the user. Wait for approval.

### 3. Build, review, audit, test, ship

After the user approves, set `AUTOPILOT=true` and run the full sprint:

`build` → `/review` → `/security` → `/qa` → `/ship`

Each phase saves its artifact. Between steps show status:

> Feature: build complete. Running /review...
> Feature: review clean. Running /security...
> Feature: security grade A. Running /qa...
> Feature: qa passed. Running /ship...

Only stop if:
- `/review` finds blocking issues
- `/security` finds critical vulnerabilities
- `/qa` tests fail

### 4. Close

Follow the /ship closing protocol: what was built, how to see it, and 2-3 ideas for next features using `/feature`.
