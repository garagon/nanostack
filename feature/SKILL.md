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

For a direct invocation, initialize the sprint session with autopilot and explicit plan auto-approval. When `/think` hands off a completed autopilot brief, keep that active session instead: do not archive it or initialize a replacement. Confirm its workspace matches the current project, `type=development`, `autopilot=true`, `run_mode=normal`, think is completed, no phase is in progress, and plan has not started. If that handoff state is inconsistent, stop and report it rather than overwrite the session.

```bash
~/.claude/skills/nanostack/bin/session.sh init feature --autopilot --plan-approval auto
```

Manual feature work should use `/think` + `/nano` instead. `/feature` itself does not accept a manual mode flag.

Let `/nano` start the plan phase. Phase-gate enforcement depends on the active adapter; do not describe guided hosts as hook-enforced.

## Process

You are the full-sprint coordinator. Invoke each specialist once and wait for its result. Continue routine work without asking permission between phases; stop for unresolved scope, unsafe test environments, blocking findings you cannot fix, or an action requiring user authorization.

**Auto-approval is not publication permission.** `plan_approval=auto` approves planning, not PR creation, merge, or deployment. Preserve `/ship`'s preview and explicit authorization requirements. Tell delegated specialists to return their artifacts and findings to this coordinator, not launch another phase.

### Step 1: Context

Resolve existing artifacts and solutions in one call:

```bash
~/.claude/skills/nanostack/bin/resolve.sh feature
```

The output is JSON with `upstream_artifacts` (think, plan, ship paths if recent) and `solutions` (ranked past learnings). Read the checkpoint summaries. If no artifacts exist, read the codebase directly.

### Step 2: Plan

```
Invoke /nano using the active host's skill mechanism.
```

Wait for /nano to complete. It saves its own artifact. Then immediately build.

### Step 3: Build

Run `session.sh phase-start build`, then implement the approved plan. Run `session.sh phase-complete build` only after implementation finishes. Do not launch verification against an unfinished build.

### Step 4: Review + Security + QA (parallel)

Use native delegation only when the active host exposes it. Give each specialist the approved scope, build under test, and this boundary: inspect and report; do not edit product files, commit, or invoke another skill. QA must use isolated test data and output directories. Shared mutable services or fixtures require sequential verification.

Otherwise invoke `/review`, `/security`, and `/qa` sequentially using the host's skill mechanism. If delegation fails after any reader has started, wait for or cancel and confirm termination of that reader before falling back; never launch duplicate work against a still-running batch. Guided adapters rely on these instructions, not universal hook enforcement.

If verification finds blocking issues, wait for all readers to finish (or confirm cancellation), return to build, and apply repairs there. After any product change, re-run all three verification phases before `/ship`. Do not carry passing results from the previous build forward. If a repair exceeds approved scope, ask the user instead.

`Feature: review + security + qa complete. Running /ship...`

### Step 5: Ship

```
Invoke /ship using the active host's skill mechanism.
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

- **One orchestration owner.** `/feature` owns planning, build, verification, and the authorized shipping handoff. Specialists return results; they do not start another sprint.
- Invoke each skill through the active host's skill mechanism, not by reimplementing it inline.
- Each skill saves its own artifact. You do not save artifacts — the skills do.
- Between steps, show one line of status: `Feature: review complete. Running /security...`
- Stop when scope, safety, or publication authorization requires a user decision.
- If the feature already exists in the codebase, tell the user and suggest alternatives.
