# Nanostack: Agent Discovery

This file lists all available skills for all supported agents (Claude Code, Cursor, Codex, OpenCode, Gemini CLI).
Each skill folder contains a `SKILL.md` for agent discovery and an `agents/openai.yaml` for OpenAI-compatible agents.

## Available Skills

| Skill | Directory | Description |
|-------|-----------|-------------|
| think | `think/` | Strategic product thinking. Three modes (Founder/Startup/Builder) with calibrated intensity. YC-grade forcing questions, CEO cognitive patterns, manual delivery test. |
| nano | `plan/` | Implementation planning. Scope assessment, step-by-step plans with verification, product standards. |
| review | `review/` | Two-pass code review. Structural then adversarial. Scope drift detection against plan. Conflict detection with /security. |
| qa | `qa/` | Quality assurance. Browser, API, CLI and debug testing with Playwright. WTF heuristic. |
| security | `security/` | Security audit. OWASP Top 10, STRIDE, dependency scanning. Cross-references /review for conflicts. Graded report (A-F). |
| ship | `ship/` | Shipping pipeline. PR creation, CI monitoring, post-merge verification. Generates sprint journal on success. |
| guard | `guard/` | Three-tier safety. Allowlist, in-project bypass, 28 block rules with safer alternatives. Configurable in guard/rules.json. |
| conductor | `conductor/` | Multi-agent sprint orchestrator. Parallel sessions via claim/complete protocol with atomic file locking. |

## Know-how Pipeline

Skills automatically save artifacts to `.nanostack/` and cross-reference each other. `/ship` generates a sprint journal. The vault at `.nanostack/know-how/` works as an Obsidian vault. Run `bin/discard-sprint.sh` to clean up bad sessions.

## Usage

Each skill's `SKILL.md` contains the full instructions. Read it and follow the process described.

Supporting files (templates, references, checklists, scripts) are in subdirectories. Read them when referenced by the SKILL.md.
