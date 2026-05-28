# Harness Contract

The CI harness subsystem has a single source of truth: [`ci/harnesses.json`](../ci/harnesses.json). Every test/contract harness under `ci/` is registered there, validated by [`ci/check-harness-manifest.sh`](../ci/check-harness-manifest.sh), and run through [`ci/run-harness.sh`](../ci/run-harness.sh).

Introduced in Harness Architecture vNext PR 3 (2026-05-28).

## Building blocks

- [`ci/lib/harness.sh`](../ci/lib/harness.sh) - shared assertion/counter/temp core (`nh_*`). New suites source this instead of re-implementing counters, colors, `set -e` capture, and the `/tmp` temp-root rule.
- [`ci/lib/fixtures.sh`](../ci/lib/fixtures.sh) - shared fixtures (`nf_*`): git projects, stores, artifacts (the `verified` hash reuses the production canonical path, not a parallel one), custom phases, phase graphs, sessions.
- `ci/harnesses.json` - the manifest (this contract).
- `ci/check-harness-manifest.sh` - static consistency check (never runs a heavy suite).
- `ci/run-harness.sh` - the local full-gauntlet runner.

## Manifest schema

Each entry in `.suites[]`:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Unique short id (used by `--suite`). |
| `path` | yes | Repo-relative path to the harness; must exist. |
| `kind` | yes | `unit` \| `static-contract` \| `runtime-e2e` \| `visual-e2e` \| `example-e2e`. |
| `tier` | yes | `pr` (workflow triggers on both `pull_request` and `push`) \| `opt-in` (manual-only: `workflow_dispatch`/`workflow_call`, no automatic trigger) \| `local` (developer-run, not wired to CI). |
| `surface` | yes | Non-empty list of subsystems the suite covers. |
| `deps` | yes | Non-empty list of required commands; the runner skips a suite whose deps are missing. |
| `expected_checks` | yes | Drift hint (number). Not verified by the manifest check, which never runs suites; `delivery-matrix` counts cells. |
| `timeout_minutes` | recommended | Advisory budget. |
| `workflow` + `job` | when CI-wired | The workflow file and the `jobs:` key that runs the suite. Both or neither. |

## What the manifest check enforces

`ci/check-harness-manifest.sh` fails closed when:

- the manifest is not valid JSON with a non-empty `.suites`;
- any suite is missing a required field, or `kind`/`tier` is outside its enum;
- two suites share an `id`;
- a manifest `path` does not exist on disk;
- a `ci/e2e-*.sh` or `ci/check-*.sh` file on disk is **not** registered;
- any `tests/*.sh` file exists but is not registered (e.g. `tests/run.sh` is classified `kind=unit tier=local`);
- a suite declares a `workflow`/`job` whose file or job key does not exist;
- a workflow `run:` line invokes a `ci/(e2e|check)-*.sh` path that no longer exists.

It is a static check. It does not run suites. Heavy execution belongs to the runner. The sabotage cells in [`ci/e2e-harness-manifest-selftest.sh`](../ci/e2e-harness-manifest-selftest.sh) prove each failure direction.

## Running suites locally

```
ci/run-harness.sh --list                       # every registered suite
ci/run-harness.sh --suite artifact-trust       # one suite
ci/run-harness.sh --suite artifact-trust --filter gate
ci/run-harness.sh --kind static-contract       # all of a kind
ci/run-harness.sh --tier opt-in --dry-run      # what the opt-in tier would run
ci/run-harness.sh --all                        # the full gauntlet
```

The runner validates a suite's `deps` before running it, runs serially, prints a `suite / checks / result / seconds` table, and exits non-zero if any selected suite fails. `--continue-on-fail`, `--json`, and `--dry-run` are available.

## Adding a new harness

1. Write the suite sourcing `ci/lib/harness.sh` (and `ci/lib/fixtures.sh` if it builds projects/artifacts). Support `--filter`.
2. Add an entry to `ci/harnesses.json` with all required fields.
3. If it should run in CI, add the job to the workflow and set `workflow`/`job`.
4. `ci/check-harness-manifest.sh` must pass. A new `ci/e2e-*.sh` left unregistered fails the check.

## Tier policy

The `pr` tier runs on every change and must stay fast; heavier runtime suites live in the `opt-in` tier (`.github/workflows/e2e.yml`, `workflow_dispatch`). Do not move a suite to `pr` without a deliberate decision, and never count a `workflow_dispatch`-only job as continuous adapter evidence (see `reference/host-adapter-schema.md`).
