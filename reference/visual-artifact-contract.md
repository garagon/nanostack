# Visual Artifact Contract

## Purpose

`bin/render-artifact.sh` writes a static HTML view of a Nanostack JSON artifact. The HTML is a derived, local, inspectable view of the canonical artifact. JSON remains the source of truth; the renderer is strictly downstream.

This contract is normative for PR 1 of the Visual Artifacts Architecture v1 round (2026-05-11). It documents what the renderer produces, where it writes, what it refuses, and how downstream consumers must treat the output.

## Hard invariants

1. **JSON is canonical.** No skill (`/review`, `/security`, `/qa`, `/ship`, `bin/resolve.sh`, conductor) reads HTML as source evidence. HTML can be deleted and regenerated without changing sprint state.
2. **Deterministic.** Same source artifact + same renderer version produces semantically equivalent HTML and manifest. Only the manifest `created_at` field is allowed to vary.
3. **Local.** Output paths live under `$NANOSTACK_STORE/visual/`. The renderer refuses `--out` paths that escape the visual root and refuses to follow a symlinked visual root.
4. **Trust-aware.** Every render records source trust. `--strict` rejects `integrity_missing` and `integrity_mismatch`. Without `--strict`, `integrity_mismatch` still fails (exit 3); `integrity_missing` renders with a visible untrusted badge.
5. **Escaped.** Every string read from JSON passes through `nano_html_escape` or `nano_attr_escape` before reaching HTML.
6. **Offline.** No external scripts, fonts, CSS, images, telemetry, or analytics. CSP defaults to `default-src 'none'`. Static mode forbids inline script.
7. **Interactive mode is copy-only.** Reserved for PR 4. PR 1 rejects `--interactive` with exit 2.

A consumer that depends on any of these invariants can read the manifest (see below) to confirm the render produced today's contract.

## CLI

```
bin/render-artifact.sh <phase> [artifact-path|--latest] [--strict] [--interactive] [--out <path>] [--manifest-only]
```

| Form | Behavior |
|------|----------|
| `<phase> --latest` | Resolve source via `bin/find-artifact.sh <phase> 30`. |
| `<phase> <artifact-path>` | Render the explicit file. Phase mismatch fails with exit 1. |
| `<phase>` with no artifact argument | Equivalent to `<phase> --latest`. |
| `journal --today` | Reserved for PR 3. Exit 2 in PR 1. |
| `stack <name>` | Reserved for PR 3. Exit 2 in PR 1. |

| Flag | Behavior |
|------|----------|
| `--latest` | Resolve source with `find-artifact.sh`. |
| `--strict` | Require `nano_artifact_trust == verified`. |
| `--interactive` | Reserved for PR 4. Exit 2 in PR 1. |
| `--out <path>` | Write HTML to explicit path. Path must be inside `$NANOSTACK_STORE/visual/`. |
| `--manifest-only` | Write manifest only. Useful for CI trust checks. |

| Exit | Meaning |
|------|---------|
| 0 | Render succeeded. Output path printed to stdout. |
| 1 | Input error: missing artifact, invalid JSON, phase mismatch, unsupported phase. |
| 2 | Feature intentionally unsupported in current PR. |
| 3 | Trust failure (`integrity_mismatch` always; `integrity_missing` only under `--strict`). |
| 4 | Unsafe output path or symlinked visual root. |

## Store layout

```
$NANOSTACK_STORE/visual/
  <phase>/                       core phase HTML (plan, think, review, security, qa, ship)
  custom/<phase>/                custom phase HTML
  journal/                       sprint journal HTML
  manifests/                     companion manifest JSON for every render
```

Filename format:

- HTML: `YYYYMMDD-HHMMSS-<phase>.html`
- Core manifest: `YYYYMMDD-HHMMSS-<phase>.manifest.json`
- Custom manifest: `YYYYMMDD-HHMMSS-custom-<phase>.manifest.json`

## Manifest schema

Every render writes a companion manifest. Schema version `1`:

```json
{
  "schema_version": "1",
  "kind": "phase",
  "phase": "plan",
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
  "output_path": "/absolute/path/.nanostack/visual/plan/20260511-180100-plan.html",
  "renderer": {
    "name": "nanostack-html-renderer",
    "version": "1"
  },
  "created_at": "2026-05-11T18:01:00Z"
}
```

Validation rules:

- `schema_version` equals `"1"`.
- `format` equals `"html"`.
- `kind` is one of `phase`, `journal`, `stack`.
- `source_artifacts` length is at least 1; each entry has `phase`, `path`, `trust`.
- `output_path` is absolute and under `$NANOSTACK_STORE/visual/`.
- `renderer.version` is present.

## HTML safety contract

Every generated HTML document includes:

- `<!doctype html>`.
- `<meta charset="utf-8">`.
- `<meta name="viewport" content="width=device-width, initial-scale=1">`.
- A static-mode CSP: `default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`.
- A `<title>` of the form `Nanostack /<phase> visual artifact`.
- A `<main>` element with `data-nanostack-visual="1"` and `data-phase="<phase>"`.
- A trust badge element with `data-trust="<status>"`.
- A provenance footer with `data-testid="visual-provenance"`, source artifact path (`data-testid="source-artifact-path"`), and manifest path (`data-testid="visual-manifest-path"`).

Forbidden in any generated template or rendered output:

- External URLs (`http://`, `https://`).
- `<script src=...>`, `fetch(`, `XMLHttpRequest`, `navigator.sendBeacon`.
- `localStorage`, `sessionStorage`, `document.cookie`.
- `eval(`, `new Function(`.

CI enforces the forbidden list against `bin/render-artifact.sh` and `bin/lib/visual-render.sh` via `ci/check-visual-artifact-templates.sh`.

## Escape helpers

`bin/lib/html-escape.sh` exposes:

- `nano_html_escape` — escape text content. Replaces `& < > " '` with named/numeric entities. Preserves newlines.
- `nano_attr_escape` — escape attribute content. Same character set, stricter.
- `nano_json_string` — escape a string for safe inclusion in a JSON literal (used by the manifest writer).

Every JSON-derived string MUST pass through one of these. Fixed template HTML (page shell, table headers, button labels) may be written directly.

## Trust badge wording

| Status | Badge text |
|--------|-----------|
| `verified` | `verified` |
| `integrity_missing` | `unverified` |
| `integrity_mismatch` | This status never reaches the badge: the render exits 3 before HTML is written. |
| `not_found` | This status never reaches the badge: the render exits 1 before HTML is written. |

The wording is locked. A renderer that prints other strings for these statuses fails `ci/check-visual-artifact-templates.sh`.

## Relationship to existing primitives

- Trust state comes from `bin/lib/artifact-trust.sh::nano_artifact_trust`. The renderer never reimplements integrity checks.
- Source artifact resolution uses `bin/find-artifact.sh` for `--latest` and accepts an explicit path otherwise. The renderer parses the explicit path with `jq -e .` and verifies `.phase` matches the requested phase.
- Schema validation uses `bin/lib/artifact-schemas.sh::nano_validate_artifact`. A source artifact that fails schema validation is rendered with a visible "schema invalid" notice rather than failing the render; the manifest still records the source trust.
- Store path comes from `bin/lib/store-path.sh::NANOSTACK_STORE`.
- No skill, conductor command, or guard hook reads the HTML output. The renderer is strictly downstream.

## Determinism and atomicity

- Writes go to `<path>.tmp.$$` and rename into place after the render and manifest both succeed.
- Temporary files are removed on trap.
- The renderer prints exactly one line to stdout on success: the absolute HTML output path. Errors go to stderr.
