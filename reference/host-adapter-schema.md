# Host Adapter Schema

Each host that nanostack supports declares its real capabilities in a JSON file under `adapters/`. The schema is the contract between the workflow core (skills, doctor, setup, README) and the host (Claude Code, Cursor, Codex, OpenCode, Gemini, future).

The point is to stop overpromising. Setup, doctor, and the README must read these files before claiming "enforced" or "guarded" anywhere. If a host's adapter says `instructions_only`, the user-facing wording is "guided", not "enforced".

## File location

```
adapters/<host>.json
```

One file per host. Filename matches the `host` field. Existing host names: `claude`, `codex`, `cursor`, `opencode`, `gemini`.

## Schema (v1)

```json
{
  "host": "claude",
  "schema_version": "1",
  "last_verified": "2026-04-25",
  "verification": {
    "method": "ci|manual|unknown",
    "evidence": "path or command that proved the claim"
  },
  "skill_discovery": "native",
  "bash_guard": "enforced",
  "write_guard": "enforced",
  "phase_gate": "enforced",
  "install_target": ".claude/settings.json",
  "doctor_checks": ["hooks", "permissions", "commands"]
}
```

### Required fields

| Field | Type | Notes |
|---|---|---|
| `host` | string | Must match the filename without `.json`. |
| `schema_version` | string | Currently `"1"`. Bump on breaking schema changes. |
| `last_verified` | string (ISO date) | When a maintainer last confirmed the declared capabilities match the host. Stale dates lower trust; CI may downgrade displayed capability. |
| `verification` | object | How the claim was proved. See below. |
| `skill_discovery` | capability | How the host finds skills (see capability values). |
| `bash_guard` | capability | Enforcement level for shell commands. |
| `write_guard` | capability | Enforcement level for Write/Edit/MultiEdit. |
| `phase_gate` | capability | Enforcement level for the phase-aware commit gate. |
| `install_target` | string | The path setup writes the host's config to (advisory; for diagnostics). |
| `doctor_checks` | string[] | The check categories `nano-doctor` should run for this host. |

### `verification` field

```json
{
  "method": "ci",
  "evidence": ".github/workflows/lint.yml:guard-regression",
  "ci_jobs": ["guard-regression", "write-guard-regression"]
}
```

- `method`: one of `ci`, `manual`, `unknown`.
  - `ci` means CI runs a job that exercises the capability.
  - `manual` means a human ran a check and signed off; the evidence string should name the check or the commit.
  - `unknown` means nobody has confirmed; the host's claims must be conservative.
- `evidence`: short pointer to where the proof lives. A file path with optional anchor, a command, or a URL.
- `ci_jobs`: array of CI job names (the `jobs:` keys under `.github/workflows/`) that exercise the host's hooks. Required when any capability is `enforced` or `hooked` (see the evidence gate below). Each name must be a real job in a workflow that runs on every change, i.e. whose `on:` block includes `pull_request` or `push`. `bin/check-adapters.sh` rejects a name that is not such a job: a key that only appears under `on:` (e.g. `pull_request`), a job in a `workflow_dispatch`-only workflow, or a value with regex metacharacters. A hook that is only exercised when a maintainer manually runs a workflow is not continuous evidence and must not be listed here (mention it in `evidence` instead).

### Evidence gate for `enforced` and `hooked`

A capability value of `enforced` or `hooked` is a behavioral claim: it says a hook actually runs (and, for `enforced`, blocks). An enum value alone does not prove that. So `bin/check-adapters.sh` requires evidence:

- If `bash_guard`, `write_guard`, or `phase_gate` is `enforced` or `hooked`, the adapter must set `verification.method == "ci"` and a non-empty `verification.ci_jobs` array naming jobs that exist under `.github/workflows/`.
- An adapter cannot claim `enforced`/`hooked` on `verification.method == "manual"` or `unknown`, and cannot name a CI job that does not exist.

Today only Claude Code has hook CI, so only `adapters/claude.json` may claim `enforced`/`hooked` on those surfaces. Every other host stays at `instructions_only` (or whatever its real evidence supports) until a CI job proves otherwise.

### Capability values

| Value | Meaning | Wording |
|---|---|---|
| `unsupported` | The host cannot do this at all. | "Not available" |
| `instructions_only` | The host reads skill text and is expected to follow it; no programmatic gate. | "Guided" |
| `detectable` | Nanostack can inspect state and report issues, but cannot block. | "Checked" |
| `hooked` | The host invokes a nanostack hook before the action; the hook runs. | "Guarded" |
| `enforced` | The hook can block the action and the host honors the block. | "Blocked when unsafe" |
| `host_dependent` | Capability varies by host configuration that nanostack cannot detect. | Use only when the host config truly varies (e.g. browser QA depends on a desktop environment). |

The capability hierarchy maps directly to the L0..L4 levels in the V1 SPEC:

- `unsupported` and `instructions_only` are L0 ("Guided")
- `detectable` is L1 ("Checked")
- `hooked` is L2 ("Guarded")
- `enforced` is L3 ("Enforced")
- L4 ("Continuously verified") is not a capability value but a property of the `verification` block: when `method == "ci"`, the declared capability is L4-asserted.

This level-to-label vocabulary (L0 Guided, L1 Checked, L2 Guarded, L3 Enforced, L4 Continuously verified) is the single source of truth. The README L-level legend and the per-host matrix must use the same words; `bin/check-adapters.sh` parses this list and fails if they drift.

## Observation overrides declaration

The adapter file is a declaration, not eternal truth. A host upgrade can break the assumption.

The runtime contract:

1. `setup` and `nano-doctor` should observe the actual install state when feasible (file presence, `jq -e` over `.claude/settings.json`, version checks).
2. If observed state contradicts the adapter file, the runtime must report the **lower** capability and surface the discrepancy as a warning. It must never echo the file's value when the file is wrong.
3. The discrepancy should be actionable: prefer pointing the user at `init-project.sh --repair` over telling them to edit JSON.

## Guarantees that the schema must support

The first version of the schema covers the four guarantees that already exist in nanostack:

- skill discovery (the agent finds and invokes skills)
- bash guard (PreToolUse on shell commands)
- write guard (PreToolUse on Write/Edit/MultiEdit)
- phase gate (Bash hook that blocks commits before review/security/QA)

Subagent orchestration, browser QA, and other capabilities are intentionally **not** in v1. They get added when (and only when) a script or a doctor check actually consumes them. Adding capabilities without a consumer trains everyone to treat the schema as decoration.

## Adding a new host

1. Create `adapters/<host>.json` with conservative defaults (`instructions_only` for everything until proven otherwise).
2. Run the `setup --host <host>` flow on a real machine; observe whether hooks actually fire.
3. Update the adapter file with the observed value. Set `last_verified` to the date of observation. Set `verification.method` to `manual` and `verification.evidence` to the commit SHA or audit log line.
4. If a CI job can prove the capability, add it under `.github/workflows/`, then update `verification.method` to `ci` and point `evidence` at the job.
