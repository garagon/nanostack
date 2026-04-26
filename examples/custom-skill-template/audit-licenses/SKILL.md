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

### 1. Register the phase (first run only)

`save-artifact.sh` and the resolver only accept phases listed in `.nanostack/config.json`. Register `audit-licenses` once per project:

```bash
mkdir -p .nanostack
if [ -f .nanostack/config.json ]; then
  jq '.custom_phases = ((.custom_phases // []) + ["audit-licenses"] | unique)' \
    .nanostack/config.json > .nanostack/config.json.tmp \
    && mv .nanostack/config.json.tmp .nanostack/config.json
else
  printf '%s\n' '{"custom_phases":["audit-licenses"]}' > .nanostack/config.json
fi
```

Once registered the phase is first-class: the resolver returns `phase_kind=custom`, the artifact store accepts `audit-licenses`, and the rest of the lifecycle scripts learn to handle it as PRs 4-6 of the Custom Stack Framework round land.

### 2. Resolve context

Load whatever upstream context exists for this phase. The resolver knows about `audit-licenses` because step 1 registered it:

```bash
~/.claude/skills/nanostack/bin/resolve.sh audit-licenses
```

Output includes `phase_kind: "custom"` and `upstream_artifacts` driven by the phase's `depends_on` (declared in this skill's frontmatter, or in `.nanostack/config.json`'s `phase_graph` if you have one). Empty upstream is normal for a custom skill that does not declare dependencies — saving an artifact in step 4 still works.

### 3. Detect the stack and run the audit

Check what kind of project this is and read its dependency manifest. The helper lives next to this `SKILL.md`. Once the skill is copied into your agent's skills directory (see the README), call it with its absolute path:

```bash
SKILL_DIR="$HOME/.claude/skills/audit-licenses"
# Substitute the path your agent uses for skills if it differs.

if [ -f package.json ]; then
  "$SKILL_DIR/bin/audit.sh" node
elif [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  "$SKILL_DIR/bin/audit.sh" python
elif [ -f go.mod ]; then
  "$SKILL_DIR/bin/audit.sh" go
else
  echo "No supported manifest found (package.json, requirements.txt, pyproject.toml, go.mod)."
  exit 1
fi
```

The script prints a JSON block with `{ permissive: N, weak_copyleft: N, strong_copyleft: N, unknown: N, flagged: [...] }` plus a human-readable summary table.

### 4. Show the result and save the artifact

Show the user the summary first, then save an artifact so a future skill (or `/compound`) can read it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh audit-licenses \
  '{"phase":"audit-licenses","summary":{"flagged":[...],"counts":{...}},"context_checkpoint":{}}'
```

The artifact lives at `.nanostack/audit-licenses/<timestamp>.json`. Other skills can find it with `bin/find-artifact.sh audit-licenses 30`.

### 5. Headline

Close with one summary line, same format as the built-in skills:

```
[audit-licenses] OK: 47 deps scanned, 0 GPL/AGPL flagged.
```

Use `WARN` instead of `OK` when any GPL/AGPL dependency is flagged.

## Gotchas

- This skill only inspects manifest files. Transitive dependencies inside `node_modules/`, `vendor/`, or `.venv/` are not walked. For deep audits use a dedicated tool like `license-checker` (npm) or `pip-licenses`.
- "Permissive" here means MIT, BSD, Apache-2.0, ISC. "Weak copyleft" means LGPL, MPL. "Strong copyleft" means GPL, AGPL.
- Unknown licenses are not assumed permissive. They are flagged as `unknown` and the user decides.
