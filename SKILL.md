---
name: nanostack
description: Use when the user asks about available workflow skills, wants an overview of the engineering workflow, or references "nanostack". Also triggers on /nanostack.
---

# Nanostack — Engineering Workflow Skills

You have access to a set of composable engineering workflow skills. Each skill is a folder with supporting files — read them as needed for context.

## Available Skills

| Skill | When to use | Modes | Key files |
|-------|-------------|-------|-----------|
| `/think` | Before planning — strategic product thinking, premise validation, scope decisions. | — | `think/references/forcing-questions.md`, `think/references/cognitive-patterns.md` |
| `/nano-plan` | Before starting any non-trivial work. Produces a scoped, actionable plan. | — | `plan/templates/plan-template.md` |
| `/review` | After code is written. Two-pass review + scope drift detection + conflict resolution. | `--quick` `--standard` `--thorough` | `review/checklist.md`, `reference/conflict-precedents.md` |
| `/qa` | To verify code works. Browser-based testing with Playwright, plus root-cause debugging. | `--quick` `--standard` `--thorough` | `qa/bin/screenshot.sh` |
| `/security` | Before shipping. OWASP Top 10 + STRIDE + variant analysis + conflict detection. | `--quick` `--standard` `--thorough` | `security/references/owasp-checklist.md`, `security/templates/security-report.md` |
| `/ship` | To create PRs, merge, deploy, and verify. Generates sprint journal on success. | — | `ship/templates/pr-template.md` |
| `/guard` | When working near production, destructive operations, or sensitive systems. | — | `guard/bin/check-dangerous.sh` |
| `/conductor` | Orchestrate parallel agent sessions through a sprint. Coordinate task claiming and artifact handoff. | `start` `claim` `complete` `status` | `conductor/bin/sprint.sh` |

## Workflow Order

The default workflow is: `/think` → `/nano-plan` → build → `/review` → `/qa` → `/security` → `/ship`

With `/conductor`, review + qa + security run **in parallel** — they all depend on build, not on each other:

```
think → plan → build ─┬─ review  ─┐
                      ├─ qa       ├─ ship
                      └─ security ─┘
```

Activate `/guard` at any point when operating near production or sensitive systems.

## Zen

Read `ZEN.md` for the full set of principles. When in doubt about a decision during any skill, consult it. The short version:

- Question the requirement before writing the code.
- Delete what shouldn't exist. Don't optimize what's left until you do.
- Narrow the scope, not the ambition.
- Fix it or ask. Never ignore it.
- Security is not a tradeoff. It is a constraint.
- The output should look better than what was asked for.

## Intensity Modes

Skills `/review`, `/security`, and `/qa` support intensity modes:

| Mode | Flag | When | Confidence |
|------|------|------|-----------|
| **Quick** | `--quick` | Trivial changes (typos, config, docs) | 9/10 — only the obvious |
| **Standard** | (default) | Normal changes | 7/10 — anything reasonable |
| **Thorough** | `--thorough` | Critical changes (auth, payments, infra) | 3/10 — flag everything suspicious |

Skills auto-suggest a mode based on the diff, but the user always decides.

## Artifact Persistence

Skills automatically save their output to `.nanostack/` after every run:

```bash
.nanostack/<phase>/<timestamp>.json
```

This enables:
- **Scope drift detection** — `/review` compares planned vs actual files
- **Conflict detection** — `/review` and `/security` cross-reference each other's findings
- **Sprint journals** — `/ship` generates a journal entry from all phase artifacts
- **Trend tracking** — Are security findings decreasing over time?

Auto-saving is on by default. The user can disable it by setting `auto_save: false` in `.nanostack/config.json`.

Artifacts are validated before saving: `save-artifact.sh` rejects invalid JSON, missing required fields (`phase`, `summary`), and phase mismatches.

To discard artifacts from a bad session: `bin/discard-sprint.sh` (removes artifacts and journal entry for the current project and date).

## Conflict Resolution

When skills produce contradictory guidance (e.g., `/review` says "more error detail" but `/security` says "minimize error exposure"), the conflict resolution framework applies:

1. **Security has default precedence** — unless the risk is theoretical or internal-only
2. **Context determines final precedence** — public-facing app vs internal tool vs startup vs compliance
3. **Conflicts are documented, not silenced** — every resolution is recorded in the skill artifact

Read `reference/conflict-precedents.md` for known conflict patterns and pre-defined resolutions.

## Project Config

On first use in a project, run `bin/init-config.sh --interactive` to create `.nanostack/config.json`. This stores:

- **Installed agents** — auto-detected (claude, codex, kiro)
- **Detected stack** — node, go, python, docker
- **Preferences** — default intensity mode, auto-save, conflict precedence

If config exists, read it at the start of any skill to adapt behavior:
```bash
bin/init-config.sh  # outputs current config or {} if none
```

Skills use config for:
- `/review`, `/qa`, `/security`: read `preferences.default_intensity` instead of always defaulting to standard
- `/security`: read `preferences.conflict_precedence` to determine who wins in cross-skill conflicts
- `/security`: read `detected` to skip irrelevant checks (don't scan for Python vulns in a Go project)

Per-skill configs (`security/config.json`, `guard/config.json`) store skill-specific settings and are read by that skill only.

## Universal Rules

- **Read before acting.** Every skill must read the relevant code/diff/config before producing output. Never analyze blind.
- **Boil the lake, not the ocean.** When completeness costs minutes more than shortcuts, do the complete thing. When it costs days, don't.

## Proactive Triggers

Suggest skills when context matches — don't wait for the user to remember:

| Trigger | Suggest |
|---------|---------|
| User says "what should I build" / unclear on direction | `/think` |
| Task touches 3+ files or user says "how should I approach this" | `/nano-plan` |
| User says "done", "finished", "ready for review" | `/review` |
| User says "does this work", "test this", bug report | `/qa` |
| Pre-ship, user says "ready to deploy", or diff touches auth/env/infra | `/security` |
| User says "create PR", "merge", "ship it" | `/ship` |
| Destructive commands, production access, or sensitive operations detected | `/guard` |

## Usage Rules

- Start with `/think` for new products or when the "what" is unclear
- Run `/nano-plan` before building anything that touches more than 3 files
- Run `/review` on your own code — the adversarial pass catches what you missed
- `/security` is not optional before shipping to production
- `/guard` is on-demand — activate it, don't leave it always on
- Skills compose: `/qa` can invoke `/security` checks, `/ship` can invoke `/review`
