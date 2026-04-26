# Custom Stack Contract

What a custom phase guarantees and what it does not. This document is the authoritative description of how `bin/lib/phases.sh`, `bin/resolve.sh`, and the rest of the lifecycle scripts treat a phase that the user registered themselves.

This contract is written incrementally. PR 1 added the registry. PR 2 (this section) adds the resolver. Later PRs extend the same surface.

## Phase kinds

A phase belongs to one of three kinds:

| Kind | Source | Notes |
|---|---|---|
| `core` | The immutable list `think plan review qa security ship`. | Built into Nanostack. Cannot be redefined. |
| `custom` | `.custom_phases` array in `.nanostack/config.json` (project) or `~/.nanostack/config.json` (global). Custom names must match `^[a-z][a-z0-9-]*$`. | The registry rejects invalid names and silently drops attempts to override a core name. |
| `unknown` | A phase the user mentions that is not in either list. | Lifecycle scripts treat this as an error. |

`bin/lib/phases.sh` is the single source of truth. Every lifecycle script reads from it.

## Resolver behavior

`bin/resolve.sh <phase>` returns one of three shapes.

### Core phase

Routing is hardcoded. Each core phase declares its upstream phases, whether to load solutions, conflict precedents, diarizations, and so on. The output keeps the historical shape and adds one new field, `phase_kind`, set to `"core"`. Skills that already consume the resolver are unaffected.

### Registered custom phase

Output:

```json
{
  "phase": "audit-licenses",
  "phase_kind": "custom",
  "upstream_artifacts": {
    "build": null,
    "plan": "/path/to/plan/artifact.json",
    "ship": null
  },
  "solutions": [],
  "conflict_precedents": null,
  "diarizations": [],
  "config": { ... },
  "goal": "...",
  "sprint_metrics": null
}
```

Rules:

- `phase_kind` is `"custom"`.
- `upstream_artifacts` is keyed on each declared dependency. The value is the artifact path if one exists within the configured age window, or `null` if the dep was declared but no artifact was found. This is different from core phases, which omit missing upstreams entirely. Custom phases keep the key so consumers can tell "we asked for this and found nothing" apart from "this was never a dep".
- `build` is allowed in dependency lists (the conductor's build stage). It produces no artifact, so the resolver records it as `null`.
- `solutions` is `[]`. Custom skills decide for themselves whether to load solutions; the core resolver does not run that logic for custom phases yet.
- `conflict_precedents` is `null` and `diarizations` is `[]`. Same reasoning.
- `config`, `goal`, and `sprint_metrics` are populated using the same logic as for core phases.

The resolver exits `0`. A custom skill that runs under `set -e` can rely on the call succeeding.

### Unregistered phase

Output:

```
{"error": "unknown phase: <name>"}
```

Exit code `1`. This is unchanged from previous behavior and matches what `set -e` callers already expect.

## Where dependencies come from

The resolver looks for the custom phase's dependency list in this order:

1. **`phase_graph` in `.nanostack/config.json`**. The library validates the graph (names match the regex, names exist in core ∪ custom ∪ `build`, every `depends_on[]` entry references a name that appears in the graph). Invalid graphs fall back to the default with a stderr warning, so the resolver never sees an invalid topology.
2. **`depends_on:` in the skill's `SKILL.md` frontmatter**. Both inline (`depends_on: [plan, build]`) and block (`depends_on:\n  - plan\n  - build`) YAML list forms parse. The skill is found via `nano_phase_skill_path`.
3. If neither lists the phase, `upstream_artifacts` is `{}`.

## What the resolver does NOT do for custom phases (yet)

- It does not load solutions, precedents, or diarizations. Skills that want those can call the helpers directly (`bin/find-solution.sh`, etc.).
- It does not read custom routing rules from a config file. Routing is currently keyed on the dependency list only.
- It does not enforce the conductor's `concurrency` field. That work belongs to PR 5 (conductor custom graph).
- It does not check skill discovery files (`agents/openai.yaml`). That belongs to PR 3 (copy-paste template) and PR 6 (`bin/check-custom-skill.sh`).

## Lifecycle outputs

`bin/analytics.sh`, `bin/sprint-journal.sh`, and `bin/discard-sprint.sh` each include registered custom phases.

### Analytics

`bin/analytics.sh --json` adds three fields to the existing `sprints` object:

```json
{
  "sprints": {
    "think": 1, "plan": 1, "review": 1, "qa": 1, "security": 1, "ship": 1,
    "core_total": 6,
    "custom": { "audit-licenses": 1 },
    "custom_total": 1,
    "total": 7
  }
}
```

Rules:

- The six core phase keys keep their historical names and counts. Existing consumers see no shape change.
- `core_total` is the sum of the six core counts. `custom_total` is the sum of all registered custom phases. `total` is the sum of both.
- `custom` is an object keyed on registered custom phase names. With no registered custom phases, it is `{}` and `custom_total` is `0`. In that case `total` equals `core_total`, matching the historical behavior.

The text and Obsidian-dashboard outputs add one row per registered custom phase under the existing "Sprint phases" block.

### Sprint journal

`bin/sprint-journal.sh` emits the existing `/think`, `/plan`, `/review`, `/qa`, `/security`, `/ship` sections for core phases, then iterates over registered custom phases and emits a generic section per phase that has an artifact for the current project:

```
## /audit-licenses

**Status:** OK
**Summary:** 47 deps scanned, 0 GPL/AGPL flagged
**Next:** none
**Artifact:** .nanostack/audit-licenses/20260426-145855.json
```

Field resolution order for the section body:

- **Status** — `summary.status`. Skipped if absent.
- **Summary** — first hit of `summary.headline`, then `summary.result`. If both are missing AND `summary.status` is also missing, falls back to a compact JSON dump of `summary` so the section is never silently empty.
- **Next** — `summary.next_action`. Skipped if absent.
- **Artifact** — always present, full path to the JSON file.

A custom phase with no artifact for the current project produces no section.

### Discard

`bin/discard-sprint.sh --dry-run` (no `--phase` flag) iterates over every registered phase, core and custom, and lists `[dry-run] would delete: <path>` for each artifact in the date window. Without registered custom phases this is identical to the historical behavior; with custom phases registered, the default discard cleans them too. The explicit `--phase <name>` flag still narrows to a single phase.

## Conductor

`conductor/bin/sprint.sh` accepts a custom phase graph at sprint start.

### Phase source resolution

`cmd_start` picks the graph in this order (highest priority first):

1. `--phases <json>` — inline JSON array passed on the command line.
2. `--phases <path>` — path to a file containing a JSON array. Conductor reads the file when `<path>` is an existing file; otherwise it treats the value as inline JSON.
3. `phase_graph` field in `.nanostack/config.json`. Conductor reads this field directly with `jq`, validates it, and aborts sprint creation with exit `2` if the graph is malformed (cycle, duplicate name, dangling `depends_on`, or unknown name). Silently falling back to the default would mask a real config bug, so conductor stays fail-closed here. The registry's tolerant helper `nano_phase_graph_json` keeps its fallback semantics for other callers (resolver, future consumers); only the conductor needs the strict path.
4. `DEFAULT_PHASES` — the canonical seven-node sprint (`think → plan → build → review/qa/security → ship`). Reached only when no `--phases` flag was passed AND `.nanostack/config.json` has no `phase_graph` field.

### Validation

Before creating the sprint directory, `cmd_start` runs `_nano_phase_graph_is_valid` against the chosen graph. The validator rejects:

- Non-array structure or empty array.
- An entry whose `.name` is not a string or whose `.depends_on` is not an array of strings.
- A `.name` that fails the phase regex (`^[a-z][a-z0-9-]*$`).
- A `.name` that is not in the known set: core ∪ registered custom ∪ the conductor's `build` stage.
- A `.depends_on[]` entry that does not reference a name appearing elsewhere in the same graph.
- **Duplicate names** in the graph. Two entries with the same `.name` make `depends_on` ambiguous.
- **Cycles** in the dependency graph. Detected via Kahn's algorithm — if zero-deps node removal cannot reduce the graph to empty, a cycle exists.

A failed validation aborts with exit `2` and the message `ERROR: invalid phase graph (cycle, duplicate name, dangling depends_on, or unknown name)`. No sprint directory is created. Same behavior whether the graph came from `--phases` or `config.json`.

### Concurrency lookup

`cmd_batch`'s `get_concurrency` reads the `concurrency:` frontmatter field from a phase's `SKILL.md`. Lookup order:

1. Built-in core skill at `<nanostack_root>/<phase>/SKILL.md`.
2. Custom skill resolved via `nano_phase_skill_path`. Search order, most-specific to least: configured `skill_roots` from `.nanostack/config.json`, then `<store>/skills/` (where `<store>` comes from `bin/lib/store-path.sh` — the same path `bin/create-skill.sh` writes to), then `<config-dir>/skills/` (covers a global config under `$HOME/.nanostack/`), then the legacy cwd-relative `.nanostack/skills/`, then `$HOME/.claude/skills/` and `$HOME/.agents/skills/` for skills installed outside `.nanostack/`. The store-path-relative entries are the load-bearing ones: a scaffold from a git subdirectory or a no-git project lives in the resolved store, not under cwd.
3. Conductor-only `build` stage returns `write` (no SKILL.md).
4. Unknown phase falls back to `write` and emits a stderr warning. The conservative default avoids accidentally scheduling a custom write-phase as parallel-read.

### Stability

The output of `sprint.sh status` is keyed on phase names from the chosen graph. A custom graph that includes `audit-licenses` produces an `audit-licenses` entry under `.phases`, exactly as if it were a core phase. `sprint.sh batch` emits the same `{batch, type, phases}` JSON objects whether the phases are core, custom, or a mix.

## Tooling

`bin/create-skill.sh` scaffolds a custom skill and (by default) registers it as a custom phase in one shot.

```bash
bin/create-skill.sh license-audit --concurrency read --depends-on build
```

What it does:

- Validates the skill name against the registry's regex (`^[a-z][a-z0-9-]*$`) and rejects any name that collides with a core phase.
- Resolves the store path the same way every lifecycle script does (via `bin/lib/store-path.sh`): `$NANOSTACK_STORE` if set, otherwise the git repo root's `.nanostack/`, otherwise `$HOME/.nanostack/`. The skill lands at `<store>/skills/<name>/` and the registration is written to `<store>/config.json`. Same path that `save-artifact`, `resolve`, `analytics`, and `conductor` read from. A user invoking the tool from a git subdirectory writes to the repo root (not the subdir); a user without git writes to `$HOME/.nanostack/` (not the cwd).
- Copies the bundled template (`examples/custom-skill-template/audit-licenses` by default; override with `--from <dir>`).
- Substitutes the source skill name with `<name>` in `SKILL.md`, `agents/openai.yaml`, and `README.md`.
- Optionally rewrites the frontmatter `concurrency:` field (`--concurrency read|write|exclusive`) and `depends_on:` field (`--depends-on <phase>`, repeatable).
- Adds `<name>` to `.custom_phases` in `<store>/config.json`. Idempotent — already-present names are not duplicated. `--no-register` skips this step.

`bin/check-custom-skill.sh` validates a copied or scaffolded skill against the framework contract.

```bash
bin/check-custom-skill.sh .nanostack/skills/license-audit
```

What it checks:

- `SKILL.md` exists with `name:`, `description:`, and `concurrency:` frontmatter (`concurrency` must be `read`, `write`, or `exclusive`).
- The frontmatter `name:` matches the directory basename. A copied template that still says `name: audit-licenses` inside `license-audit/` would expose `/audit-licenses` to the agent — not what the user intended.
- `agents/openai.yaml` exists and contains `display_name`, `short_description`, `default_prompt` under `interface:`. The validator uses narrow grep checks instead of a YAML library so it stays portable on any machine with bash + jq + standard tools (no PyYAML or external runtime needed).
- The `display_name` references the new skill name, catching the same kind of drift in the OpenAI-discovery surface.
- Every `bin/*.sh` passes `bash -n`.
- The skill directory name matches the phase regex.
- The phase is registered in `<store>/config.json:custom_phases` so `save-artifact.sh` and `resolve.sh` accept it. `<store>` is resolved via `bin/lib/store-path.sh` — same path the scaffolder writes to.
- `SKILL.md` does not embed `./examples/custom-skill-template/...` paths (would break after copy).
- `save-artifact.sh` round-trips a smoke artifact and `find-artifact.sh` reads it back. The smoke artifact is removed after the check.

Output is one `OK` or `FAIL` line per check, ending in `OK: <name> passed N checks.` or `FAIL: <K> of <N> checks failed for <name>.`. Exit `0` on full pass, `1` on any failure.

## End-to-end coverage

`ci/e2e-custom-stack-flows.sh` runs the full new-user journey on a real `/tmp` project: scaffold → check → run helper → save → find → resolve → journal → analytics → discard → conductor start → conductor batch → openai.yaml present → no example-path leak → subdirectory scaffold → no-git scaffold → frontmatter-name drift rejected. Fifteen cells, thirty assertions. The `e2e-custom-stack` GitHub Actions job runs it on `workflow_dispatch`. When the harness is green, the framework claims in `README.md` and `EXTENDING.md` are grounded in working code.

## Stability

`phase_kind` is the load-bearing addition. Once shipped, downstream skills can branch on it. Future PRs may add new fields to the resolver output, but the existing shape stays — consumers should keep using `jq` field access rather than positional or shape-strict parsing.
