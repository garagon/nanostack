# Think Brief Template

Used by `/think` Phase 6.5 to write a shareable markdown brief to `.nanostack/know-how/briefs/YYYY-MM-DD-<slug>.md` (slug derived from the value proposition).

This is a human-readable document the user can share with a team, paste into a doc, or open in Obsidian. It is **not** the JSON artifact (that is saved separately by `save-artifact.sh`).

## Format

```markdown
# Think Brief: <value proposition short title>

**Date:** YYYY-MM-DD
**Mode:** Startup / Builder / Founder
**Scope:** Expand / Hold / Reduce

## Value Proposition
<one sentence>

## Target User
<who specifically, and why they'd use a broken v1>

## Starting Point
<the smallest thing that delivers value>

## Key Risk
<the one thing most likely to make this fail>

## What We Decided NOT to Build
<out of scope items from the diagnostic>

## Premise
<validated or not — and the argument that tested it>
```

## Rules

- Keep it under 20 lines total.
- No filler, no headers without content.
- Skip sections that don't apply (e.g., omit "What We Decided NOT to Build" if nothing was excluded).
- The slug is derived from the value proposition: lowercase, hyphenated, max ~5 words.

## Retro briefs

For `/think --retro`, write to `.nanostack/know-how/briefs/YYYY-MM-DD-retro.md` with the retro output (Sprint, Shipped, Right problem?, Surprises, Recurring patterns, Recommendation). Same directory, different filename pattern.
