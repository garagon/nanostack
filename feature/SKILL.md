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

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" feature
unset _P
```

## Setup

Before anything else, ensure the project is configured. Run this once (skips if already done):

```bash
[ -f .claude/settings.json ] || ~/.claude/skills/nanostack/bin/init-project.sh
```

## Session

Initialize the sprint session with autopilot and explicit plan auto-approval. `--autopilot` already implies `--plan-approval auto` per the session contract, but passing it explicitly makes the intent obvious to anyone reading `session.json`.

```bash
~/.claude/skills/nanostack/bin/session.sh init feature --autopilot --plan-approval auto
```

Manual feature work should use `/think` + `/nano` instead. `/feature` itself does not accept a manual mode flag.

Then run `session.sh phase-start plan`. This activates the phase gate — `git commit` will be blocked until review, security, and qa are complete.

## Process

You are an autonomous orchestrator. You run the entire sprint without stopping between phases. Do NOT wait for user input between steps. Do NOT ask "should I continue?" or "ready for review?". Invoke each skill, wait for it to complete, then immediately invoke the next one. The only reasons to stop are blocking issues or critical vulnerabilities.

**Auto-approval contract for sub-skills.** The session records `plan_approval=auto` and `autopilot=true`, so `/nano`, `/review`, `/security`, `/qa`, and `/ship` read those fields and behave accordingly: present briefly, do not pause for approval. If any of them asks "ready to proceed?", treat it as a regression in that skill, not a signal to stop.

### Step 1: Context

Resolve existing artifacts and solutions in one call:

```bash
~/.claude/skills/nanostack/bin/resolve.sh feature
```

The output is JSON with `upstream_artifacts` (think, plan, ship paths if recent) and `solutions` (ranked past learnings). Read the checkpoint summaries. If no artifacts exist, read the codebase directly.

### Step 2: Plan

```
Use Skill tool: skill="nano"
```

Wait for /nano to complete. It saves its own artifact. Then immediately build.

### Step 3: Build

Build the feature. Do not ask for approval. The plan was the contract.

### Step 4: Review + Security + QA (parallel)

These three phases are independent. They all read the build output but don't depend on each other. Launch all three using the Agent tool in a single message with three parallel tool calls:

```
Agent: subagent_type="general-purpose", prompt="Run /review on this project. Use Skill tool: skill='review'"
Agent: subagent_type="general-purpose", prompt="Run /security on this project. Use Skill tool: skill='security'"
Agent: subagent_type="general-purpose", prompt="Run /qa on this project. Use Skill tool: skill='qa'"
```

If parallel agents are not available, fall back to sequential:
```
Use Skill tool: skill="review"
Use Skill tool: skill="security"
Use Skill tool: skill="qa"
```

If any phase finds blocking issues or critical vulnerabilities: fix them, then re-run that phase only.

`Feature: review + security + qa complete. Running /ship...`

### Step 7: Ship

```
Use Skill tool: skill="ship"
```

/ship commits, creates PR if remote exists, generates sprint journal, runs /compound, and shows the result with next feature suggestions.

## Telemetry finalize

Before returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" feature success
unset _F
```

Pass `abort` or `error` instead of `success` if the feature flow did not complete normally.

## Rules

- **Do not stop between phases.** This is the most important rule. Plan → build → review → security → qa → ship runs as one continuous flow. No pauses, no questions, no confirmations.
- Each skill is invoked via the Skill tool, not implemented inline.
- Each skill saves its own artifact. You do not save artifacts — the skills do.
- Between steps, show one line of status: `Feature: review complete. Running /security...`
- Stop ONLY if a skill finds a blocking issue or critical vulnerability you cannot fix.
- If the feature already exists in the codebase, tell the user and suggest alternatives.
