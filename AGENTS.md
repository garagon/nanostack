# Nanostack — Agent Discovery

This file lists all available skills for non-Claude Code agents (Codex, Kiro, etc.).
Each skill folder contains an `agents/openai.yaml` for OpenAI-compatible agent discovery.

## Available Skills

| Skill | Directory | Description |
|-------|-----------|-------------|
| think | `think/` | Strategic product thinking — YC-grade forcing questions, CEO cognitive patterns, premise validation |
| plan | `plan/` | Implementation planning — scope assessment, step-by-step execution plans with verification |
| review | `review/` | Two-pass code review — structural correctness then adversarial edge-case hunting |
| qa | `qa/` | Quality assurance — browser-based testing with Playwright, root-cause debugging |
| security | `security/` | Security audit — OWASP Top 10, STRIDE threat modeling, dependency scanning |
| ship | `ship/` | Shipping pipeline — PR creation, CI monitoring, post-merge verification |
| guard | `guard/` | Safety guardrails — on-demand protection against destructive operations |
| conductor | `conductor/` | Multi-agent sprint orchestrator — coordinate parallel sessions via claim/complete protocol |

## Usage

Each skill's `SKILL.md` contains the full instructions. Read it and follow the process described.

Supporting files (templates, references, checklists, scripts) are in subdirectories — read them when referenced by the SKILL.md.
