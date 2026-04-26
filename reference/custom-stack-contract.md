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

## Stability

`phase_kind` is the load-bearing addition. Once shipped, downstream skills can branch on it. Future PRs may add new fields to the resolver output, but the existing shape stays — consumers should keep using `jq` field access rather than positional or shape-strict parsing.
