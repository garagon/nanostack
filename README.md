<h1 align="center">Nanostack</h1>
<p align="center">
  Turns your AI agent into an engineering team that challenges scope, plans, reviews, tests, audits and ships.<br>
  One sprint. Minutes, not weeks.
</p>

<br>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License"></a>
  <a href="https://github.com/garagon/nanostack/stargazers"><img src="https://img.shields.io/github/stars/garagon/nanostack?style=flat" alt="GitHub Stars"></a>
  <a href="https://skills.sh/garagon/nanostack"><img src="https://img.shields.io/badge/skills.sh-available-brightgreen" alt="skills.sh"></a>
</p>

<p align="center">
  <a href="#install">Install</a> &middot;
  <a href="#the-sprint">The Sprint</a> &middot;
  <a href="#autopilot">Autopilot</a> &middot;
  <a href="#guard">Guard</a> &middot;
  <a href="#know-how">Know-how</a> &middot;
  <a href="#build-on-nanostack">Extend</a> &middot;
  <a href="#contributing">Contributing</a>
</p>

---

Inspired by [gstack](https://github.com/garrytan/gstack) from [Garry Tan](https://x.com/garrytan). 9 skills. Zero dependencies. Zero build step.

Works with Claude Code, Cursor, OpenAI Codex, OpenCode, Gemini CLI, Antigravity, Amp and Cline.

## Quick start

```bash
npx create-nanostack
```

One command. Detects your agents, installs everything, runs setup. Works with Claude Code, Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, and Antigravity.

Then run `/nano-run` in your agent to configure your project through a conversation.

Or jump straight in:

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
You:    /nano
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
/think → /nano → build → /review → /qa → /security → /ship
```

Each skill feeds into the next. `/nano` writes an artifact that `/review` reads for scope drift detection. `/review` catches conflicts with `/security` findings. `/ship` verifies everything is clean before creating the PR. The phase gate enforces the pipeline: `git commit` is blocked until review, security and qa are done. Nothing falls through the cracks because every step knows what came before it, and skipping steps is not an option.

| Skill | Your specialist | What they do |
|-------|----------------|--------------|
| `/think` | **CEO / Founder** | Three intensity modes: Founder (full pushback), Startup (challenges scope, respects pain) and Builder (minimal pushback). Six forcing questions including manual delivery test and community validation. `--autopilot` runs the full sprint after approval. |
| `/nano` | **Eng Manager** | Auto-generates product specs (Medium scope) or product + technical specs (Large scope) before implementation steps. Product standards for web (shadcn/ui), CLI/TUI (Bubble Tea, Rich, Ink, Ratatui). Stack defaults with CLI preference for beginners. |
| `/review` | **Staff Engineer** | Two-pass code review: structural then adversarial. Auto-fixes mechanical issues, asks about judgment calls. Detects scope drift against the plan. Cross-references `/security` with 10 conflict precedents. |
| `/qa` | **QA Lead** | Functional testing + Visual QA. Takes screenshots and analyzes UI against product standards. Browser, API, CLI and debug modes. WTF heuristic stops before fixes cause regressions. |
| `/security` | **Security Engineer** | Auto-detects your stack, scans secrets, injection, auth, CI/CD, AI/LLM vulnerabilities. Graded report (A-F). Cross-references `/review` for conflict detection. Every finding includes the fix. |
| `/ship` | **Release Engineer** | Pre-flight + repo quality checks. PR creation, CI monitoring, sprint journal. After commit, asks: run locally, deploy to production, or done. Production path guides through hosting, domain, monitoring, costs. |

### Power tools

| Skill | What it does |
|-------|-------------|
| `/compound` | **Knowledge** | Documents solved problems after each sprint. Three types: bug (what broke + fix), pattern (reusable approach), decision (architecture choice). `/nano` and `/review` search past solutions automatically in future sprints. |
| `/guard` | **Safety** | Five-tier safety: allowlist, in-project bypass, phase-aware concurrency (blocks writes during read-only phases), phase gate (blocks commit/push until review+security+qa pass), and pattern matching with 33 block rules. Blocked commands get a safer alternative. `/freeze` locks edits to one directory. Rules in `guard/rules.json`. |
| `/conductor` | **Orchestrator** | Parallel agent sessions with auto-batching. `sprint.sh batch` reads skill concurrency metadata and groups parallel-safe phases. Session resume on crash. Dependency validation before each phase. No daemon, just atomic file ops. |
| `/feature` | **Builder** | Add functionality to an existing project. Skips /think, goes straight to plan, build, review, audit, test, ship. |
| `/nano-run` | **Onboarding** | First-time setup. Configures stack, permissions, and work preferences through a conversation. Auto-detects your project and guides your first sprint. |
| `/nano-help` | **Reference** | Quick reference for all nanostack commands and how to use them. |

### Intensity modes

Not every change needs a full audit. `/review`, `/qa` and `/security` support three modes:

| Mode | Flag | When to use |
|------|------|-------------|
| **Quick** | `--quick` | Typos, config, docs. Only report the obvious. |
| **Standard** | (default) | Normal features and bug fixes. |
| **Thorough** | `--thorough` | Auth, payments, infra. Flag everything suspicious. |

### Specs by scope

`/nano` generates specs automatically based on project complexity:

| Scope | What you get |
|-------|-------------|
| **Small** (1-3 files) | Implementation steps only |
| **Medium** (4-10 files) | Product spec + implementation steps |
| **Large** (10+ files) | Product spec + technical spec + implementation steps |

The product spec covers: problem, solution, user stories, acceptance criteria, user flow, edge cases, out of scope. The technical spec adds: architecture, data model, API contracts, integrations, technical decisions, security considerations, migration/rollback.

Specs are presented for approval before implementation. If the spec is wrong, everything downstream is wrong.

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
You:    /nano
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

## Autopilot

Discuss the idea, approve the brief, walk away. The agent runs the full sprint:

```
/think --autopilot
```

`/think` is interactive: the agent asks questions, you answer, you align on the brief. After you approve, everything else runs automatically:

```
/nano → build → /review → /security → /qa → /ship
```

The phase gate enforces the pipeline. Even if the agent judges a task as "simple" and tries to skip review or security, `git commit` is blocked until all phases have fresh artifacts. No instructions to follow — the hook stops the commit.

Autopilot only stops if:
- `/review` finds blocking issues that need your decision
- `/security` finds critical or high vulnerabilities
- `/qa` tests fail
- A product question comes up the agent can't answer from context

Between steps the agent shows status:
```
Autopilot: build complete. Running /review...
Autopilot: review clean (5 findings, 0 blocking). Running /security...
Autopilot: security grade A. Running /qa...
Autopilot: qa passed (12 tests, 0 failed). Running /ship...
```

## Parallel sprints

Nanostack works well with one agent. It gets interesting with three running at once.

`/conductor` coordinates multiple sessions. Each agent claims a phase, executes it and the next agent picks up the artifact. Review, QA and security run in parallel because they all depend on build, not on each other.

```
/think → /nano → build ─┬─ /review   (Agent A) ─┐
                              ├─ /qa       (Agent B)  ├─ /ship
                              └─ /security (Agent C) ─┘
```

No daemon. No message queue. Just `mkdir` for atomic locking, JSON for state, symlinks for artifact handoff.

`sprint.sh batch` reads each skill's `concurrency` metadata (read, write, exclusive) and outputs execution batches. Review, QA and security are all `read` and share the same dependency, so they batch together automatically.

### Session resume

If the agent crashes mid-sprint, `session.sh resume` detects the last session state and `restore-context.sh` reads all completed phase checkpoints. The agent skips completed phases and restarts from where it left off. Each checkpoint is a compact summary (~50 tokens) with the key findings, files and decisions from that phase.

### Budget and circuit breaker

`budget.sh set --max-usd 15 --model opus-4` sets a cost limit for the sprint. At each phase transition, `budget.sh check` calculates spent vs budget. Warns at 80%, stops at 95% with partial results preserved.

`circuit.sh` tracks consecutive failures. After 3 failures on the same approach, the circuit opens and the agent must pivot or stop. Changing approach resets the counter.

## Guard

AI agents make mistakes. They run `rm -rf` when they mean `rm -r`, force push to main when they mean to push to a branch, pipe untrusted URLs to shell. `/guard` catches these before they execute.

### Five tiers

Inspired by [Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode), guard evaluates every command through five tiers:

**Tier 1: Allowlist.** Commands like `git status`, `ls`, `cat`, `jq` skip all checks. They can't cause damage.

**Tier 2: In-project.** Operations that only touch files inside the current git repo pass through. If the agent writes a bad file, you revert it. Version control is the safety net.

**Tier 2.5: Phase-aware concurrency.** During read-only phases (review, qa, security), write operations are blocked. This prevents race conditions when multiple agents run in parallel. The agent reports findings instead of auto-fixing.

**Tier 2.75: Phase gate.** When a sprint is active, `git commit` and `git push` are blocked until review, security and qa artifacts exist and are fresher than the latest code change. This is the enforcement that prevents the agent from skipping pipeline phases on simple tasks. Bypass with `NANOSTACK_SKIP_GATE=1` for non-sprint commits.

**Tier 3: Pattern matching.** Everything else is checked against block and warn rules. 33 block rules cover mass deletion, history destruction, database drops, production deploys, remote code execution, security degradation and safety bypasses. 9 warn rules cover operations that need attention but not blocking.

### Deny-and-continue

When guard blocks a command, it doesn't just say "no." It suggests a safer alternative:

```
BLOCKED [G-007] Force push overwrites remote history
Category: history-destruction
Command: git push --force origin main

Safer alternative: git push --force-with-lease (safer, fails if remote changed)
```

The agent reads this and retries with the safer command. No manual intervention needed.

### Configurable rules

All rules live in [`guard/rules.json`](guard/rules.json). Each rule has an ID, regex pattern, category, description and (for block rules) a safer alternative. Add your own:

```json
{
  "id": "G-100",
  "pattern": "terraform destroy",
  "category": "infra-destruction",
  "description": "Destroy all Terraform-managed infrastructure",
  "alternative": "terraform plan -destroy first to review what would be removed"
}
```

## Install

### Recommended

```bash
npx create-nanostack
```

Detects your agents, installs all skills, runs setup. Works with Claude Code, Cursor, Codex, Gemini CLI, Amp, Cline, OpenCode, and Antigravity.

Update from your agent:

```
/nano-update
```

### Alternative: git clone (advanced)

Full control including skill rename, analytics, sprint journal and project setup.

```bash
git clone https://github.com/garagon/nanostack.git <path>
cd <path> && ./setup --host auto
```

Targets: `claude`, `codex`, `cursor`, `opencode`, `gemini`, `auto`.

### Alternative: Gemini CLI

```bash
gemini extensions install https://github.com/garagon/nanostack --consent
```

### Rename skills

If you have other skill sets installed (gstack, superpowers, etc.) and names collide, rename the ones that conflict. Requires git clone install.

```bash
cd ~/.claude/skills/nanostack
./setup --rename "review=my-review,security=my-security"
```

Renames persist between updates. Other useful commands:

```bash
./setup --list           # show current skill names
./setup --rename reset   # restore original names
```

### Project setup

Run once in each project to configure permissions and .gitignore. Requires git clone install.

```bash
~/.claude/skills/nanostack/bin/init-project.sh
```

This creates `.claude/settings.json` with permissions so Claude Code doesn't interrupt the workflow asking for approval on every file create or bash command. Also adds `.nanostack/` to `.gitignore`.

### Windows

Requires [Git for Windows](https://git-scm.com/downloads/win) which includes Git Bash. Claude Code uses Git Bash internally, so the setup script and all bin/ scripts work without changes. Alternatively use WSL or `npx skills add`.

### Requirements

Nanostack runs on git. Artifacts are stored relative to the git root. The phase gate uses git history to verify sprint compliance. Scope drift compares planned files against `git diff`. Guard uses the repo boundary for in-project safety. Every project that uses nanostack must be a git repository.

- [Git](https://git-scm.com/)
- [jq](https://jqlang.github.io/jq/) for artifact processing (`brew install jq`, `apt install jq`, or `choco install jq`)
- macOS, Linux or Windows (Git Bash or WSL)
- One of: Claude Code, Cursor, OpenAI Codex, OpenCode, Gemini CLI, Antigravity, Amp, Cline

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

Most AI coding tools are stateless. Every session starts from zero. Nanostack builds knowledge as you work without extra commands.

### Every skill saves automatically

Every skill persists its output to `.nanostack/` after every run. You don't add flags. It just happens.

```
/think     →  .nanostack/think/20260325-140000.json
/nano →  .nanostack/plan/20260325-143000.json
/review    →  .nanostack/review/20260325-150000.json
/qa        →  .nanostack/qa/20260325-151500.json
/security  →  .nanostack/security/20260325-152000.json
/ship      →  .nanostack/ship/20260325-160000.json
```

A review artifact captures everything: findings, scope drift, conflicts resolved.

```json
{
  "phase": "review",
  "mode": "standard",
  "summary": { "blocking": 0, "should_fix": 2, "nitpicks": 1, "positive": 3 },
  "scope_drift": { "status": "drift_detected", "out_of_scope_files": ["src/unplanned.ts"] },
  "conflicts": [
    { "finding_id": "REV-005", "conflicts_with": "SEC-003",
      "tension": "complementary", "resolution": "structured error codes" }
  ]
}
```

Full schema in [`reference/artifact-schema.md`](reference/artifact-schema.md). To disable, set `auto_save: false` in `.nanostack/config.json`.

### Skills read each other

`/review` automatically finds the most recent `/nano` artifact and checks scope drift: did you touch files outside the plan? Did you skip files that were in it?

```
/nano     →  saves planned_files list
/review   →  finds plan, compares against git diff, reports:
              "drift_detected: src/unplanned.ts out of scope, tests/auth.test.ts missing"
```

`/security` automatically finds the most recent `/review` artifact and detects conflicts. `/review` says "add detail to error messages." `/security` says "don't expose internals." The resolution gets matched against [10 built-in precedents](reference/conflict-precedents.md) and recorded.

```
/review   →  saves "REV-003: error messages too vague"
/security →  finds review, detects conflict, resolves:
              "structured errors: code + generic msg to user, details to logs"
```

This happens in all modes. No flags needed. If an artifact exists, the next skill reads it.

### Sprint journal on /ship

When you run `/ship` and the PR lands, it automatically generates a sprint journal:

```
/ship  →  saves PR data
       →  runs bin/sprint-journal.sh
       →  writes .nanostack/know-how/journal/2026-03-25-myproject.md
```

The journal reads every phase artifact from the sprint and writes one file with the full decision trail: what `/think` reframed, what `/nano` scoped, what `/review` found, how conflicts were resolved, what `/security` graded.

### Knowledge compounding on /compound

After shipping, run `/compound` to document what you learned:

```
/compound  →  reads sprint artifacts
           →  identifies problems solved
           →  writes to .nanostack/know-how/solutions/bug/
           →  writes to .nanostack/know-how/solutions/pattern/
           →  writes to .nanostack/know-how/solutions/decision/
```

Next sprint, `/nano` automatically searches past solutions before planning. `/review` checks if current code follows documented resolutions. Solutions that reference files no longer on disk are ranked lower automatically. The knowledge compounds: every sprint makes the next one faster.

Search manually:

```bash
bin/find-solution.sh "stripe webhook"        # by keyword
bin/find-solution.sh --type bug              # by type
bin/find-solution.sh --tag security          # by tag
bin/find-solution.sh --file src/api/webhooks # by file
```

### Analytics and learnings

Two optional scripts for when you want to see patterns across sprints:

```bash
bin/analytics.sh --obsidian    # dashboard with phase counts and security trends
bin/capture-learning.sh "..."  # append a learning to the knowledge base
```

### Discard a bad session

If a sprint went wrong (agent hallucinated findings, aborted halfway, bad data), discard it:

```bash
bin/discard-sprint.sh                     # discard all artifacts from today for this project
bin/discard-sprint.sh --phase review      # discard only review artifacts
bin/discard-sprint.sh --date 2026-03-24   # discard artifacts from a specific date
bin/discard-sprint.sh --dry-run           # show what would be deleted without deleting
```

This removes artifacts and the journal entry. Analytics recalculate on next run.

### The Obsidian vault

Open `.nanostack/know-how/` in Obsidian. Sprint journals link to conflict precedents. The dashboard links to journals. Graph view shows how sprints, conflicts and learnings connect over time.

## Build on nanostack

Nanostack is a platform. Build your own skill set on top of it for any domain.

Register custom phases in `.nanostack/config.json`:

```json
{ "custom_phases": ["audience", "campaign", "measure"] }
```

Your skills use the same infrastructure: `save-artifact.sh` persists artifacts, `find-artifact.sh` reads them, skills cross-reference each other. The sprint journal, analytics and Obsidian vault work with custom phases.

A marketing team builds `/audience` and `/campaign`. A data team builds `/explore` and `/model`. A design team builds `/wireframe` and `/usability`. All compose with nanostack's `/think` for ideation, `/review` for quality and `/ship` for delivery.

Full guide: [`EXTENDING.md`](EXTENDING.md).

## Privacy

All data stays on your machine in `.nanostack/`. No remote calls. No telemetry.

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
Run `/nano-update` from Claude Code, or `~/.claude/skills/nanostack/bin/upgrade.sh` from the terminal.

## Uninstall

```bash
# Claude Code
cd ~/.claude/skills && rm -f think nano review qa security ship guard conductor compound && rm -rf nanostack

# Codex
rm -rf ~/.agents/skills/nanostack*

# Cursor
rm -f .cursor/rules/nanostack.md

# OpenCode
rm -rf ~/.agents/skills/nanostack

# Gemini CLI
gemini extensions remove nanostack
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, project structure and PR guidelines.

- [Bug reports](https://github.com/garagon/nanostack/issues/new?template=bug_report.yml)
- [Feature requests](https://github.com/garagon/nanostack/issues/new?template=feature_request.yml)
- Security vulnerabilities: [SECURITY.md](SECURITY.md)

## License

Apache 2.0
