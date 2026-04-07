---
name: feature
description: Add a feature to an existing project with a full sprint. Skips /think diagnostic, goes straight to planning. Use when the user knows what they want and the project already exists. Triggers on /feature.
concurrency: read
depends_on: []
summary: "Fast sprint for incremental features. Reads existing artifacts, plans, builds, reviews, audits, ships."
estimated_tokens: 200
hooks:
  PreToolUse:
    - matcher: Bash
      command: "./feature/bin/enforce-sprint.sh"
---

# /feature — Add a Feature

Fast path for adding a feature to an existing project. Skips the /think diagnostic and runs the full sprint via skill invocations.

```
/feature Add import from JSON/CSV to restore backups
```

## Setup

Before anything else, ensure the project is configured. Run this once (skips if already done):

```bash
[ -f .claude/settings.json ] || ~/.claude/skills/nanostack/bin/init-project.sh
```

## Session

Initialize the sprint session:

```bash
~/.claude/skills/nanostack/bin/session.sh init feature
```

Then run `session.sh phase-start plan`. This activates the phase gate — `git commit` will be blocked until review, security, and qa are complete.

## Process

You are an orchestrator. You invoke each skill in sequence using the Skill tool. Do NOT implement the skill logic yourself — invoke the skill and let it run.

### Step 1: Context

Read existing artifacts to understand the project:

```bash
~/.claude/skills/nanostack/bin/find-artifact.sh think 30
~/.claude/skills/nanostack/bin/find-artifact.sh plan 30
~/.claude/skills/nanostack/bin/find-artifact.sh ship 30
```

Read the checkpoint summaries. If no artifacts exist, read the codebase directly.

### Step 2: Plan

Invoke the nano skill using the Skill tool. Pass the feature description as context:

```
Use Skill tool: skill="nano"
```

Wait for /nano to complete. It will save its own artifact.

### Step 3: Build

After /nano completes and the user approves the plan, build the feature.

### Step 4: Review

After build completes, invoke the review skill:

```
Use Skill tool: skill="review"
```

Wait for /review to complete. It saves its own artifact. If blocking issues found, fix them before continuing.

### Step 5: Security

```
Use Skill tool: skill="security"
```

Wait for /security to complete. If critical findings, fix before continuing.

### Step 6: QA

```
Use Skill tool: skill="qa"
```

Wait for /qa to complete. If tests fail, fix before continuing.

### Step 7: Ship

```
Use Skill tool: skill="ship"
```

/ship commits, creates PR if remote exists, generates sprint journal, and shows the result with next feature suggestions.

## Rules

- Each skill is invoked via the Skill tool, not implemented inline.
- Each skill saves its own artifact. You do not save artifacts — the skills do.
- Between steps, show brief status: `Feature: review complete. Running /security...`
- Stop the sequence if any skill finds blocking issues or critical vulnerabilities.
- If the feature already exists in the codebase, tell the user and suggest alternatives.
