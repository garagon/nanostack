---
name: audit-licenses
description: Use to list the open-source licenses of every dependency in this project, grouped by license family. Flags GPL or AGPL dependencies that may force the project itself to be open-source. Triggers on /audit-licenses.
concurrency: read
depends_on: []
summary: "License compliance check across npm/pip/go dependencies."
estimated_tokens: 180
---

# /audit-licenses — Dependency License Audit

You audit the open-source licenses of this project's dependencies. The point is compliance: some licenses (GPL, AGPL) force the project that uses them to be open-source under the same terms. The team needs to know that before shipping.

This is an example custom skill. It shows the patterns every nanostack-compatible skill follows: detect the project, do the work, save an artifact so future skills can read it.

## Process

### 1. Resolve context

Other phases may have run before this one. Load whatever upstream context exists:

```bash
~/.claude/skills/nanostack/bin/resolve.sh audit-licenses
```

The resolver does not have a routing rule for `audit-licenses` so this returns minimal output. That is fine. Custom skills can still use the artifact store (see step 3) and the conductor (see `/conductor`).

### 2. Detect the stack and run the audit

Check what kind of project this is and read its dependency manifest. Cover the three common stacks:

```bash
if [ -f package.json ]; then
  ./examples/custom-skill-template/audit-licenses/bin/audit.sh node
elif [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  ./examples/custom-skill-template/audit-licenses/bin/audit.sh python
elif [ -f go.mod ]; then
  ./examples/custom-skill-template/audit-licenses/bin/audit.sh go
else
  echo "No supported manifest found (package.json, requirements.txt, pyproject.toml, go.mod)."
  exit 1
fi
```

The script prints a JSON block with `{ permissive: N, weak_copyleft: N, strong_copyleft: N, unknown: N, flagged: [...] }` plus a human-readable summary table.

### 3. Show the result and save the artifact

Show the user the summary first, then save an artifact so a future skill (or `/compound`) can read it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh audit-licenses \
  '{"phase":"audit-licenses","summary":{"flagged":[...],"counts":{...}},"context_checkpoint":{}}'
```

The artifact lives at `.nanostack/audit-licenses/<timestamp>.json`. Other skills can find it with `bin/find-artifact.sh audit-licenses 30`.

### 4. Headline

Close with one summary line, same format as the built-in skills:

```
[audit-licenses] OK: 47 deps scanned, 0 GPL/AGPL flagged.
```

Use `WARN` instead of `OK` when any GPL/AGPL dependency is flagged.

## Gotchas

- This skill only inspects manifest files. Transitive dependencies inside `node_modules/`, `vendor/`, or `.venv/` are not walked. For deep audits use a dedicated tool like `license-checker` (npm) or `pip-licenses`.
- "Permissive" here means MIT, BSD, Apache-2.0, ISC. "Weak copyleft" means LGPL, MPL. "Strong copyleft" means GPL, AGPL.
- Unknown licenses are not assumed permissive. They are flagged as `unknown` and the user decides.
