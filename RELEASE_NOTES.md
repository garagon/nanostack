# Nanostack Release Notes

The detailed "what changed" surface for Nanostack. The [README](README.md)
stays the stable, user-facing overview; this file records what each release
adds and why it matters. Newest first.

## v1.1.1 (2026-05-30)

Security and safety hardening after v1.1.0. A focused follow-up that closes a
review pass over the guard and workflow-control surface. Normal use is
unchanged: these changes tighten what the guard already does and make the docs
match it. Each one shipped with sabotage and false-positive test cells and a CI
contract.

### Guard and safety

- Command recognition: the guard catches risky operations it previously missed
  through flag permutations, path prefixes, command wrappers, and
  download-to-shell forms.
- Cleanup and archive helpers stay inside their own folders, checked by strict
  selectors.
- Gates and context loaders read verified, integrity-checked evidence.
- Logs and promoted context no longer carry data they should not.
- The global gates (phase concurrency, sprint phase gate, budget gate) run
  before any allowlist or in-project shortcut, so a safe-listed or in-project
  command cannot skip them. The allowlist read exemption is precise about which
  git reads stay available behind the budget wall. `/freeze` is documented as a
  guided instruction the agent follows, not a hook-enforced block.

See PRs #242 through #246.

## v1.1.0 (2026-05-29)

The largest release since v1.0.0: 76 merged PRs. It grows Nanostack from a
fixed sprint into a composable framework, adds a way to read any phase as
local HTML, and hardens the safety and CI contracts. Everything stays local.

### Custom workflow stacks

Nanostack is no longer only the built-in sprint. You can declare your own
phases and compose them into a domain-specific workflow with the same
lifecycle support as the default sprint.

- `bin/create-skill.sh` scaffolds a phase skill (`--from` starts from a
  template).
- `.nanostack/config.json` registers phases (`custom_phases`, `phase_graph`).
  A shared phase registry drives the conductor, guard, session, resolver, and
  next-step, so a custom workflow stack gets graph-aware progression,
  concurrency enforcement, artifact trust, schema validation, and routing
  through `phase_context`.
- `bin/check-custom-skill.sh` validates a stack. The `compliance-release`
  example composes `/license-audit`, `/privacy-check`, and
  `/release-readiness` into one gate before `/ship`, with static, smoke, and
  runtime end-to-end coverage.

### Visual artifacts

- `bin/render-artifact.sh` renders any phase artifact, sprint journal, or
  workflow-stack graph as an offline local HTML view (its own CSS, no
  network).
- `--strict` refuses unverifiable evidence; `--interactive` adds copy-only
  buttons (prompt / Markdown / JSON patch) on `/plan` and `/review`, with no
  writes and no network calls.
- JSON stays canonical; the HTML is a derived view you can delete and
  regenerate. Registered custom phases render too.

### Architecture and safety hardening

- Read-only phases (`/review`, `/security`, `/qa`) now block file mutations
  through Write/Edit/MultiEdit, not just Bash, so they are safe to run as one
  parallel batch.
- A shared artifact-trust primitive adds SHA-256 integrity to saved
  artifacts; release gates require trusted (integrity-checked,
  filename-dated) artifacts and fail closed on tampered evidence.
- Per-phase structured artifact schemas, a graph-aware session lifecycle, and
  a `phase_context` routing contract for custom skills.
- Guard blocks credential JSON at write time and on Bash. Adapter enforcement
  claims are locked to named CI evidence so the docs cannot overclaim.

### /think and onboarding

- `/think` vNext: a structured think artifact, session-first flow, an
  autopilot minimum-viable-brief gate, quiet preset loading, and search modes
  with a privacy boundary (local_only / private / public).
- Guided Archetypes: `/think` detects the kind of work (founder validation,
  CLI tooling, API backend, landing) and routes the matching lens.
- `/nano-run` vNext: a schema-enforced setup artifact, a session-first
  rewrite, and a legacy detector that refuses silent migration.

### Examples library

- A normalized examples index with four starter apps (todo, CLI notes, API
  healthcheck, static landing) plus the `compliance-release` custom workflow
  stack, each tied to the delivery workflow and covered by per-archetype
  sprint end-to-end runs.

### Contributor experience

- The CI harness subsystem shares one core library and fixtures, an inventory
  (`ci/harnesses.json`) that fails when it drifts from the real scripts, and a
  single local runner (`ci/run-harness.sh --all`). The large visual suite is
  split into reviewable sections, and long lint contracts are extracted into
  reusable checks.
- Reliability fixes: real user-flow end-to-end coverage, a macOS write-guard
  symlink bypass closed, and a delivery-matrix harness for per-adapter
  coverage.

### Honest scope

Hard enforcement is host-dependent. Claude Code has the strongest continuous
hook coverage; the other verified adapters (Cursor, OpenAI Codex, OpenCode,
Gemini CLI) run the same workflow as guided instructions unless their
`adapters/<host>.json` proves otherwise. Nanostack has no cloud or backend;
everything is local under `.nanostack/`. The heavier runtime end-to-end suites
run in the opt-in E2E workflow (`workflow_dispatch`), not on every PR; lighter
contract checks, including the visual-artifact contract, do run on every PR.

### Install

```
npx create-nanostack
```

Full changelog: https://github.com/garagon/nanostack/compare/v1.0.0...v1.1.0
