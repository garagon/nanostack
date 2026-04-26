# Custom Stack Examples v1: Technical Spec

## Status

Draft for implementation planning.

This spec is for the next round after Custom Stack Framework v1. The framework is now real: custom phases can be registered, resolved, saved, surfaced in lifecycle outputs, and scheduled by conductor. The next step is to prove that a user can build a domain workflow on top of it, not only a single custom skill.

## Product Objective

Show that Nanostack is a base framework for building your own agent workflow stack.

The product promise for this round:

> Nanostack gives you the delivery framework. You can bring your own domain workflow as custom skills, and those skills inherit artifacts, resolver context, journals, analytics, conductor scheduling, and local vault output.

The proof must be executable, not copy only. A clean sandbox user should be able to copy or scaffold a stack, run its skills, save artifacts, resolve dependencies, generate journal/analytics, and see conductor schedule the custom graph correctly.

## Why This Round Exists

Custom Stack Framework v1 proved a single skill works:

- `bin/create-skill.sh` can scaffold one custom skill.
- `bin/check-custom-skill.sh` can validate it.
- Lifecycle scripts accept custom phases.
- Conductor reads `concurrency:` from custom `SKILL.md`.

That is necessary but not enough for the product claim "build your own stack." A stack is a domain workflow with multiple phases that hand off context to each other. The next round should prove composition.

## Scope Decision

Start with one fully developed stack, not three.

The first proof point should be:

```text
examples/custom-stack-template/compliance-release/
```

Reason:

- It matches Nanostack's strengths: delivery, review, security, QA, and release evidence.
- It is easy to test in CI without external APIs.
- It demonstrates a real multi-skill graph:
  - one skill scans licenses
  - one skill checks privacy/release data handling
  - one skill composes those results into a release decision
- It avoids vague "marketing workflow" behavior that is harder to verify deterministically.

Future stacks like marketing, data, or design should wait until the first stack exposes the right file shape and test contract.

## Non-Goals

- Do not build a new stack installer yet.
- Do not introduce a daemon, package manager, or plugin registry.
- Do not require Node, Python packages, Docker, network access, or external services.
- Do not claim "one command installs a full stack" unless the command exists and is covered by E2E.
- Do not move the README hero to "framework" before at least one real stack example lands and passes CI.
- Do not create three shallow examples. One complete stack is more valuable than three brochure examples.

## Directory Contract

Add a new directory:

```text
examples/custom-stack-template/
  README.md
  compliance-release/
    README.md
    stack.json
    skills/
      license-audit/
        SKILL.md
        agents/openai.yaml
        bin/audit.sh
        bin/smoke.sh
      privacy-check/
        SKILL.md
        agents/openai.yaml
        bin/check.sh
        bin/smoke.sh
      release-readiness/
        SKILL.md
        agents/openai.yaml
        bin/summarize.sh
        bin/smoke.sh
```

### Why `stack.json`

`stack.json` in this directory is an example manifest, not Nanostack's technology stack preferences file. It must not be read by `/nano` as project stack defaults.

The file exists so docs, CI, and future tooling can agree on the stack composition without scraping prose.

If this name is too ambiguous with existing `.nanostack/stack.json`, use `custom-stack.json` instead. Do not introduce both. The implementation PR should make one explicit choice and document it.

Recommended decision: use `stack.json` inside `examples/custom-stack-template/<stack-name>/` because Opus already named that shape, but keep the schema field `kind: "custom_stack_example"` to prevent confusion.

## Stack Manifest Schema

`examples/custom-stack-template/compliance-release/stack.json`:

```json
{
  "schema_version": "1",
  "kind": "custom_stack_example",
  "name": "compliance-release",
  "display_name": "Compliance Release Stack",
  "description": "A read-only release compliance workflow that checks licenses, privacy signals, and release readiness before /ship.",
  "skills": [
    {
      "name": "license-audit",
      "path": "skills/license-audit",
      "concurrency": "read",
      "depends_on": ["build"]
    },
    {
      "name": "privacy-check",
      "path": "skills/privacy-check",
      "concurrency": "read",
      "depends_on": ["build"]
    },
    {
      "name": "release-readiness",
      "path": "skills/release-readiness",
      "concurrency": "read",
      "depends_on": ["review", "qa", "security", "license-audit", "privacy-check"]
    }
  ],
  "phase_graph": [
    { "name": "think", "depends_on": [] },
    { "name": "plan", "depends_on": ["think"] },
    { "name": "build", "depends_on": ["plan"] },
    { "name": "review", "depends_on": ["build"] },
    { "name": "qa", "depends_on": ["build"] },
    { "name": "security", "depends_on": ["build"] },
    { "name": "license-audit", "depends_on": ["build"] },
    { "name": "privacy-check", "depends_on": ["build"] },
    { "name": "release-readiness", "depends_on": ["review", "qa", "security", "license-audit", "privacy-check"] },
    { "name": "ship", "depends_on": ["release-readiness"] }
  ],
  "expected_evidence": [
    "resolve.sh release-readiness returns upstream_artifacts for review, qa, security, license-audit, and privacy-check",
    "conductor batch schedules license-audit and privacy-check as read phases after build",
    "sprint-journal.sh emits sections for all three custom phases",
    "analytics.sh --json counts all three custom phases"
  ]
}
```

Validation rules:

- `schema_version` must be `"1"`.
- `kind` must be `"custom_stack_example"`.
- `name` must match `^[a-z][a-z0-9-]*$`.
- Each `skills[].name` must match the phase regex.
- Each `skills[].path` must exist and contain `SKILL.md`.
- Each skill must pass `bin/check-custom-skill.sh` after installation into a temp project.
- Every `phase_graph[].name` must be either core, `build`, or listed in `skills[].name`.
- Every custom skill listed in `phase_graph` must appear in `skills`.
- `ship` must depend on `release-readiness`, not directly on the review/security/QA trio in this stack.

## Stack Behavior

### Skill 1: `/license-audit`

Purpose:

Read dependency manifests and identify license risk before release.

Inputs:

- `package.json`
- `requirements.txt`
- `pyproject.toml`
- `go.mod`

Output artifact:

```json
{
  "phase": "license-audit",
  "summary": {
    "status": "OK",
    "headline": "No GPL/AGPL licenses found in direct dependencies.",
    "counts": {
      "total": 12,
      "permissive": 10,
      "weak_copyleft": 1,
      "strong_copyleft": 0,
      "unknown": 1
    },
    "flagged": [],
    "next_action": "None."
  },
  "context_checkpoint": {
    "summary": "License audit completed.",
    "key_files": ["package.json"],
    "decisions_made": [],
    "open_questions": []
  }
}
```

Rules:

- Read-only.
- No network.
- Direct dependencies only unless a lockfile parser is already available without installing dependencies.
- Unknown licenses produce `status: "WARN"`, not `OK`.
- GPL or AGPL produces `status: "BLOCKED"`.

### Skill 2: `/privacy-check`

Purpose:

Check whether the release introduces obvious privacy/data-handling risk before shipping.

This is not a legal review. It is a deterministic release hygiene check.

Inputs:

- README files
- `TELEMETRY.md` if present
- `.env.example`, `.env.sample`, `.env.template`
- app source files under common locations:
  - `src/`
  - `app/`
  - `pages/`
  - `server/`
  - `api/`

Checks:

- Detects forms or API routes that collect email, name, phone, address, payment, token, API key, or uploaded files.
- Detects telemetry words: analytics, tracking, telemetry, segment, posthog, ga, mixpanel, sentry.
- Detects whether a privacy note exists in README or `PRIVACY.md` when collection signals exist.
- Detects unsafe examples in env templates, but must not read real `.env` files.

Output artifact:

```json
{
  "phase": "privacy-check",
  "summary": {
    "status": "WARN",
    "headline": "Email collection detected but no privacy note found.",
    "signals": [
      {
        "kind": "personal_data",
        "file": "src/signup.js",
        "evidence": "email"
      }
    ],
    "missing": ["privacy_note"],
    "next_action": "Add a short privacy note before shipping."
  },
  "context_checkpoint": {
    "summary": "Privacy check completed.",
    "key_files": ["src/signup.js"],
    "decisions_made": [],
    "open_questions": ["Where should the privacy note live?"]
  }
}
```

Rules:

- Read-only.
- Must not read `.env`, `.env.local`, `.env.production`, secret JSON files, or private key files.
- It may read env templates allowed by guard: `.env.example`, `.env.sample`, `.env.template`.
- It must report "not a legal review" in the skill close, not in every artifact field.
- It must never claim GDPR/CCPA compliance.

### Skill 3: `/release-readiness`

Purpose:

Compose core and custom evidence into a release decision before `/ship`.

Inputs:

- `review`
- `qa`
- `security`
- `license-audit`
- `privacy-check`

Resolver behavior:

`bin/resolve.sh release-readiness` must return:

```json
{
  "phase": "release-readiness",
  "phase_kind": "custom",
  "upstream_artifacts": {
    "review": "/path/or/null",
    "qa": "/path/or/null",
    "security": "/path/or/null",
    "license-audit": "/path/or/null",
    "privacy-check": "/path/or/null"
  }
}
```

Output artifact:

```json
{
  "phase": "release-readiness",
  "summary": {
    "status": "BLOCKED",
    "headline": "Release blocked: privacy note missing and QA evidence absent.",
    "checks": [
      { "phase": "review", "status": "OK", "evidence": "artifact" },
      { "phase": "qa", "status": "MISSING", "evidence": null },
      { "phase": "security", "status": "OK", "evidence": "artifact" },
      { "phase": "license-audit", "status": "OK", "evidence": "artifact" },
      { "phase": "privacy-check", "status": "WARN", "evidence": "artifact" }
    ],
    "next_action": "Run /qa and add a privacy note before /ship."
  },
  "context_checkpoint": {
    "summary": "Release readiness composed upstream evidence.",
    "key_files": [],
    "decisions_made": [],
    "open_questions": []
  }
}
```

Rules:

- Read-only.
- Missing required upstreams are `MISSING`.
- Any upstream `BLOCKED` makes release-readiness `BLOCKED`.
- Any upstream `WARN` with no explicit mitigation makes release-readiness `WARN` at minimum.
- `OK` only when all required upstreams are present and none is `WARN` or `BLOCKED`.
- It does not create PRs, commit, deploy, or run `/ship`.

## Installation Path For The Example

The README should show only commands that work today.

Recommended user flow:

```bash
# from a sandbox project where nanostack is available
bin/create-skill.sh license-audit \
  --from examples/custom-stack-template/compliance-release/skills/license-audit \
  --concurrency read \
  --depends-on build

bin/create-skill.sh privacy-check \
  --from examples/custom-stack-template/compliance-release/skills/privacy-check \
  --concurrency read \
  --depends-on build

bin/create-skill.sh release-readiness \
  --from examples/custom-stack-template/compliance-release/skills/release-readiness \
  --concurrency read \
  --depends-on review \
  --depends-on qa \
  --depends-on security \
  --depends-on license-audit \
  --depends-on privacy-check
```

Then configure the graph:

```bash
jq '.phase_graph = [
  {"name":"think","depends_on":[]},
  {"name":"plan","depends_on":["think"]},
  {"name":"build","depends_on":["plan"]},
  {"name":"review","depends_on":["build"]},
  {"name":"qa","depends_on":["build"]},
  {"name":"security","depends_on":["build"]},
  {"name":"license-audit","depends_on":["build"]},
  {"name":"privacy-check","depends_on":["build"]},
  {"name":"release-readiness","depends_on":["review","qa","security","license-audit","privacy-check"]},
  {"name":"ship","depends_on":["release-readiness"]}
]' .nanostack/config.json > .nanostack/config.json.tmp &&
mv .nanostack/config.json.tmp .nanostack/config.json
```

If this feels too long in docs, the implementation may add a tiny example-local helper:

```text
examples/custom-stack-template/compliance-release/bin/install.sh
```

But only if:

- It is pure bash + jq.
- It calls existing `bin/create-skill.sh`.
- It is covered by E2E.
- Public docs say "example helper", not "new framework installer".

## E2E Contract

Add:

```text
ci/check-custom-stack-examples.sh
ci/e2e-custom-stack-examples.sh
```

### Static Contract: `ci/check-custom-stack-examples.sh`

Validates:

- `examples/custom-stack-template/README.md` exists.
- `examples/custom-stack-template/compliance-release/README.md` exists.
- `stack.json` parses with `jq`.
- `stack.json.kind == "custom_stack_example"`.
- All `skills[].path` exist.
- All `skills[].name` match directory basenames.
- Each skill has:
  - `SKILL.md`
  - `agents/openai.yaml`
  - at least one `bin/*.sh`
  - `bin/smoke.sh`
- Every shell script passes `bash -n`.
- No committed runtime artifacts:
  - `.nanostack/`
  - `node_modules/`
  - `.env`
  - real credential JSON
  - logs
- README has these sections:
  - "Who this stack is for"
  - "What it adds"
  - "Install in a sandbox"
  - "Run the workflow"
  - "Expected evidence"
  - "Reset"
- README must mention `bin/create-skill.sh`, `bin/check-custom-skill.sh`, `conductor/bin/sprint.sh`, and `release-readiness`.

### Runtime Contract: `ci/e2e-custom-stack-examples.sh`

Runs in a temp project. No network.

Cells:

1. Create a fixture app with:
   - `package.json`
   - `README.md`
   - `.env.example`
   - one source file with an email field
2. Install the three skills using the documented commands or the example helper.
3. Validate each skill with `bin/check-custom-skill.sh`.
4. Save minimal fake core artifacts for `review`, `qa`, and `security`.
5. Run `license-audit/bin/audit.sh` and save a `license-audit` artifact.
6. Run `privacy-check/bin/check.sh` and save a `privacy-check` artifact.
7. Run `bin/resolve.sh release-readiness` and assert upstream keys include all five dependencies.
8. Run `release-readiness/bin/summarize.sh` and save a `release-readiness` artifact.
9. Run `bin/sprint-journal.sh` and assert sections exist:
   - `## /license-audit`
   - `## /privacy-check`
   - `## /release-readiness`
10. Run `bin/analytics.sh --json` and assert all three custom phases are counted under `sprints.custom`.
11. Run `bin/discard-sprint.sh --dry-run` and assert custom artifacts are listed.
12. Run `conductor/bin/sprint.sh start` with the stack's `phase_graph`.
13. Run `conductor/bin/sprint.sh batch` and assert:
   - `license-audit` and `privacy-check` are `type=read`
   - both appear after `build`
   - `release-readiness` appears after `license-audit`, `privacy-check`, `review`, `qa`, and `security`
   - `ship` appears after `release-readiness`
14. Run the same install from a git subdirectory and assert no rogue subdir `.nanostack/` is created.
15. Run no-git install with fake `$HOME` and assert skills land in `$HOME/.nanostack/skills`.

Acceptance target:

- At least 35 assertions.
- The harness output must include a final count, e.g.:

```text
Custom Stack Examples E2E: 42 checks passed, 0 failed
```

## CI Integration

Add lint jobs:

```text
custom-stack-examples-contract
```

Optionally add workflow_dispatch job in `.github/workflows/e2e.yml`:

```text
e2e-custom-stack-examples
```

Do not run heavy E2E on every PR unless existing policy changes. Static checks can run in lint; runtime stack E2E may remain workflow_dispatch if consistent with current E2E policy.

## Public Wording Contract

Do not reposition the README hero until the first stack example is green.

After the stack lands, README can add a short section near the top:

```text
Use Nanostack as-is, or build your own workflow stack on top.
```

Allowed claims after this round:

- "Build your own workflow stack."
- "Custom skills can compose into a domain workflow."
- "The compliance-release example proves save, resolve, journal, analytics, discard, and conductor work together."
- "No SaaS, no daemon, no build step."

Disallowed claims:

- "Install any stack with one command" unless a covered installer exists.
- "Marketplace" or "plugin ecosystem".
- "Compliance certified", "GDPR ready", "SOC2 ready", or legal compliance claims.
- "Works in every agent identically." Adapter honesty still applies.

## README Follow-Up Gates

The README/landing repositioning becomes eligible only when all are true:

- `examples/custom-stack-template/compliance-release/` exists.
- Static and runtime stack example checks are green.
- The stack README explains installation without requiring source reading.
- `EXTENDING.md` links to the stack example.
- `README.es.md` has equivalent first-class wording.

Until then, framework wording should remain in the middle of the README, not the hero.

## Suggested PR Split

### PR 1: Stack Example Contract

Files:

- `reference/custom-stack-examples-technical-spec.md`
- `examples/custom-stack-template/README.md`
- `examples/custom-stack-template/compliance-release/README.md`
- `examples/custom-stack-template/compliance-release/stack.json`
- `ci/check-custom-stack-examples.sh`
- `.github/workflows/lint.yml`

Acceptance:

- Static contract validates the manifest and README shape.
- No skill behavior yet beyond placeholder folders if needed.
- Public docs do not claim the stack is runnable until PR 3.

### PR 2: Compliance Skills

Files:

- `examples/custom-stack-template/compliance-release/skills/license-audit/**`
- `examples/custom-stack-template/compliance-release/skills/privacy-check/**`
- `examples/custom-stack-template/compliance-release/skills/release-readiness/**`

Acceptance:

- Each skill passes `bin/check-custom-skill.sh` after install into a temp project.
- Each `bin/smoke.sh` passes.
- No external runtime dependencies.

### PR 3: Runtime E2E

Files:

- `ci/e2e-custom-stack-examples.sh`
- `.github/workflows/e2e.yml`
- updates to `ci/check-custom-stack-examples.sh`

Acceptance:

- Full 15-cell runtime contract passes locally.
- Conductor schedule proves custom phase ordering and concurrency.
- Journal, analytics, discard, resolver all prove composition.

### PR 4: Public Docs and Positioning

Files:

- `README.md`
- `README.es.md`
- `EXTENDING.md`
- `examples/custom-stack-template/README.md`

Acceptance:

- Public copy uses "build your own workflow stack" only where the harness proves it.
- Spanish docs are first-class.
- No overclaims about compliance, marketplace, or cross-agent enforcement.

## Manual Retest Script For Codex

After PR 3 or PR 4, Codex should run:

```bash
ci/check-custom-stack-examples.sh
ci/e2e-custom-stack-examples.sh
```

Then manually test one no-docs user path:

```bash
tmp=$(mktemp -d)
cd "$tmp"
git init
cp -R /path/to/nanostack/examples/custom-stack-template/compliance-release ./compliance-release
# follow the README only, no source reading
```

Pass condition:

- The README commands are sufficient.
- No hidden environment variable is required.
- No real secrets are read.
- `release-readiness` blocks when privacy or QA evidence is missing.
- `release-readiness` passes when all upstream artifacts are `OK`.

## Risks

### Risk: Stack examples become marketing demos

Mitigation:

- Every stack claim must have a static or runtime assertion.
- The first stack must be deterministic and local.

### Risk: `stack.json` conflicts with existing stack preferences

Mitigation:

- Keep example manifest under `examples/custom-stack-template/<name>/stack.json`.
- Add `kind: "custom_stack_example"`.
- Do not teach users to copy it to `.nanostack/stack.json`.

### Risk: Skills duplicate built-in `/security`

Mitigation:

- `privacy-check` checks release hygiene only.
- It does not claim vulnerability coverage.
- It never replaces `/security`.

### Risk: Example helper becomes untested framework API

Mitigation:

- If an install helper exists, keep it under the example directory.
- Call it "example helper".
- Cover it with E2E.

## Done Definition

This round is done when:

- One real custom stack exists under `examples/custom-stack-template/compliance-release/`.
- The stack has 3 working custom skills.
- The stack has a manifest and README.
- Static checks validate the manifest, docs, scripts, and no-runtime-artifact policy.
- Runtime E2E proves install, validate, run, save, resolve, journal, analytics, discard, and conductor scheduling.
- `EXTENDING.md` points users to the stack as the next step after the single-skill template.
- README/README.es may mention "build your own workflow stack" with no overclaims.

## What Comes After

After one stack proves the abstraction:

1. Add a second stack only if the contract held without major refactors.
2. Reposition README top copy around:

   ```text
   Use Nanostack's delivery workflow, or build your own workflow stack on top.
   ```

3. Create a 60-second sandbox demo using the smallest path from the first stack.

