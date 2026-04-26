# Compliance Release Stack

A three-skill stack that gates `/ship` on license, privacy, and release-readiness evidence. Read-only by design: no commits, no PRs, no deploys, no network calls.

> Status: end-to-end working. The static contract (`ci/check-custom-stack-examples.sh`, 49 checks) runs on every PR; the runtime harness (`ci/e2e-custom-stack-examples.sh`, 15 cells / 51 assertions) runs in the opt-in E2E workflow. The install commands below are the same ones the harness exercises.

## Who this stack is for

Teams that ship code with third-party dependencies and may collect personal data, and want a deterministic release-decision step before `/ship`. Concretely:

- You want a release gate that fails closed when QA evidence is missing or a privacy signal has no documented mitigation.
- You want license risk surfaced as part of the sprint, not as a separate manual step.
- You want the gate's decision recorded as an artifact your sprint journal and analytics already understand.

If you only need any one of those, copying a single skill from `examples/custom-skill-template/` is a smaller starting point. This stack is the integrated workflow.

## What it adds

Three custom phases, wired into the sprint via `phase_graph` so `conductor/bin/sprint.sh` knows the dependency order:

- **`/license-audit`**: scans direct dependencies for GPL, AGPL, or unknown licenses. Output: per-family counts and a flagged list. Status `OK`, `WARN` (unknown licenses), or `BLOCKED` (GPL/AGPL).
- **`/privacy-check`**: release-hygiene check. Surfaces personal-data collection signals (forms, API routes that take email/name/phone/address/payment), telemetry libraries, and whether a privacy note exists. **Not a legal review.**
- **`/release-readiness`**: composer. Reads `review`, `qa`, `security`, `license-audit`, and `privacy-check` artifacts and emits a single status. `BLOCKED` if any upstream is `BLOCKED` or required evidence is missing; `WARN` if any upstream is `WARN`; `OK` otherwise. Sits between the rest of the sprint and `/ship`.

The `phase_graph` in `stack.json` puts `release-readiness` directly upstream of `ship` so the conductor cannot schedule `/ship` before the gate has run.

## Install in a sandbox

> The install commands below assume Custom Stack Examples PR 2 has merged so each skill has real behavior. Until then, scaffolding works but the helpers print placeholder output. PR 3 wires the runtime end-to-end harness that proves this section.

The Nanostack scaffolder (`bin/create-skill.sh`) reads the source skill via `--from`. Setting an absolute path makes the install work regardless of the sandbox project's cwd. Point `NANOSTACK_ROOT` at your local Nanostack checkout (the directory that contains `bin/create-skill.sh`):

```bash
# Substitute the path to your Nanostack checkout.
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
STACK_DIR="$NANOSTACK_ROOT/examples/custom-stack-template/compliance-release"
```

Scaffold the three skills from the absolute stack path:

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
STACK_DIR="$NANOSTACK_ROOT/examples/custom-stack-template/compliance-release"

"$NANOSTACK_ROOT/bin/create-skill.sh" license-audit \
  --from "$STACK_DIR/skills/license-audit" \
  --concurrency read \
  --depends-on build

"$NANOSTACK_ROOT/bin/create-skill.sh" privacy-check \
  --from "$STACK_DIR/skills/privacy-check" \
  --concurrency read \
  --depends-on build

"$NANOSTACK_ROOT/bin/create-skill.sh" release-readiness \
  --from "$STACK_DIR/skills/release-readiness" \
  --concurrency read \
  --depends-on review \
  --depends-on qa \
  --depends-on security \
  --depends-on license-audit \
  --depends-on privacy-check
```

`bin/create-skill.sh` resolves the install destination via `bin/lib/store-path.sh` (your repo root's `.nanostack/`, or `$HOME/.nanostack/` outside git), so the skills land where every lifecycle script reads from regardless of which subdirectory you ran the command from.

Then wire the `phase_graph` so the conductor knows the full topology. Resolve the store path the same way the scaffolder did, by sourcing `bin/lib/store-path.sh`. That gives `$NANOSTACK_STORE` with the same priority order lifecycle scripts use: an explicit `NANOSTACK_STORE` env var first, then the git repo root, then `$HOME/.nanostack/`. Skipping this step would split the install across two stores when a user or harness has `NANOSTACK_STORE` exported.

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
. "$NANOSTACK_ROOT/bin/lib/store-path.sh"

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
]' "$NANOSTACK_STORE/config.json" > "$NANOSTACK_STORE/config.json.tmp" \
  && mv "$NANOSTACK_STORE/config.json.tmp" "$NANOSTACK_STORE/config.json"
```

Validate each scaffolded skill against the framework contract:

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
. "$NANOSTACK_ROOT/bin/lib/store-path.sh"

"$NANOSTACK_ROOT/bin/check-custom-skill.sh" "$NANOSTACK_STORE/skills/license-audit"
"$NANOSTACK_ROOT/bin/check-custom-skill.sh" "$NANOSTACK_STORE/skills/privacy-check"
"$NANOSTACK_ROOT/bin/check-custom-skill.sh" "$NANOSTACK_STORE/skills/release-readiness"
```

Each invocation should end with `OK: <name> passed N checks.`. The path resolves through `bin/lib/store-path.sh`, the exact same priority order `bin/create-skill.sh` used to install the skill: explicit `NANOSTACK_STORE` env var, then git repo root's `.nanostack/`, then `$HOME/.nanostack/`.

Restart your agent so it picks up the three new slash commands.

## Run the workflow

The skills are read-only and idempotent. Run them in any order; the conductor (and `release-readiness`) reads the latest artifact for each upstream.

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
. "$NANOSTACK_ROOT/bin/lib/store-path.sh"

# License + privacy can run in parallel (both are concurrency=read).
"$NANOSTACK_STORE/skills/license-audit/bin/audit.sh"
"$NANOSTACK_STORE/skills/privacy-check/bin/check.sh"

# release-readiness composes the upstream artifacts into a status.
"$NANOSTACK_STORE/skills/release-readiness/bin/summarize.sh"
```

Each helper saves an artifact via `bin/save-artifact.sh`. The full schedule, including parallelism, comes from the conductor:

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
"$NANOSTACK_ROOT/conductor/bin/sprint.sh" start
"$NANOSTACK_ROOT/conductor/bin/sprint.sh" batch
```

`batch` returns the parallel groups in topological order. `license-audit` and `privacy-check` schedule together as `concurrency: read` after `build`; `release-readiness` waits for those plus the core review/qa/security artifacts; `ship` waits for `release-readiness`.

## Expected evidence

After running the workflow once, these are the artifacts and outputs you should see; every line is something Codex's spec or PR 3's harness asserts.

- `.nanostack/license-audit/<timestamp>.json` exists with `summary.status`, `summary.counts`, `summary.flagged`.
- `.nanostack/privacy-check/<timestamp>.json` exists with `summary.status`, `summary.signals`, `summary.missing`.
- `.nanostack/release-readiness/<timestamp>.json` exists with `summary.status`, `summary.checks` (one entry per upstream), and `summary.next_action`.
- `bin/resolve.sh release-readiness` returns `phase_kind: "custom"` with `upstream_artifacts` keys for all five upstreams.
- `bin/sprint-journal.sh` emits `## /license-audit`, `## /privacy-check`, and `## /release-readiness` sections.
- `bin/analytics.sh --json` includes all three phases under `sprints.custom`, with `sprints.total` summing core + custom.
- `bin/discard-sprint.sh --dry-run` lists the three custom artifacts alongside the core ones.
- `conductor/bin/sprint.sh batch` schedules `license-audit` and `privacy-check` as `type=read` after `build`, then `release-readiness` after the five upstreams complete, then `ship` after `release-readiness`.

If any of these fails, `release-readiness` is supposed to surface it. That's the entire point of the gate.

## Reset

To remove the stack from a sandbox project (resolves the same store the scaffolder wrote to: explicit `NANOSTACK_STORE` env var, then git repo root, then `$HOME/.nanostack/`):

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
. "$NANOSTACK_ROOT/bin/lib/store-path.sh"

rm -rf "$NANOSTACK_STORE/skills/license-audit" \
       "$NANOSTACK_STORE/skills/privacy-check" \
       "$NANOSTACK_STORE/skills/release-readiness"

jq '.custom_phases -= ["license-audit","privacy-check","release-readiness"]' \
  "$NANOSTACK_STORE/config.json" > "$NANOSTACK_STORE/config.json.tmp" \
  && mv "$NANOSTACK_STORE/config.json.tmp" "$NANOSTACK_STORE/config.json"

# Optional: drop the saved artifacts too.
rm -rf "$NANOSTACK_STORE/license-audit" \
       "$NANOSTACK_STORE/privacy-check" \
       "$NANOSTACK_STORE/release-readiness"
```

If you also wired `phase_graph` and want to revert to the canonical default sprint, remove the field:

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
. "$NANOSTACK_ROOT/bin/lib/store-path.sh"
jq 'del(.phase_graph)' "$NANOSTACK_STORE/config.json" > "$NANOSTACK_STORE/config.json.tmp" \
  && mv "$NANOSTACK_STORE/config.json.tmp" "$NANOSTACK_STORE/config.json"
```

Restart your agent so it stops surfacing the slash commands.
