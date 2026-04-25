# SPEC: Agent-Agnostic Delivery Workflow

## Status

Draft for implementation planning.

## Positioning

Nanostack is an AI coding agent team skills layer for the full engineering workflow.

It turns a single coding agent into a repeatable delivery process: idea challenge, planning, implementation, review, security, QA, shipping, and learning capture.

The product must work for two audiences:

- Technical users who want stricter delivery quality without building their own process.
- Non-technical users who want professional outcomes without needing to understand git, hooks, CI, artifacts, or security jargon.

The product must be agent-agnostic. Claude Code can be the strongest first adapter, but the architecture cannot assume Claude Code semantics are universal.

## Problem

Nanostack was built primarily through Claude Code and Opus, so the current product shape inherits Claude-specific assumptions:

- Hooks are treated as if every agent can enforce them.
- Slash-command skill invocation is treated as universal.
- The docs sometimes say "enforced" when another host only receives instructions.
- Users upgrading from older installs get warnings instead of a safe migration path.
- Non-technical users are still exposed to implementation concepts such as artifacts, JSON, hooks, PRs, CI, and phase names.

This creates a trust gap. The product promises professional delivery, but the actual guarantees vary by host and install path.

## Product Goal

Make Nanostack feel like a professional delivery partner, not a folder of prompts.

The user should experience:

1. "I say what I need."
2. "The agent challenges scope when useful."
3. "The agent builds the smallest correct version."
4. "Review, security, and QA happen automatically or visibly."
5. "The result is delivered with proof."
6. "If something is unsafe or unsupported, Nanostack says so plainly."

The implementation should make guarantees deterministic where possible and honest where not possible.

## Non-Goals

- Do not build a SaaS control plane.
- Do not require users to adopt one specific coding agent.
- Do not hide advanced controls from technical users.
- Do not claim host-level enforcement where the host adapter cannot provide it.
- Do not turn Nanostack into a heavy framework with a daemon requirement.

## Core Principle

Every promise must map to a capability level.

| Level | Name | Meaning | User-facing wording |
|---|---|---|---|
| L0 | Instructions only | Agent is told what to do, but nothing enforces it. | "Guided" |
| L1 | Detectable | Nanostack can inspect state and report issues. | "Checked" |
| L2 | Hooked | Host runs Nanostack before actions. | "Guarded" |
| L3 | Enforced | Nanostack can block unsafe actions deterministically. | "Blocked when unsafe" |
| L4 | CI-asserted | CI or local tests prove the guarantee still holds in this release. | "Continuously verified" |

Marketing, README tables, doctor output, and onboarding must use these terms consistently.

## User Personas

### Non-Technical Builder

Wants an app, landing page, automation, internal tool, or prototype. Does not want to learn git, CI, or security process.

Needs:

- Plain-language flow.
- One obvious next action.
- Visible proof that the result works.
- Safe defaults.
- No manual JSON editing.

Success:

- User says what they want.
- Nanostack builds and shows how to try it.
- Security/QA results are summarized as "safe to try", "needs fix", or "not verified".

### Technical Builder

Already uses agents daily. Wants a stronger process and fewer skipped steps.

Needs:

- Inspectable artifacts.
- CI-friendly scripts.
- Strict guardrails.
- Fast mode for small changes.
- Escape hatches with explicit risk labels.

Success:

- User can wire Nanostack into existing repo workflows.
- Review/security/QA output is actionable.
- CI catches regressions in the process itself.

### Team Lead / Founder

Wants consistent delivery quality from agents or junior builders.

Needs:

- Repeatable workflow.
- Evidence trail.
- Shareable briefs and sprint journals.
- Clear risk language.
- Compatibility matrix across agents.

Success:

- They can say which guarantees exist in each environment.
- They can trust a sprint journal as a delivery record.

## Product Modes

### Guided Mode

Default for non-technical projects and for any host whose adapter cannot enforce hooks.

Guided Mode is about the user's experience and the trust level of the host. It can exist inside a git repo.

Behavior:

- Avoid slash-command lists unless asked.
- Avoid git, PR, branch, diff, artifact, hook, CI language.
- Say what the user has, how to try it, and what remains unverified.
- Use progressive disclosure.

Example close:

> Listo. Ya tenes la version inicial. Para verla, abri `index.html`. Revise que carga, que el boton principal funciona y que no hay secretos expuestos. Queda pendiente publicarla.

### Professional Mode

Default for git projects with technical signals.

Behavior:

- Show phases and evidence.
- Include commands, files, test results, PR status.
- Use review/security/QA terminology.
- Preserve strict gates.

### Autopilot Mode

Runs end to end after initial alignment.

Autopilot must be explicit in session state and inherited by child phases. A phase cannot infer autopilot from prose alone.

### Report-Only Mode

For audits and review without changes.

Behavior:

- No file edits.
- Findings first.
- Each finding has proof and fix direction.

## Architecture

```
User intent
  |
  v
Nanostack Skill Layer
  |-- think
  |-- nano
  |-- build handoff
  |-- review
  |-- security
  |-- qa
  |-- ship
  |-- compound
  |
  v
Workflow Core
  |-- session state
  |-- artifact store
  |-- resolver
  |-- phase gate
  |-- doctor
  |-- telemetry client
  |
  v
Host Adapter Layer
  |-- Claude Code adapter
  |-- Codex adapter
  |-- Cursor adapter
  |-- OpenCode adapter
  |-- Gemini adapter
  |
  v
Host capabilities
  |-- skill discovery
  |-- pre-action hooks
  |-- file write interception
  |-- shell command interception
```

Subagent orchestration and browser QA may become adapter capabilities later, but they are out of the first adapter schema until a script consumes them.

## Host Adapter Contract

Each host adapter must declare capabilities in a machine-readable file.

Proposed file:

```json
{
  "host": "claude",
  "schema_version": "1",
  "last_verified": "2026-04-25",
  "verification": {
    "method": "ci|manual|unknown",
    "evidence": "path or command that proved the claim"
  },
  "skill_discovery": "native",
  "bash_guard": "enforced",
  "write_guard": "enforced",
  "phase_gate": "enforced",
  "install_target": ".claude/settings.json",
  "doctor_checks": ["hooks", "permissions", "commands"]
}
```

Capability values:

- `unsupported`
- `instructions_only`
- `detectable`
- `hooked`
- `enforced`
- `host_dependent`

Nanostack must never print "enforced" for a host whose adapter reports `instructions_only`.

Adapter files are declarations, not eternal truth. They must include `last_verified`, and CI should validate any host capability that can be checked locally. If install-time observation contradicts the file, doctor/setup must report the observed lower capability instead of repeating the stale declaration.

## Current Capability Target

| Host | Skill discovery | Bash guard | Write/Edit guard | Phase gate | Product wording |
|---|---:|---:|---:|---:|---|
| Claude Code | Native | Enforced | Enforced | Enforced | Full guard support |
| Codex | Native skill files | Unknown / adapter needed | Unknown / adapter needed | Instruction-only unless adapter exists | Guided workflow |
| Cursor | Rules file | Instruction-only | Instruction-only | Instruction-only | Guided workflow |
| OpenCode | Skill folder | Unknown / adapter needed | Unknown / adapter needed | Instruction-only unless adapter exists | Guided workflow |
| Gemini CLI | Extension | Unknown / adapter needed | Unknown / adapter needed | Instruction-only unless adapter exists | Guided workflow |

This table is a product requirement, not a permanent limitation. The next release should replace "unknown" with verified adapter behavior.

## Delivery Guarantees

### Guaranteed Only When Host Supports Hooks

- Blocking destructive shell commands.
- Blocking unsafe Write/Edit destinations.
- Blocking commits before review/security/QA.
- Budget gate hard stop.
- Read-only phase write blocking.

### Always Available

- Skill instructions.
- Artifact saving.
- Resolver context.
- Review/security/QA reports.
- Sprint journal.
- Doctor diagnostics.
- Local scripts run manually by user or agent.

### Must Be Reworded

Current wording like "Every step is enforced" should become:

> Nanostack enforces the workflow when your agent supports hooks. Otherwise it guides the workflow and tells you which protections are advisory.

## Installation Flow

### Fresh Install

1. Detect host.
2. Install skills.
3. Install host adapter if available.
4. Run `nano-doctor --json`.
5. Show one result:
   - Full protection enabled.
   - Guided mode enabled, protection advisory.
   - Install incomplete, fix required.

For non-technical users, do not print a long command list by default.

### Project Init

`init-project.sh` should be idempotent and safe for both fresh and existing settings.

Required behavior:

- Create `.nanostack/`.
- Create `.claude/settings.json` when missing.
- Merge hooks into existing `.claude/settings.json` with a backup.
- Narrow broad permissions when user passes `--migrate-permissions`.
- Print plain-language outcome.

Proposed flags:

```bash
bin/init-project.sh --check
bin/init-project.sh --migrate-hooks
bin/init-project.sh --migrate-permissions
bin/init-project.sh --repair
```

`--repair` should:

- Back up current settings.
- Add missing hooks.
- Add narrow rm rules.
- Leave broad entries untouched unless `--migrate-permissions` is present.
- Re-run doctor.

### Upgrade

`upgrade.sh` should not stop at pulling files.

Required post-upgrade flow:

1. Pull/update Nanostack.
2. Re-run setup for installed hosts.
3. Check only the current project unless the user explicitly opted into a project registry.
4. Tell user:
   - "Nanostack updated."
   - "Your current project still needs hook migration."
   - "Run: `bin/init-project.sh --repair`."

For non-technical flows, `/nano-doctor` should offer to run repair rather than asking the user to edit JSON.

Privacy constraint: Nanostack should not maintain a central list of user projects by default. A project registry such as `~/.nanostack/projects.json` is allowed only with explicit opt-in during project init.

## Safety Model

### Bash Guard

Block rules run before allowlist.

Required coverage:

- Mass deletion.
- Git history destruction.
- Curl-to-shell.
- Secret file reads.
- Secret disclosure via grep/rg/jq/env/printenv.
- Production deploys.
- Safety bypass flags.

### Write/Edit Guard

The guard must evaluate both:

- Original path exactly as received.
- Resolved path after following symlinks.

Rules:

- Block protected basenames.
- Block protected absolute prefixes.
- Block resolved paths under protected prefixes.
- Optionally block writes outside project unless an explicit host/user mode allows it.

Recommended default:

- In Guided Mode: project-only writes plus `/tmp`, behind a configurable guard setting. This should ship with clear messaging and real-world validation because legitimate CLIs may need to write under `~/.config`.
- In Professional Mode: project-only writes plus configured extra paths.
- Global writes require explicit user approval.

### Secret Read Policy

Secret protection is not "cat-specific". The policy is:

> Any command that can print secret-bearing files or environment variables must be blocked or require explicit confirmation.

This covers:

- `cat .env`
- `head .env`
- `tail secrets.pem`
- `grep TOKEN .env`
- `rg TOKEN .env`
- `jq . .env`
- `env`
- `printenv`

Possible exception:

- Allow `env | grep SAFE_PREFIX` only when configured.

## Workflow State Model

Session state is the source of sprint progress.

Required fields:

```json
{
  "session_id": "project-yyyymmdd-hhmmss",
  "host": "claude",
  "profile": "guided|professional",
  "run_mode": "normal|report_only",
  "autopilot": false,
  "plan_approval": "manual|auto|not_required",
  "capabilities": {
    "bash_guard": "enforced",
    "write_guard": "enforced",
    "phase_gate": "enforced"
  },
  "current_phase": "review",
  "completed_phases": ["think", "plan", "build"],
  "pending_phases": ["review", "security", "qa", "ship"],
  "evidence": {
    "tests": [],
    "security": [],
    "qa": []
  }
}
```

The user-facing UI should be derived from this state, not from hard-coded next-step prose in each skill.

## Product Flow

### New Non-Technical Project

1. User runs install.
2. User says what they want.
3. Nanostack asks at most one clarifying question at a time.
4. Nanostack summarizes:
   - What will be built.
   - What will not be built yet.
   - How the user will try it.
5. Nanostack builds.
6. Nanostack verifies.
7. Nanostack shows:
   - Result.
   - How to open it.
   - What was checked.
   - What remains optional.

No PR/CI/git language unless the user asks or the project has a remote.

### Existing Technical Project

1. User runs `/feature`.
2. Nanostack loads recent artifacts and code context.
3. Nanostack creates an implementation plan.
4. `/feature` is always autopilot. The plan is auto-approved and recorded as such.
5. Build happens.
6. Review/security/QA run.
7. Ship creates PR after preview and approval.

Manual feature work should use `/think` + `/nano`, not `/feature --manual`. Two paths, two contracts.

### Audit-Only Flow

1. User asks for audit.
2. Nanostack enters report-only mode.
3. No files are edited.
4. Findings include:
   - Product risk.
   - Architecture risk.
   - Security risk.
   - User-flow risk.
5. A spec or implementation plan can be generated after the audit.

## UX Requirements

### Language Levels

Every major output should support two layers.

Plain:

> Esto esta listo para probar. El formulario guarda datos y muestra errores claros si falta algo.

Technical:

> QA passed 12/12. Security grade A. No staged secrets. PR #42 ready.

### Doctor Output

Doctor should produce three outputs:

- Human technical.
- Human plain.
- Machine JSON.

Machine JSON must be built with `jq`, not delimiter parsing.

Required schema:

```json
{
  "overall": "pass|warn|fail",
  "checks": [
    {
      "status": "pass|warn|fail",
      "category": "permissions",
      "name": "write_guard",
      "detail": "check-write.sh wired",
      "fix_available": true,
      "fix_command": "bin/init-project.sh --repair"
    }
  ]
}
```

### Setup Output

The setup script should end with:

```text
Nanostack is installed.

Protection level:
  Claude Code: full guard support
  Cursor: guided workflow only

Next:
  1. Restart Cursor
  2. In your project, run /nano-run
```

Do not print every skill unless user passes `--verbose`.

## Technical Decisions

| Decision | Choice | Why |
|---|---|---|
| Host abstraction | Adapter capability files | Avoid Claude-specific assumptions |
| Enforcement wording | Capability-level language | Prevent overpromising |
| Existing installs | Repair command with backup | Non-technical users should not edit JSON |
| Write guard | Resolve symlinks and project scope | Denylist on raw path is bypassable |
| Doctor JSON | Build with jq arrays | Avoid delimiter truncation |
| Feature fast path | Explicit auto-approved plan state | Avoid contradiction with `/nano` approval |
| Local mode vs Guided Mode | Local mode always implies Guided Mode; Guided Mode can also apply in git repos | Avoid conflating "no git" with "non-technical user" |
| CI | Matrix over scripts and product contracts | Catch workflow regressions |

## Implementation Plan

### Phase 1: Truthful Guarantees

Files:

- `README.md`
- `README.es.md`
- `SECURITY.md`
- `guard/SKILL.md`
- `setup`

Changes:

- Add capability levels.
- Replace universal "enforced" claims.
- Add host capability matrix.
- Mark non-hook hosts as guided until adapters prove enforcement.

Verification:

- Grep docs for "Every step is enforced" and confirm qualified wording.
- Ensure README and Spanish README do not diverge on guarantees.

### Phase 2: Host Adapter Model

Files:

- `reference/host-adapter-schema.md`
- `adapters/claude.json`
- `adapters/codex.json`
- `adapters/cursor.json`
- `adapters/opencode.json`
- `adapters/gemini.json`
- `setup`
- `bin/nano-doctor.sh`

Changes:

- Add adapter capability schema.
- Setup writes detected host capability summary.
- Doctor reports protection level per host.
- Keep the first schema minimal: skill discovery, Bash guard, Write/Edit guard, phase gate, install target, doctor checks, last verified, verification evidence.
- Defer subagents, browser QA, and other non-consumed capabilities until there is code that reads them.

Verification:

- `setup --host claude --dry-run` shows full guard support.
- `setup --host cursor --dry-run` shows guided workflow unless real hooks exist.
- Adapter declarations include `last_verified`.
- CI validates any declared local capability it can observe.

### Phase 3: Repair Existing Installs

Files:

- `bin/init-project.sh`
- `bin/upgrade.sh`
- `bin/nano-doctor.sh`
- `TROUBLESHOOTING.md`

Changes:

- Add `--check`, `--repair`, `--migrate-hooks`, `--migrate-permissions`.
- Back up settings before mutation.
- Add missing hooks to existing settings.
- Doctor suggests repair command with fix metadata.

Verification:

- Existing settings without hooks are repaired.
- Existing broad rm remains unless migration flag is present.
- Backup file is created.
- Doctor moves from warn to pass after repair.

### Phase 4: Harden Guard

Files:

- `guard/bin/check-write.sh`
- `guard/bin/check-dangerous.sh`
- `guard/rules.json`
- `.github/workflows/lint.yml`
- `tests/run.sh`

Changes:

- Resolve symlinks in Write/Edit guard.
- Add configurable outside-project write blocking. Default ON for Guided Mode only after validating common CLI flows; default OFF for Professional Mode.
- Add secret disclosure rules for grep/rg/jq/env/printenv.
- Add regression tests for symlink bypass and secret disclosure variants.

Verification:

- `check-write.sh /tmp/link-to-etc/passwd` exits 1.
- `check-write.sh /tmp/link-to-ssh/config` exits 1.
- `check-dangerous.sh 'grep SECRET .env'` exits 1.
- `check-dangerous.sh 'env'` exits 1 or warns based on configured mode.

### Phase 5: Workflow Orchestration State

Files:

- `bin/session.sh`
- `bin/next-step.sh`
- `feature/SKILL.md`
- `plan/SKILL.md`
- `ship/SKILL.md`

Changes:

- Store mode and host capability in session.
- Store explicit `plan_approval: user|auto|not_required`.
- `/feature` always sets auto-approved planning. Manual users should use `/think` + `/nano`.
- Next-step guidance is generated from session state.

Verification:

- `/feature` no longer conflicts with `/nano` approval.
- Manual `/nano` still waits for approval.
- Autopilot status survives across phases.

### Phase 6: Non-Technical Delivery Experience

Files:

- `start/SKILL.md`
- `think/SKILL.md`
- `plan/SKILL.md`
- `qa/SKILL.md`
- `ship/SKILL.md`
- `doctor/SKILL.md`
- `README.es.md`

Changes:

- Add a shared "plain language output contract".
- Replace phase-heavy next steps with one-action guidance in Guided Mode.
- Add "what was checked" and "what is not verified" blocks.
- Ensure Spanish docs are first-class, not partial.

Verification:

- In a no-git project, no output mentions PR, CI, branch, diff, hook, artifact, or phase unless user asks.
- Ship output tells user exactly how to try the result.

## Acceptance Criteria

| Area | Criteria | How to verify |
|---|---|---|
| Agent agnosticism | Every supported host has declared capability levels | Adapter files + doctor output |
| Honest positioning | Docs do not claim enforcement where host lacks hooks | Grep docs + capability matrix |
| Existing installs | User can repair hooks without editing JSON | Temp settings test |
| Write safety | Symlink targets to protected dirs are blocked | Regression test |
| Secret safety | Secret-bearing files cannot be printed through common read commands | Guard matrix |
| Non-technical flow | No-git project gets plain next action and proof | Local-mode transcript test |
| Feature flow | `/feature` does not wait on `/nano` approval accidentally | Session test |
| Doctor JSON | No truncation when details include pipes/newlines | JSON schema test |
| CI coverage | Workflow runs guard, write guard, doctor JSON, install repair, frozen install, audit, typecheck | GitHub Actions |

## Metrics

Product metrics should be local-first and optional.

Useful aggregate metrics:

- Time from idea to first runnable output.
- Percent of sprints with review/security/QA artifacts.
- Percent of sprints stopped by guard.
- Percent of installs with full guard support.
- Percent of doctor runs that report repairable warnings.
- Autopilot completion rate.
- Non-technical flow completion rate.

Never collect:

- Code.
- Prompts.
- File paths.
- Repo names.
- Hostnames.
- Secrets.

## Release Plan

### v0.8: Honest Capabilities

Ship as four small PRs:

1. Adapter schema and capability JSON files only.
2. CI/schema validation for adapter files.
3. README/SECURITY/setup wording that consumes the capability vocabulary.
4. Doctor/setup protection-level output.

### v0.9: Repair and Guard Hardening

- `init-project.sh --repair`.
- Symlink-safe Write/Edit guard.
- Secret disclosure guard variants.
- CI matrix expanded.

### v1.0: Delivery Experience

- Guided Mode polished.
- Feature autopilot contract fixed.
- Session state owns next-step guidance.
- Spanish docs complete.
- Public positioning updated to: "AI coding agent team skills for the full engineering workflow, with enforced guardrails where your agent supports hooks and guided delivery everywhere else."

Implementation contract: see `reference/v1-delivery-experience-technical-spec.md`.

## Closed v1.0 Decisions

| Topic | Decision |
|---|---|
| Write/Edit outside project | Professional mode warns and is configurable. Guided/local blocks or requires explicit confirmation. |
| `env` and `printenv` | Guided blocks. Professional warns and is configurable. Silent allow is forbidden. |
| Local mode vs Guided Mode | Local mode implies Guided Mode. Guided Mode can also exist inside a git repo. |
| `/feature` | Always autopilot. Manual feature work uses `/think` + `/nano`. |
| Session state | `session.json` owns profile, capabilities, plan approval, and next-step guidance. |

## Recommended Next Sprint

Build v1.0 Sprint 1 first: docs-only decision landing.

Scope:

- Land `reference/v1-delivery-experience-technical-spec.md`.
- Keep runtime code unchanged.
- Confirm v1.0 decisions are explicit before implementing `session.sh` schema v2.

Why:

- It avoids mixing product policy with script changes.
- It gives implementation agents exact fields, files, commands, and tests.
- It prevents Sprint 4/5 language work from starting before Sprint 2 creates the session-state backbone.
