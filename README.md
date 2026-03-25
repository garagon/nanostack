# Nanostack

Minimal AI coding agent team skills for the full engineering workflow. Inspired by [gstack](https://github.com/garrytan/gstack) from [Garry Tan](https://x.com/garrytan).

Other tools help you write code faster. Nanostack questions what you're building before you build it. It tells you "that's a 3-week project, but this version ships today" and it's usually right. Then it plans, reviews, tests, audits security, and ships. One person does the work of a full team.

**8 skills. Any agent. Zero dependencies. Zero build step.**

## Quick start

```bash
git clone https://github.com/garagon/nanostack.git ~/.claude/skills/nanostack
cd ~/.claude/skills/nanostack && ./setup
```

That's it. Now try this:

```
You:    I need to add notifications to my app. Users keep missing
        replies on their posts.
You:    /think

Agent:  Before we build anything, how are users coping today?

You:    They open the app 3-4 times a day just to check. Sometimes
        they miss replies for hours. People are frustrated.

Agent:  I'm going to push back on "notifications." You said users open
        the app 3-4 times a day. That's high engagement. They already
        come back. The problem isn't that they can't be reached. The
        problem is that when they arrive, they can't tell what changed.

        That's a freshness problem, not a messaging problem.

        A notification system (email, push, in-app, preferences,
        digest, unsubscribe) is a 3-week project. A red dot on the
        nav icon that says "something new" ships this afternoon.

        One solves the symptom (they're not being told). The other
        solves the cause (they can't see what's new when they look).

        RECOMMENDATION: Reduce. Ship the dot. See if complaints drop.
        If they do, you just saved 3 weeks. If they don't, then build
        push notifications, but now you have data, not a guess.

You:    Makes sense. Let's do the dot.
You:    /plan
        [3 steps, 2 files, product standards: shadcn/ui + Tailwind]

You:    [builds it]

You:    /review
        Review: 2 findings (1 auto-fixed, 1 nit). 2 things done well.

You:    /ship
        Ship: PR created. Tests pass. Done.
```

You said "notifications." The agent said "your users have a freshness problem" and found a solution that ships in an afternoon instead of three weeks. Four commands. That is not a copilot. That is a thinking partner.

## The sprint

Nanostack is a process, not a collection of tools. The skills run in the order a sprint runs:

```
/think → /plan → build → /review → /qa → /security → /ship
```

Each skill feeds into the next. `/plan` writes an artifact that `/review` reads for scope drift detection. `/review` catches conflicts with `/security` findings. `/ship` verifies everything is clean before creating the PR. Nothing falls through the cracks because every step knows what came before it.

| Skill | Your specialist | What they do |
|-------|----------------|--------------|
| `/think` | **CEO / Founder** | Start here. Six forcing questions that reframe your product before you write code. Challenges premises, checks your ambition level, finds the narrowest wedge. |
| `/plan` | **Eng Manager** | Scope, steps, files, risks, architecture checkpoint. Enforces product standards on frontend (shadcn/ui, SEO, LLM discoverability). |
| `/review` | **Staff Engineer** | Two-pass code review: structural then adversarial. Auto-fixes mechanical issues, asks about judgment calls. Detects scope drift against the plan. |
| `/qa` | **QA Lead** | Test your code, find bugs, fix them, re-verify. Browser, API, CLI, and debug modes. `--report-only` for findings without fixes. |
| `/security` | **Security Engineer** | Auto-detects your stack, scans secrets, injection, auth, CI/CD, AI/LLM vulnerabilities. Graded report (A-F). Every finding includes the fix. |
| `/ship` | **Release Engineer** | Pre-flight checks, PR creation, CI monitoring, post-deploy verification with error rate threshold. Rollback plan included. |

### Power tools

| Skill | What it does |
|-------|-------------|
| `/guard` | On-demand safety guardrails. Warns before destructive commands. `/freeze` locks edits to one directory. Activate when touching prod. |
| `/conductor` | Orchestrate parallel agent sessions through a sprint. Agents claim phases, resolve dependencies, hand off artifacts. No daemon, just atomic file ops. |

### Intensity modes

Not every change needs a full audit. `/review`, `/qa`, and `/security` support three modes:

| Mode | Flag | When to use |
|------|------|-------------|
| **Quick** | `--quick` | Typos, config, docs. Only report the obvious. |
| **Standard** | (default) | Normal features and bug fixes. |
| **Thorough** | `--thorough` | Auth, payments, infra. Flag everything suspicious. |

## See it work: full sprint

```
You:    I want to build a security scanner for cloud misconfigurations.
        We keep finding S3 buckets left public and IAM roles that are
        way too broad. Last month a public bucket caused an incident.
You:    /think

Agent:  I'm going to push back on "security scanner." A scanner finds
        problems after they exist. But you said last month a public
        bucket caused an incident. You don't want to find misconfigs,
        you want to stop them from reaching production.

        That's a prevention gate, not a scanner. Different product.

        The scanner is 10% better than what you have (manual audits).
        A pre-deploy gate is 10x. The misconfiguration never ships.

        Who would use a broken v1 tomorrow? Your platform team. They
        got paged for that incident. They'd use anything that blocks
        public S3 buckets before deploy, even if it only checks one rule.

        RECOMMENDATION: Reduce scope. One rule. S3 public access check,
        pre-deploy. Ship tomorrow. The full scanner is a 3-month project.

You:    That makes sense. Let's start with S3.
You:    /plan
        [5 steps, 4 files, risks listed, out-of-scope explicit]

You:    [builds the feature]

You:    /review
        Review: 3 findings (2 auto-fixed, 1 ask). Scope drift: CLEAN.

You:    /security
        Security: CRITICAL (0) HIGH (0) MEDIUM (1) LOW (1). Score: A.

You:    /ship
        Ship: PR created. CI passed. Post-deploy: smoke test clean.
```

You said "security scanner." The agent said "you're building a prevention gate" because it listened to your pain, not your feature request. Six commands, start to shipped.

## Parallel sprints

Nanostack works well with one agent. It gets interesting with three running at once.

`/conductor` coordinates multiple sessions. Each agent claims a phase, executes it, and the next agent picks up the artifact. Review, QA, and security run in parallel because they all depend on build, not on each other.

```
/think → /plan → build ─┬─ /review   (Agent A) ─┐
                        ├─ /qa       (Agent B)  ├─ /ship
                        └─ /security (Agent C) ─┘
```

No daemon. No message queue. Just `mkdir` for atomic locking, JSON for state, symlinks for artifact handoff.

## Install

```bash
# Claude Code (recommended)
git clone https://github.com/garagon/nanostack.git ~/.claude/skills/nanostack
cd ~/.claude/skills/nanostack && ./setup

# OpenAI Codex
git clone https://github.com/garagon/nanostack.git ~/nanostack
cd ~/nanostack && ./setup --host codex

# Amazon Kiro
git clone https://github.com/garagon/nanostack.git ~/nanostack
cd ~/nanostack && ./setup --host kiro

# Auto-detect all installed agents
./setup --host auto
```

### Update

```bash
bin/upgrade.sh
```

Shows what changed, re-runs setup if needed. Or just `git pull`.

No build step. Skills use symlinks. Changes take effect immediately.

## The Zen of Nanostack

```
Question the requirement before writing the code.
Delete what shouldn't exist.
If nobody would use a broken v1, the scope is wrong.
Narrow the scope, not the ambition.
Ship the version that ships today.
Fix it or ask. Never ignore it.
Security is not a tradeoff. It is a constraint.
The output should look better than what was asked for.
If the plan is hard to explain, the plan is wrong.
```

Full version in [`ZEN.md`](ZEN.md).

## Know-how

Most AI coding tools are stateless. Every session starts from zero. Your agent doesn't remember that last month's auth refactor took three weeks because scope drifted twice, or that `/review` and `/security` disagreed on error verbosity and you resolved it with structured error codes.

Nanostack remembers.

Every sprint produces structured artifacts — JSON from each phase, saved to `~/.nanostack/`. The know-how system turns those artifacts into a knowledge base that gets more useful the more you use it.

### What gets captured

**Sprint journals.** One entry per sprint with the full decision trail: what `/think` reframed, what `/plan` scoped, what `/review` found, what `/security` graded, what `/ship` deployed.

**Conflict precedents.** When `/review` says "add detail to errors" and `/security` says "don't expose internals," the resolution gets recorded ([10 built-in](reference/conflict-precedents.md)). Next time the same tension appears, it's resolved instantly — not debated again. New precedents accumulate as you work.

**Learnings.** Things that surprised you. Patterns you noticed. Decisions you'd make differently. Captured in the moment, searchable later.

**Analytics.** Phase counts, intensity modes, security score trends. See how your process changes over time — are you running more thorough reviews? Is scope drift decreasing? Are security grades improving?

### The Obsidian vault

Everything lives in `~/.nanostack/know-how/` and works as an Obsidian vault. Sprint journals link to conflict precedents. The dashboard links to journals. Learnings link to the sprints where they happened.

```bash
bin/sprint-journal.sh          # generate journal entry from sprint artifacts
bin/analytics.sh --obsidian    # generate dashboard with phase counts and trends
bin/capture-learning.sh "..."  # capture a learning from a sprint
```

Open `~/.nanostack/know-how/` in Obsidian and switch to graph view. Sprints, conflicts, and learnings are linked — you can trace any decision back to the sprint where it happened.

### Why this matters

After ten sprints you have a decision log that shows how your team thinks. After fifty you have institutional knowledge that survives context switches, onboarding, and team changes. The data tells you where your process is strong and where it's weak.

No other AI coding tool does this. They help you write code today and forget everything tomorrow. Nanostack doesn't — every sprint makes the next one better.

## Privacy

All data stays on your machine in `~/.nanostack/`. No remote calls. No telemetry.

Run `bin/analytics.sh` to see your own usage: which skills you run, how often, in what mode. Reads local artifacts only.

## Troubleshooting

**Skills don't appear as slash commands.**
The setup script creates symlinks. If they broke, re-run `./setup`.

**`jq: command not found` when running scripts.**
Install jq: `brew install jq` (macOS) or `apt install jq` (Linux).

**Port in use when running /qa browser tests.**
Find it: `lsof -ti:3000`. Kill it: `kill $(lsof -ti:3000)`.

**`/conductor` claim fails with BLOCKED.**
Dependencies not finished. Run `conductor/bin/sprint.sh status` to check.

**Skills seem outdated.**
Run `bin/upgrade.sh` to pull latest and re-run setup.

## Uninstall

```bash
# Claude Code
cd ~/.claude/skills && rm -f think plan review qa security ship guard conductor && rm -rf nanostack

# Codex
rm -rf ~/.codex/skills/nanostack*

# Kiro
rm -rf ~/.kiro/skills/nanostack
```

## License

Apache 2.0
