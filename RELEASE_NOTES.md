# Nanostack Release Notes

The detailed "what changed" surface for Nanostack. The [README](README.md)
stays the stable, user-facing overview; this file records what each release
adds and why it matters. Newest first.

## 2026-05-29 (changes since v1.0.0)

### What changed

- **Custom workflow stacks.** Build a domain-specific workflow on top of
  Nanostack, not just a one-off skill. `bin/create-skill.sh` scaffolds a
  skill, `.nanostack/config.json` registers it (`custom_phases`,
  `phase_graph`), and `bin/check-custom-skill.sh` validates it. The
  `compliance-release` example shows three skills composing into one release
  gate before `/ship`.
- **Visual artifacts.** `bin/render-artifact.sh` turns the JSON a phase
  saved into a local HTML view: plans, reviews, security and QA output,
  sprint journals, and workflow-stack graphs. The HTML is offline (its own
  CSS, no network), `--strict` refuses unverifiable evidence, and
  `--interactive` adds copy-only buttons on `/plan` and `/review`. The JSON
  stays canonical; the HTML is a layer you can delete and regenerate.
- **Stronger safety contracts.** Read-only phases now block mutations
  through Write/Edit/MultiEdit, not just Bash, so `/review`, `/security`, and
  `/qa` are safe to run as one parallel batch. Release gates require
  trusted artifacts (integrity-checked, filename-dated), and README
  enforcement levels are locked to the adapter JSON and CI evidence.
- **Cleaner contributor harness.** The CI test suites share one core
  library and fixtures, an inventory (`ci/harnesses.json`) that fails when it
  drifts from the real scripts, and a single local runner. The big visual
  suite is split into reviewable sections.

### What this means in practice

- Easier to inspect what the agent actually did, in a browser.
- Easier to extend Nanostack into a real, domain-specific workflow.
- Safer parallel review/security/QA phases.
- More reliable release gates that fail closed on tampered evidence.
- Easier contributor debugging when CI fails, via one runner.

### Honest scope

Hard enforcement is host-dependent. Claude Code has the strongest
continuous hook coverage; the other verified adapters (Cursor, OpenAI
Codex, OpenCode, Gemini CLI) run the same workflow as guided instructions
unless their `adapters/<host>.json` proves otherwise. Nanostack has no
cloud or backend; everything is local under `.nanostack/`. The heavier
runtime end-to-end suites run in the opt-in E2E workflow
(`workflow_dispatch`), not on every PR; lighter contract checks, including
the visual-artifact contract, do run on every PR.
