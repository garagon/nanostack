# Compliance Release Stack

A three-skill stack that gates `/ship` on license, privacy, and release-readiness evidence. Read-only by design: no commits, no PRs, no deploys, no network calls.

> Status: **PR 1 of the Custom Stack Examples v1 round.** The manifest, README, and skill folders are in place and the static contract (`ci/check-custom-stack-examples.sh`) passes. Skill behavior lands in PR 2; runtime end-to-end coverage lands in PR 3. The install commands below run once PR 3 ships; until then the skills are stubs that satisfy the structural contract.

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

Then wire the `phase_graph` so the conductor knows the full topology. Resolve the store path the same way the scaffolder did:

```bash
STORE="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/.nanostack"
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
]' "$STORE/config.json" > "$STORE/config.json.tmp" \
  && mv "$STORE/config.json.tmp" "$STORE/config.json"
```

Validate each scaffolded skill against the framework contract:

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
"$NANOSTACK_ROOT/bin/check-custom-skill.sh" "$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/.nanostack/skills/license-audit"
"$NANOSTACK_ROOT/bin/check-custom-skill.sh" "$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/.nanostack/skills/privacy-check"
"$NANOSTACK_ROOT/bin/check-custom-skill.sh" "$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/.nanostack/skills/release-readiness"
```

Each invocation should end with `OK: <name> passed N checks.`. The path expression resolves the same store `bin/create-skill.sh` wrote to (your repo root's `.nanostack/skills/` inside git, or `$HOME/.nanostack/skills/` outside git).

Restart your agent so it picks up the three new slash commands.

## Run the workflow

The skills are read-only and idempotent. Run them in any order; the conductor (and `release-readiness`) reads the latest artifact for each upstream.

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
SKILLS_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/.nanostack/skills"

# License + privacy can run in parallel (both are concurrency=read).
"$SKILLS_ROOT/license-audit/bin/audit.sh"
"$SKILLS_ROOT/privacy-check/bin/check.sh"

# release-readiness composes the upstream artifacts into a status.
"$SKILLS_ROOT/release-readiness/bin/summarize.sh"
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

To remove the stack from a sandbox project (resolves the same store the scaffolder wrote to: repo root inside git, `$HOME/.nanostack/` outside):

```bash
STORE="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/.nanostack"

rm -rf "$STORE/skills/license-audit" \
       "$STORE/skills/privacy-check" \
       "$STORE/skills/release-readiness"

jq '.custom_phases -= ["license-audit","privacy-check","release-readiness"]' \
  "$STORE/config.json" > "$STORE/config.json.tmp" \
  && mv "$STORE/config.json.tmp" "$STORE/config.json"

# Optional: drop the saved artifacts too.
rm -rf "$STORE/license-audit" \
       "$STORE/privacy-check" \
       "$STORE/release-readiness"
```

If you also wired `phase_graph` and want to revert to the canonical default sprint, remove the field:

```bash
STORE="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/.nanostack"
jq 'del(.phase_graph)' "$STORE/config.json" > "$STORE/config.json.tmp" \
  && mv "$STORE/config.json.tmp" "$STORE/config.json"
```

Restart your agent so it stops surfacing the slash commands.
