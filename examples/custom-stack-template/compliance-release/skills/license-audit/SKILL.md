---
name: license-audit
description: Use to audit the open-source licenses of every direct dependency in this project before shipping. Flags GPL/AGPL as BLOCKED, unknown as WARN. Triggers on /license-audit.
concurrency: read
depends_on: [build]
summary: "License compliance check across npm/pip/go dependencies, part of the compliance-release stack."
estimated_tokens: 200
---

# /license-audit — Dependency License Audit

You audit the open-source licenses of this project's dependencies. The point is compliance: some licenses (GPL, AGPL) force the project that uses them to be open-source under the same terms. This skill runs before `/release-readiness` so the gate has license evidence to compose.

This is the `license-audit` skill from the compliance-release stack. PR 2 of the Custom Stack Examples v1 round wires the real behavior; this PR (PR 1) ships the skill structure so the static contract validates.

## Process

### 0. Resolve paths (host-agnostic)

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/license-audit}"
```

Some agents (including Claude Code) execute each tool call in a fresh bash process, so each snippet redefines the env vars it uses.

### 1. Run the audit

```bash
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/license-audit}"
"$SKILL_DIR/bin/audit.sh"
```

The helper detects the project stack (npm, pip, go) from manifest files, classifies each direct dependency's license into a family (permissive, weak copyleft, strong copyleft, unknown), and prints a JSON object with counts and a `flagged` list.

### 2. Save the artifact

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
"$NANOSTACK_ROOT/bin/save-artifact.sh" license-audit \
  '{"phase":"license-audit","summary":{"status":"OK","headline":"...","counts":{...},"flagged":[]},"context_checkpoint":{"summary":"License audit completed.","key_files":["package.json"]}}'
```

Status rules:
- `OK` — every direct dependency has a known permissive or weak-copyleft license.
- `WARN` — at least one license is `unknown`. The composer in `/release-readiness` rolls this up.
- `BLOCKED` — at least one direct dependency is GPL or AGPL.

### 3. Headline

```
[license-audit] OK: 12 deps scanned, 0 GPL/AGPL flagged.
```

Use `WARN` or `BLOCKED` instead of `OK` when the status field above is not OK.

## Gotchas

- This skill walks **direct dependencies only**. Transitive dependencies are out of scope; pair with a deep auditor if your compliance bar requires that.
- "Unknown license" means the manifest declares the package but no license metadata is parseable from the manifest itself. Unknown is treated as `WARN`, not `OK`. The user decides whether to upgrade or replace.
- This skill never rewrites your code, edits package.json, or runs `npm install`. It is read-only.
