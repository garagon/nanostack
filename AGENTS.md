# Nanostack: Agent Discovery

This file lists every built-in skill shipped by Nanostack for the verified adapters: Claude Code, Cursor, OpenAI Codex, OpenCode, and Gemini CLI. Each skill folder contains a `SKILL.md` for adapter discovery and an `agents/openai.yaml` for OpenAI-compatible agents. Adapter capability evidence lives in `adapters/<host>.json`; treat the JSON as the single source of truth for what a given host actually enforces (hook execution, write guard, phase gate).

## Available skills

### Default sprint

| Skill | Directory | Description |
|-------|-----------|-------------|
| think | `think/` | Strategic product thinking with calibrated intensity per archetype. Saves a structured artifact (value proposition, scope mode, target user, narrowest wedge, key risk, premise validation). |
| nano  | `plan/` | Implementation planning. Planned files, plan approval, scope assessment, product standards. |
| review | `review/` | Two-pass code review (structural + adversarial). Scope drift detection against /nano. Conflict precedence with /security. |
| qa     | `qa/` | Browser, API, CLI, or debug testing. WTF heuristic. |
| security | `security/` | OWASP Top 10 + STRIDE audit. Cross-references /review for conflicts. |
| ship   | `ship/` | Pre-flight, PR creation, CI monitoring, post-deploy verification. Generates the sprint journal on success. |
| compound | `compound/` | Knowledge capture after /ship. Promotes proven solutions across sprints (bug, pattern, decision) with confidence and applied_count. |

### Orchestration and safety

| Skill | Directory | Description |
|-------|-----------|-------------|
| guard  | `guard/` | Block and warn rules on Bash + Write/Edit. Phase concurrency, sprint phase gate, and budget gate run inside the same pipeline. Rule counts live in `guard/rules.json`. |
| conductor | `conductor/` | Multi-agent sprint orchestrator. Parallel sessions via claim/complete protocol with atomic file locking. |

### Onboarding and entry points

| Skill | Directory | Description |
|-------|-----------|-------------|
| feature   | `feature/` | Fast sprint for an existing project. Skips /think, runs plan through ship. |
| nano-run  | `start/` | First-run onboarding. Reads adapter capabilities, writes a setup artifact, configures permissions and stack preferences through a conversation. |
| nano-help | `help/` | Quick reference for all built-in skills and the default sprint flow. |
| nano-doctor | `doctor/` | Diagnostic. Reports the actual enforcement level for the running adapter and any drift between adapter declarations and the local install. |

## Custom workflow stacks

Custom stacks declare their own phases in `.nanostack/config.json` (`custom_phases` + `phase_graph`) and live under `<store>/skills/<name>/`. They get the same lifecycle support as the built-in sprint (graph-aware progression, concurrency enforcement, artifact trust, schema validation, routing intent through `phase_context`). The contract is in `reference/custom-stack-contract.md`; `examples/custom-stack-template/compliance-release/` is a worked example.

## Know-how pipeline

Skills automatically save artifacts to `.nanostack/`. Downstream skills read upstream artifacts through `bin/resolve.sh`, which honors the artifact-trust contract (PR 2) and the routing contract for custom skills (PR 5). `/ship` generates a sprint journal. `bin/discard-sprint.sh` cleans up bad sessions.

## Usage

Each skill's `SKILL.md` contains the full instructions. Read it and follow the process described. Supporting files (templates, references, checklists, scripts) live in subdirectories and are referenced from the SKILL.md when needed.
