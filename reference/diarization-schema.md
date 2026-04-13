# Diarization Document Schema

Diarizations persist in `.nanostack/know-how/diarizations/` as structured intelligence briefs about a module, file, or concept. They synthesize scattered knowledge (git history, solutions, artifacts, code) into a single-page profile.

## Directory structure

```
.nanostack/know-how/diarizations/
├── api-webhooks.md          keyed by subject slug
├── auth-middleware.md
└── payment-processing.md
```

## YAML frontmatter

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| subject | Yes | string | The file path, directory, or concept being profiled |
| date | Yes | YYYY-MM-DD | When the diarization was last updated |
| files | Yes | string[] | File paths covered by this diarization |
| file_count | No | integer | Number of files analyzed |
| tags | No | string[] | Keywords for resolver matching |

## Body sections

```markdown
## Current State
What the module does, its size, last modification date.

## Ownership
Primary authors and recent contributors (from git log).

## What It Does vs What People Think It Does
- **Documented as:** what README/comments/docs say
- **Actually:** what the code spends most of its logic on
- **Gap:** where the documentation and reality diverge

## Recurring Issues
Aggregated from review/security/qa artifacts across sprints.
Each issue with frequency count and status (resolved/unresolved).

## Known Risks
Open risks flagged by /security or /review that were deferred or unresolved.

## Unresolved Tensions
Cross-skill conflicts (e.g., review says X, security says Y) that lack consistent resolution.

## Timeline
Key events in chronological order (PR merges, bug fixes, rewrites, audit findings).
```

## Lifecycle

- **Created by:** `/investigate --diarize <subject>` or explicitly by the user
- **Updated by:** re-running diarization on the same subject (body is rewritable)
- **Surfaced by:** `bin/resolve.sh` when changed files overlap with the diarization subject
- **Staleness:** the `date` field lets consumers decide trust. No hard TTL.

## Integration

- `bin/gather-subject.sh` does the deterministic gathering (files, git log, solutions, artifacts)
- The model reads the gathered sources and produces the structured synthesis (latent)
- `bin/resolve.sh` includes diarizations in its output when changed files overlap
- Skills decide whether to read a diarization based on age and relevance
