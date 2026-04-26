---
name: release-readiness
description: Use after review/qa/security/license-audit/privacy-check to compose a release decision before /ship. Returns OK only when all required upstream evidence is present and clean. Triggers on /release-readiness.
concurrency: read
depends_on: [review, qa, security, license-audit, privacy-check]
summary: "Composes core + custom release evidence into a single gate before /ship, part of the compliance-release stack."
estimated_tokens: 240
---

# /release-readiness — Release Decision Composer

You compose the sprint's release evidence into a single decision. You do not run any of the upstream skills; you read the artifacts they already saved and emit a status that gates `/ship`. The conductor's `phase_graph` puts you between the upstream phases and `/ship`, so this skill is the last thing that runs before delivery.

This is the `release-readiness` skill from the compliance-release stack. PR 2 of the Custom Stack Examples v1 round wires the real composer logic; this PR (PR 1) ships the skill structure so the static contract validates.

## Process

### 0. Resolve paths (host-agnostic)

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/release-readiness}"
```

### 1. Resolve upstream evidence

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
"$NANOSTACK_ROOT/bin/resolve.sh" release-readiness
```

The resolver returns `phase_kind: "custom"` and `upstream_artifacts` with five keys: `review`, `qa`, `security`, `license-audit`, `privacy-check`. Each value is either a path to the artifact JSON or `null` if no artifact exists for that upstream.

### 2. Compose the decision

```bash
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/release-readiness}"
"$SKILL_DIR/bin/summarize.sh"
```

The helper reads each upstream artifact through `bin/find-artifact.sh --verify` and maps each to a `check` entry. Per-check status:

- **`MISSING`** for any upstream whose artifact is absent.
- **`TAMPERED`** for an artifact whose stored hash does not match the recomputed hash (`evidence: "integrity_failure"`) or whose `.integrity` field is absent (`evidence: "missing_integrity"`). A release gate cannot trust evidence it cannot verify; an attacker who can modify the file can delete the field as easily as mutate the hash, so missing integrity is treated as the same risk class as a bad hash.
- **`BLOCKED`** when the upstream's `summary.status` is `BLOCKED`.
- **`WARN`** when the upstream's `summary.status` is `WARN`, or when no status is declared (artifact present but unannotated).
- **`OK`** when the upstream's `summary.status` is `OK` and integrity verifies.

Rollup is monotonic worst-case:

- Any `BLOCKED`, `TAMPERED`, or `MISSING` per-check entry forces the rollup to **`BLOCKED`**.
- Otherwise, any `WARN` per-check entry rolls up to **`WARN`**.
- Otherwise, **`OK`**.

### 3. Save the artifact

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
"$NANOSTACK_ROOT/bin/save-artifact.sh" release-readiness \
  '{"phase":"release-readiness","summary":{"status":"...","headline":"...","checks":[...],"next_action":"..."},"context_checkpoint":{"summary":"Release readiness composed upstream evidence."}}'
```

### 4. Headline

```
[release-readiness] BLOCKED: privacy note missing and QA evidence absent.
```

Prefix the status (`OK`, `WARN`, `BLOCKED`) and surface the most actionable next step. The composer's job is to tell the user **what to do**, not just to print a verdict.

## Gotchas

- This skill **never runs `/ship`**, never opens a PR, never commits, never deploys. It only composes evidence into a decision.
- Missing upstreams are explicit. If `qa` has no artifact, the rollup is `BLOCKED` for "QA evidence missing" (not `OK` with a quiet gap). The whole point of the gate is to surface that exactly.
- Tampered upstreams are explicit. An artifact whose stored hash does not match the recomputed content, or whose `.integrity` field is absent, becomes `TAMPERED` (not `OK`). A release gate cannot afford to trust evidence it cannot verify.
- The status rollup is monotonic: once any upstream is `BLOCKED`, `TAMPERED`, or `MISSING`, the composer cannot soften the rollup to `WARN`. The user must explicitly resolve the failure.
- `WARN` rollups still allow `/ship` (the composer does not auto-block), but the artifact records the warning and the next-action so the team has a paper trail.
