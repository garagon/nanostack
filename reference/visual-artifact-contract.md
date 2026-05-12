# Visual Artifact Contract

## Purpose

`bin/render-artifact.sh` writes a static HTML view of a Nanostack JSON artifact, sprint journal, or custom stack DAG. The HTML is a derived, local, inspectable view of canonical evidence. JSON remains the source of truth; the renderer is strictly downstream.

This contract is normative for the Visual Artifacts v1 round (2026-05-11). It documents what the renderer produces, where it writes, what it refuses, and how downstream consumers must treat the output.

## Hard invariants

1. **JSON is canonical.** No skill (`/review`, `/security`, `/qa`, `/ship`, `bin/resolve.sh`, conductor) reads HTML as source evidence. HTML can be deleted and regenerated without changing sprint state.
2. **Deterministic.** Same source artifact + same renderer version produces semantically equivalent HTML and manifest. Only the manifest `created_at` and timestamp fields are allowed to vary.
3. **Local.** Output paths live under `$NANOSTACK_STORE/visual/`. The renderer refuses `--out` paths that escape the visual root and refuses to follow a symlinked visual root or any symlinked subdirectory under it.
4. **Trust-aware.** Every render records source trust. `--strict` rejects `integrity_missing` and `integrity_mismatch`. Without `--strict`, `integrity_mismatch` still fails (exit 3); `integrity_missing` renders with a visible untrusted badge.
5. **Escaped.** Every string read from JSON passes through `nano_html_escape` or `nano_attr_escape` before reaching HTML.
6. **Offline.** No external scripts, fonts, CSS, images, telemetry, or analytics. Static-mode CSP defaults to `default-src 'none'`. The interactive mode (see below) widens the policy to allow ONE inline script body, with strict allowlist enforcement.
7. **Interactive mode is copy-only.** When `--interactive` is passed for `/plan` or `/review`, the page emits three clipboard buttons (copy as prompt / Markdown / JSON patch). The inline script may use only `navigator.clipboard.writeText`. No `fetch`, no `XMLHttpRequest`, no `localStorage`, no `sessionStorage`, no `document.cookie`, no `eval`, no `new Function`, no `<form>`, no `document.write`, no `window.open`. Other phases reject `--interactive` with exit 1.

A consumer that depends on any of these invariants can read the manifest (see below) to confirm the render produced today's contract.

## CLI

```
bin/render-artifact.sh <phase> [artifact-path|--latest] [--strict]
                               [--interactive] [--out <path>]
                               [--manifest-only]

bin/render-artifact.sh journal [--today|--date YYYY-MM-DD]

bin/render-artifact.sh stack [<name>] [--strict] [--manifest-only]
```

| Form | Behavior |
|------|----------|
| `<phase> --latest` | Resolve source via `bin/find-artifact.sh <phase> 30 --no-session-sync`. The `30` is the max-age window in days; artifacts older than 30 days are treated as not found and the render exits 1 with "no `<phase>` artifact found in the last 30 days". Pass an explicit `<artifact-path>` instead to render an older file. |
| `<phase> <artifact-path>` | Render the explicit file. Phase mismatch fails with exit 1. |
| `<phase>` with no artifact argument | Equivalent to `<phase> --latest`. |
| `journal --today` | Aggregate every registered phase artifact for today's date into a sprint timeline. |
| `journal --date YYYY-MM-DD` | Same shape, restricted to the requested date. Filename prefix filter; no 30-day fallback. |
| `journal` (no flag) | Defaults to today's UTC date. |
| `stack <name>` | Render a custom workflow DAG. Looks up `$NANOSTACK_STORE/stacks/<name>/stack.json` first (user-installed), then `examples/custom-stack-template/<name>/stack.json` as a bundled-example fallback. A user-installed stack with the same name as a bundled example always wins. |
| `stack default` | Falls back to `.nanostack/config.json`'s `phase_graph` when no named stack file is found. Any other unknown name renders a "Stack not found" notice rather than falling back. |

| Flag | Behavior |
|------|----------|
| `--latest` | Resolve source with `find-artifact.sh --no-session-sync`. |
| `--strict` | Require `nano_artifact_trust == verified` for the source artifact (phase renders) or for every aggregated source (journal / stack). Aggregate strict mode allows `missing` (a phase not run yet) but rejects `integrity_missing` and `integrity_mismatch`. |
| `--interactive` | Enable copy-only clipboard buttons. Supported only for `/plan` and `/review`. Exit 1 elsewhere. |
| `--out <path>` | Write HTML to explicit path. Path must lexically normalize under `$NANOSTACK_STORE/visual/` and may not traverse a symlinked directory. The leaf file may not pre-exist as a symlink or directory. |
| `--manifest-only` | Write manifest only. The strict check still runs first, so a malformed source still produces exit 3. |

| Exit | Meaning |
|------|---------|
| 0 | Render succeeded. Output path printed to stdout. |
| 1 | Input error: missing artifact, invalid JSON, phase mismatch, unsupported phase, malformed stack name, `--interactive` requested outside `/plan` and `/review`. |
| 3 | Trust failure (`integrity_mismatch` always; `integrity_missing` only under `--strict`). For `journal --strict` and `stack --strict`, the check runs BEFORE the `--manifest-only` early exit so neither path can ship a `"strict": true` manifest while an aggregated source is tampered. |
| 4 | Unsafe output path: outside the visual root, symlinked subdirectory, symlinked leaf, directory at leaf, or symlinked visual root. Also returned when `mktemp` fails to create the HTML temp, the manifest temp, or the per-render scratch directory (treated as an unsafe-environment signal, not retried). |

## Store layout

```
$NANOSTACK_STORE/visual/
  <phase>/                       core phase HTML (plan, think, review, security, qa, ship)
  custom/<phase>/                reserved for custom phase HTML (helper exists,
                                 no caller wires it in v1)
  journal/                       sprint journal HTML
  stack/<name>/                  custom stack DAG HTML
  manifests/                     companion manifest JSON for every render
```

The `custom/<phase>/` path is generated by `nano_visual_output_dir <phase> true` but no v1 render-artifact.sh code path passes `true`. Treat it as plumbing reserved for a future PR that wires per-render dispatch for custom phases.

Filename format:

- Phase HTML: `YYYYMMDD-HHMMSS-<pid>-<phase>.html`
- Journal HTML: `YYYYMMDD-HHMMSS-<pid>-journal-<date>.html`
- Stack HTML: `YYYYMMDD-HHMMSS-<pid>-stack-<name>.html`
- Manifest: matching stem with `.manifest.json` suffix, under `manifests/`

The PID suffix prevents collisions between same-second renders.

Filename stems are NOT stable across renders. Every render produces a fresh `YYYYMMDD-HHMMSS-<pid>` stem, so a consumer that bookmarks the URL to an HTML file loses the reference on the next render. The stable identity lives in the JSON artifact path and the SHA-256 integrity, both of which are reproduced in the manifest. Consumers that need a "latest" entry point should re-render or read the most recent manifest by `created_at`.

## Manifest schema

Every render writes a companion manifest. Schema version `1`:

```json
{
  "schema_version": "1",
  "kind": "phase|journal|stack",
  "phase": "plan|think|review|security|qa|ship|journal|stack",
  "custom_phase": false,
  "format": "html",
  "interactive": false,
  "strict": true,
  "source_artifacts": [
    {
      "phase": "plan",
      "path": "/absolute/path/.nanostack/plan/20260511-180000.json",
      "integrity": "sha256-hex",
      "trust": "verified"
    }
  ],
  "output_path": "/absolute/path/.nanostack/visual/plan/20260511-180100-12345-plan.html",
  "renderer": {
    "name": "nanostack-html-renderer",
    "version": "1"
  },
  "schema_valid": true,
  "schema_error": null,
  "created_at": "2026-05-11T18:01:00Z"
}
```

Validation rules:

- `schema_version` equals `"1"`.
- `format` equals `"html"`.
- `kind` is one of `phase`, `journal`, `stack`.
- `phase` records the kind that was requested at the CLI: for phase renders this is `plan` / `think` / `review` / `security` / `qa` / `ship`; for `journal` renders it is the literal `journal`; for `stack` renders it is the literal `stack`. The stack name (e.g. `compliance-release`) is not part of `phase`; it lives in the synthetic `stack:<name>` entry in `source_artifacts`.
- `source_artifacts` length is at least 1. Phase renders have one entry; journal aggregates every registered phase; stack renders include the stack definition file (or `.nanostack/config.json` for `stack default`) as the first source, plus one entry per phase.
- `output_path` is absolute and under `$NANOSTACK_STORE/visual/`.
- `renderer.version` is present.
- `interactive` is `true` only for `/plan` and `/review` renders with `--interactive`.

Even failure modes ("Stack invalid", "Stack not found") produce a manifest with a synthetic `stack:<name>` source so downstream consumers always see at least one entry.

## HTML safety contract

Every generated HTML document includes:

- `<!doctype html>`.
- `<meta charset="utf-8">`.
- `<meta name="viewport" content="width=device-width, initial-scale=1">`.
- Static-mode CSP: `default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`.
- Interactive-mode CSP: same as static plus `script-src 'unsafe-inline'`.
- A `<title>` of the form `Nanostack /<phase> visual artifact`.
- A `<main>` element with `data-nanostack-visual="1"` and `data-phase="<phase>"`.
- A trust badge element with `data-trust="<status>"`.
- A provenance footer with `data-testid="visual-provenance"`, source artifact path (`data-testid="source-artifact-path"`), and manifest path (`data-testid="visual-manifest-path"`).

Forbidden in any generated template or rendered output:

- External URLs (`http://`, `https://`) except inside the locked `nano_visual_safe_pr_url` allowlist for `/ship` PR links and the SVG XML namespace identifier.
- `<script src=...>`, `fetch(`, `XMLHttpRequest`, `navigator.sendBeacon`.
- `localStorage`, `sessionStorage`, `document.cookie`.
- `eval(`, `new Function(`.
- `<form>`, `document.write`, `window.open`.

The interactive inline script body is allowed to use `navigator.clipboard.writeText` only. CI enforces the forbidden list against `bin/render-artifact.sh`, `bin/lib/visual-render.sh`, and `bin/lib/html-escape.sh` via `ci/check-visual-artifact-templates.sh`. The lint runs grep-style absence checks for each forbidden API plus a presence check that the script body sources `navigator.clipboard.writeText` exactly. Any new clipboard / network / storage / DOM-mutation API in the interactive path requires updating both the contract and the lint.

## Escape helpers

`bin/lib/html-escape.sh` exposes:

- `nano_html_escape` — escape text content. Replaces `& < > " '` with named/numeric entities. Preserves newlines.
- `nano_attr_escape` — escape attribute content. Same character set, stricter.
- `nano_json_string` — escape a string for safe inclusion in a JSON literal (used by the manifest writer).

Every JSON-derived string MUST pass through one of these. Fixed template HTML (page shell, table headers, button labels) may be written directly.

### Reserved helpers (defined, not wired in v1)

`bin/lib/visual-render.sh::nano_visual_safe_screenshot_path` is an allowlist for QA screenshot rendering: it accepts absolute paths under the project or `$NANOSTACK_STORE`, rejects `..` traversal, absolute URLs (`http://`, `https://`, `data:`, `javascript:`, `file://`), and any path containing `<`, `>`, or `"`. The helper is defined so a future PR wiring `/qa` screenshot galleries can reuse it without re-deriving the allowlist. v1 does NOT render screenshots, so calling the helper from a render path is a contract change that requires updating this document and the CI lint.

For interactive mode, an additional transform in `render-artifact.sh::_js_safe_for_script` encodes every `<` in JS-embedded JSON payloads as `<` so the HTML parser cannot exit the script body via `<!--<script>`, `</script>`, or `<!CDATA[` sequences. `JSON.parse` reads `<` as the literal `<`, so the clipboard payload the user pastes is unchanged.

## Trust badge wording

| Status | Badge text |
|--------|-----------|
| `verified` | `verified` |
| `integrity_missing` | `unverified` |
| `integrity_mismatch` | This status never reaches the badge: the render exits 3 before HTML is written. |
| `not_applicable` | `aggregated` (used by journal and stack views, which surface per-source trust inline). |
| `not_found` | This status never reaches the badge: the render exits 1 before HTML is written. |

The wording is locked. A renderer that prints other strings for these statuses fails `ci/check-visual-artifact-templates.sh`.

## Multi-store trust scope

In a project-local store (`$(git rev-parse --show-toplevel)/.nanostack`), the journal and stack renderers surface tampered same-day artifacts even when `.project` was flipped. The integrity hash is the authoritative signal because no one else writes to the project repo's `.nanostack/` directory.

In a shared store (for example `$HOME/.nanostack` used across projects), the renderers require `.project` to match the current project before surfacing tamper. This avoids false positives from other projects' tampered or legacy artifacts.

The store-local check uses `realpath` so a macOS `/tmp` → `/private/tmp` symlink does not produce a false mismatch.

## Stack graph validation

`stack` renders accept a `phase_graph` only if all of the following hold:

- It is a non-empty array of objects.
- Each entry has a non-empty string `.name` and an array-of-string `.depends_on`.
- Names match `^[A-Za-z0-9_-]+$` (no whitespace, no path separators).
- Names are unique.
- Every name in any `.depends_on` exists as a declared node (no dangling references).
- The graph is acyclic (Kahn-style topological pass; rounds capped at `node_count + 1`). When a cycle is detected, the "Stack invalid" notice names every unresolved node so the user can identify the cycle without re-running with a debugger.

A graph that fails any check produces a "Stack invalid" notice with the specific reason. The manifest still writes with a synthetic source pointing at the stack file.

## Relationship to existing primitives

- Trust state comes from `bin/lib/artifact-trust.sh::nano_artifact_trust`. The renderer never reimplements integrity checks.
- Source artifact resolution for phase renders uses `bin/find-artifact.sh --no-session-sync` so the renderer never mutates `session.json`.
- Journal date filtering uses a filename prefix sort (matches `save-artifact.sh`'s `YYYYMMDD-HHMMSS.json` convention), not file mtime.
- Schema validation uses `bin/lib/artifact-schemas.sh::nano_validate_artifact`. A source artifact that fails schema validation is rendered with a visible "schema invalid" notice rather than failing the render; the manifest records the source trust and an HTML data-testid marks the warning.
- Store path comes from `bin/lib/store-path.sh::NANOSTACK_STORE`.
- Phase registry comes from `bin/lib/phases.sh::nano_all_phases` and `nano_phase_graph_json`. Custom phases declared in `.nanostack/config.json` appear in the journal timeline and the `stack default` fallback.
- No skill, conductor command, or guard hook reads the HTML output. The renderer is strictly downstream.

## Determinism and atomicity

- Writes go through `mktemp "$path.tmp.XXXXXX"` (O_EXCL) and rename into place after the render and manifest both succeed.
- Temporary files and the per-render scratch directory are removed on trap.
- The renderer prints exactly one line to stdout on success: the absolute HTML output path. Errors go to stderr.
- Same-second renders never collide on manifest paths because the timestamp includes the PID.
- Lexical path normalization (`nano_visual_normalize_path`) defeats `..` escape and symlink-then-up attacks before any filesystem write.
