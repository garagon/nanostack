# v1.0 Technical Spec: Delivery Experience

## Status

Accepted for v1.0 implementation planning.

This spec turns the v1.0 product decision into implementation work. It is written for agents implementing Nanostack, not for end users.

## Product Objective

Nanostack v1.0 should feel like a professional delivery team wrapped around any AI coding agent.

The core promise:

> Nanostack does not only protect the workflow. It guides delivery like a professional engineering team, understandable for technical and non-technical users.

The product must keep the v0.8 honesty contract:

- Enforced guardrails only where the host adapter can actually block actions.
- Guided delivery everywhere else.
- No user-facing claim may imply deterministic enforcement when the adapter reports `instructions_only`.

## Closed Decisions

These decisions are no longer open questions.

| Topic | v1.0 decision | Rationale |
|---|---|---|
| Write/Edit outside project | Professional: configurable warning. Guided/local: block or explicit confirmation. | Technical users need controlled escape hatches. Non-technical users need safe defaults. |
| `env` / `printenv` | Guided blocks. Professional warns/configurable. Never silent allow. | Environment dumps often leak secrets into transcripts. |
| Local mode vs Guided Mode | Local mode implies Guided. Guided can also exist inside a git repo. | "No git" and "non-technical user" are correlated, not identical. |
| `/feature` | Always autopilot. Manual feature work uses `/think` + `/nano`. | Two paths, two contracts. Avoid `/feature --manual` ambiguity. |
| Session state | Session owns profile, capabilities, plan approval, and next action. | Skill prose must not become the source of workflow truth. |

## Terminology

Avoid overloading the word `mode`.

| Term | Values | Meaning |
|---|---|---|
| `profile` | `guided`, `professional` | How user-facing output is shaped and how conservative defaults are. |
| `run_mode` | `normal`, `report_only` | Whether the sprint may edit files. |
| `autopilot` | boolean | Whether phases continue without approval pauses. |
| `plan_approval` | `manual`, `auto`, `not_required` | Whether `/nano` must wait before build. |
| `capabilities` | adapter capability map | What the current host can actually enforce. |

Do not represent `autopilot` as a profile. A user can be in `professional` profile with `autopilot=true`.

## Session Schema v2

`bin/session.sh` is the canonical writer of session state. Existing v1 fields must remain readable.

### Required Shape

```json
{
  "schema_version": "2",
  "session_id": "project-20260425-150000",
  "type": "development",
  "workspace": "/abs/path/to/project",
  "repo": "owner/name",
  "host": "claude",
  "profile": "guided",
  "run_mode": "normal",
  "autopilot": false,
  "plan_approval": "manual",
  "capabilities": {
    "skill_discovery": "native",
    "bash_guard": "enforced",
    "write_guard": "enforced",
    "phase_gate": "enforced",
    "verification_method": "ci",
    "last_verified": "2026-04-25"
  },
  "policy": {
    "outside_project_write": "block",
    "env_read": "block",
    "plain_language": true
  },
  "current_phase": null,
  "next_phase": null,
  "phase_log": [],
  "stop_conditions_met": [],
  "evidence": {
    "review": null,
    "security": null,
    "qa": null,
    "ship": null
  },
  "budget": {
    "max_usd": null,
    "spent_usd": 0,
    "tokens_input": 0,
    "tokens_output": 0
  },
  "started_at": "2026-04-25T15:00:00Z",
  "last_updated": "2026-04-25T15:00:00Z"
}
```

### Compatibility Defaults

When reading an older session without v2 fields:

| Missing field | Default |
|---|---|
| `schema_version` | `"1"` for reporting, but readers treat missing values via this table. |
| `host` | Detect from adapter/setup when possible, else `"unknown"`. |
| `profile` | `guided` if local/no-git or host capabilities are `instructions_only`; else `professional`. |
| `run_mode` | `normal`. |
| `autopilot` | Existing `.autopilot // false`. |
| `plan_approval` | `auto` if `.autopilot == true`, else `manual`. |
| `capabilities` | Read from `adapters/<host>.json`; if unknown, use `instructions_only`. |
| `policy.outside_project_write` | `block` for guided, `warn` for professional. |
| `policy.env_read` | `block` for guided, `warn` for professional. |
| `policy.plain_language` | `true` for guided, `false` for professional. |
| `evidence` | Reconstruct from fresh artifacts when possible, else nulls. |

No reader should fail on v1 sessions.

## Profile Selection

Profile is selected during session init and may be overridden by config.

### Inputs

1. Explicit CLI flag:
   - `session.sh init development --profile guided`
   - `session.sh init development --profile professional`
2. Project config:
   - `.nanostack/config.json.preferences.profile`
3. Git context:
   - no git repo -> guided
4. Host capability:
   - adapter with no enforcement -> guided unless config explicitly says professional
5. Existing technical signals:
   - repo with remote, package manager, CI files, or previous Nanostack artifacts -> professional candidate

### Resolution Order

Explicit flag wins, then project config, then detection.

Detection rule:

```text
if no git repo:
  profile = guided
else if host bash_guard/write_guard/phase_gate are all instructions_only:
  profile = guided
else:
  profile = professional
```

This rule is intentionally conservative. A technical user can opt into professional.

## Policy Matrix

| Profile | Outside project writes | `env` / `printenv` | User wording |
|---|---|---|---|
| Guided | block or explicit confirmation | block | "I stopped this because it could expose private data or write outside this project." |
| Professional | warn/configurable | warn/configurable | "Risk: this may expose environment variables. Continue only if intentional." |

For v1.0, "configurable" means policy values in session/config, not new host-level enforcement for agents that cannot hook tool calls.

Recommended config shape:

```json
{
  "preferences": {
    "profile": "guided",
    "policies": {
      "outside_project_write": "block",
      "env_read": "block"
    }
  }
}
```

Allowed policy values:

- `allow`
- `warn`
- `confirm`
- `block`

Guided defaults must never be `allow`.

## Script Contracts

### `bin/session.sh`

Required changes:

- Add `--profile guided|professional`.
- Add `--run-mode normal|report_only`.
- Add `--plan-approval manual|auto|not_required`.
- Keep `--autopilot` as a boolean flag for compatibility.
- Resolve host capabilities at init time.
- Write `schema_version: "2"`.
- Include v2 fields in `status` and `resume` output.

`--autopilot` implies:

```json
{
  "autopilot": true,
  "plan_approval": "auto"
}
```

`--run-mode report_only` implies:

```json
{
  "run_mode": "report_only",
  "plan_approval": "not_required"
}
```

Acceptance checks:

```bash
bin/session.sh init development --profile guided
jq -e '.schema_version == "2" and .profile == "guided"' .nanostack/session.json

bin/session.sh init feature --autopilot
jq -e '.autopilot == true and .plan_approval == "auto"' .nanostack/session.json
```

### `bin/next-step.sh`

Current behavior is artifact-based and post-build-specific. v1.0 behavior must derive the next action from session state first, artifacts second.

New usage:

```bash
bin/next-step.sh [--json] [current-phase]
```

Human output:

- Guided profile: one plain next action.
- Professional profile: phase list with evidence.

JSON output:

```json
{
  "profile": "guided",
  "next_phase": "review",
  "pending_phases": ["review", "security", "qa"],
  "required_before_ship": ["review", "security", "qa"],
  "user_message": "Ahora reviso que lo construido funcione y no tenga riesgos obvios.",
  "can_ship": false
}
```

Resolution algorithm:

1. Read `session.json` if present.
2. If session is missing, fall back to current artifact-based behavior.
3. Compute completed phases from `phase_log`.
4. For post-build, `review`, `security`, and `qa` are peers.
5. `ship` is available only when all required phases have completed fresh artifacts.
6. Profile controls wording, not the underlying phase requirements.

Do not encode next-step prose separately in each skill once this script exists.

### `feature/SKILL.md`

Required changes:

- Keep `/feature` always autopilot.
- Initialize session with:

```bash
bin/session.sh init feature --autopilot --plan-approval auto
```

- State that manual users should use `/think` + `/nano`.
- Do not introduce `/feature --manual`.

Acceptance checks:

- `/feature` never waits for `/nano` approval.
- A plan artifact still records that the plan was auto-approved.

### `plan/SKILL.md`

Required changes:

- Replace prose-only AUTOPILOT detection with session-first detection.
- Read:

```bash
jq -r '.plan_approval // (if .autopilot then "auto" else "manual" end)' .nanostack/session.json
```

- If `plan_approval == "auto"`, present a short plan and continue.
- If `plan_approval == "manual"`, wait for approval.
- If `plan_approval == "not_required"`, do not present an approval gate.
- Include `plan_approval` in the saved plan artifact summary.

Acceptance checks:

- Manual `/nano` still waits.
- `/feature` driven `/nano` does not wait.
- Plan artifact includes `plan_approval`.

### `review/SKILL.md`, `security/SKILL.md`, `qa/SKILL.md`

Required changes:

- Read `profile`, `run_mode`, and `autopilot` from session.
- In Guided profile, final output must include:
  - what was checked
  - whether it is safe to try
  - one next action
  - what remains unverified
- In Professional profile, preserve findings/evidence style.
- In `run_mode == report_only`, do not edit files.
- Replace hardcoded next-step text with `bin/next-step.sh --json`.

Acceptance checks:

- Guided output does not mention PR, CI, branch, diff, hook, artifact, or phase unless user asked.
- Professional output still includes exact findings and verification.

### `ship/SKILL.md`

Required changes:

- Read `profile` and git context.
- Guided/no-git output focuses on how to try the result.
- Professional/git output preserves PR/CI flow.
- Always include proof block:
  - reviewed: yes/no
  - security checked: yes/no
  - QA checked: yes/no
  - not verified: list

Guided close example:

```text
Listo para probar.

Como verlo:
1. Abri index.html en el navegador.

Que revise:
- La pantalla carga.
- El boton principal responde.
- No encontre secretos en archivos visibles.

Pendiente:
- No esta publicado en internet todavia.
```

Professional close example:

```text
Ready to ship.

Evidence:
- Review: pass, 0 blocking
- Security: grade A, no high/critical
- QA: 12/12 checks passed
- PR: #42
```

### `doctor/SKILL.md` and `bin/nano-doctor.sh`

Required changes:

- Doctor must report:
  - host capability
  - observed install state
  - session profile when run inside a project
  - recommended repair command, if any
- JSON output must expose `fix_available` and `fix_command`.
- Plain output must avoid "hooks/settings JSON" as the first-level explanation in Guided profile.

Guided wording:

```text
Nanostack can guide this project, but automatic blocking is not fully active.
I can repair the local setup with a backup.
```

Professional wording:

```text
write_guard: warn
Reason: check-write.sh hook missing from .claude/settings.json
Fix: bin/nano-doctor.sh --fix
```

## Plain Language Contract

Create:

```text
reference/plain-language-contract.md
```

It must define banned or translated terms for Guided profile.

| Internal term | Guided replacement |
|---|---|
| artifact | saved note, record, or omit |
| PR | publish request only if user has GitHub context, else omit |
| CI | automatic checks |
| branch | version |
| diff | changes |
| hook | safety check |
| phase | step |
| security audit | safety check |
| QA | test pass |
| scope drift | extra changes |

Hard rule:

Guided output may keep rigor, but must remove process jargon from the first screen.

## Test Plan

### Unit / Script Tests

Add or extend script tests for:

- `session.sh init development --profile guided`
- `session.sh init development --profile professional`
- `session.sh init feature --autopilot`
- migration/read compatibility for old session JSON
- `next-step.sh --json` with:
  - empty session
  - plan completed, build not completed
  - build completed, review/security/qa pending
  - review/security/qa completed, ship pending

### Transcript Tests

Create lightweight fixtures under `tests/transcripts/` or equivalent.

Minimum cases:

1. Guided no-git sprint.
   - Must not contain: `PR`, `CI`, `branch`, `diff`, `hook`, `artifact`, `phase`.
   - Must contain: how to try, what was checked, what remains.
2. Professional git sprint.
   - Must contain: files, commands, test results, PR/CI when applicable.
3. Feature autopilot.
   - Must not contain approval pause after plan.

These can start as grep-based contract tests before building a full transcript harness.

### CI Jobs

Add jobs or extend lint job for:

- session schema v2
- next-step state matrix
- plain-language contract grep
- `/feature` autopilot contract grep

## Sprint Breakdown

### Sprint 1: Docs Only

Goal: land this spec and close v1.0 decisions.

Files:

- `reference/agent-agnostic-delivery-spec.md`
- `reference/v1-delivery-experience-technical-spec.md`

Acceptance:

- No open questions remain for Write/Edit outside project, `env`/`printenv`, local vs Guided, or `/feature`.
- The next sprint has exact files, fields, commands, and tests.
- No runtime code changes.

### Sprint 2: Workflow Backbone

Goal: make session state the workflow source of truth.

Files:

- `bin/session.sh`
- `bin/next-step.sh`
- `feature/SKILL.md`
- `plan/SKILL.md`
- tests/CI

Acceptance:

- v2 session is written.
- old sessions still read.
- `/feature` auto-approves plan through session state.
- `next-step.sh --json` returns deterministic next action.

### Sprint 3: Skills Consume Session State

Goal: review/security/qa/ship stop guessing profile and next action.

Files:

- `review/SKILL.md`
- `security/SKILL.md`
- `qa/SKILL.md`
- `ship/SKILL.md`
- `doctor/SKILL.md`

Acceptance:

- skills read `profile`, `run_mode`, `autopilot`.
- report-only prevents edits.
- next-step guidance comes from `bin/next-step.sh`.

### Sprint 4: Plain Language Delivery

Goal: non-technical users get professional output without internal jargon.

Files:

- `reference/plain-language-contract.md`
- `think/SKILL.md`
- `plan/SKILL.md`
- `qa/SKILL.md`
- `ship/SKILL.md`
- `doctor/SKILL.md`

Acceptance:

- Guided transcript passes banned-term grep.
- Output includes result, how to try, what was checked, what remains.
- Professional output keeps technical evidence.

### Sprint 5: Spanish First-Class Surface

Goal: Spanish users receive equal quality, not a partial translation.

Files:

- `README.es.md`
- `TROUBLESHOOTING.md` or Spanish troubleshooting section
- any user-facing setup/doctor copy that has Spanish variant support

Acceptance:

- Every major public README section has Spanish coverage or clearly points to canonical English for advanced material.
- Capability matrix and Guided/Professional explanation match English.

### Sprint 6: v1.0 Release

Goal: release the new positioning and verify end-to-end delivery experience.

Files:

- `VERSION`
- `README.md`
- `README.es.md`
- release notes

Acceptance:

- v1.0 headline reflects delivery experience, not only guard hardening.
- CI green.
- Release notes explain:
  - Guided vs Professional
  - host capability honesty
  - session-state workflow
  - non-technical delivery output

## Risks

| Risk | Mitigation |
|---|---|
| Old sessions break readers | compatibility defaults and tests with v1 fixture |
| Skills diverge in wording | shared plain-language contract |
| `mode` ambiguity | use `profile`, `run_mode`, `autopilot`, `plan_approval` separately |
| Guided overblocks legitimate CLI writes | policy configurable; Professional defaults to warn |
| Non-hook hosts appear safer than they are | adapter capability remains source of truth |
| Sprint 4 starts before session backbone | hard order: Sprint 2 before Sprints 3-5 |

## Definition of Done for v1.0

v1.0 is done when a fresh user can run Nanostack in two scenarios:

1. Non-technical/local project:
   - Receives plain next actions.
   - Sees how to try the result.
   - Gets understandable proof.
   - Is protected from obvious secret/env/project-boundary mistakes where the host can enforce or confirm.

2. Technical/git project:
   - Gets explicit phases, files, findings, tests, PR/CI evidence.
   - Can inspect artifacts and session state.
   - Can configure warnings vs blocks.

Both scenarios must preserve the v0.8 honesty rule: no false enforcement claims.
