# Extending Nanostack

Build your own skill set on top of nanostack. Add domain-specific skills that integrate with the existing sprint workflow.

## How it works

Nanostack provides the engineering workflow: think, plan, build, review, test, audit, ship. Your skill set adds domain-specific phases that plug into this workflow.

Example: a marketing team builds "nanomarketing" with `/audience`, `/content-plan`, `/campaign` skills. These use nanostack's `/think` for ideation and `/ship` for deployment, but add marketing-specific phases in between.

## Create a new skill set

### 1. Create your skill directory

```bash
mkdir -p ~/.claude/skills/my-skillset
cd ~/.claude/skills/my-skillset
```

### 2. Create a skill

Each skill is a directory with a `SKILL.md`:

```
my-skillset/
  audience/
    SKILL.md
  content-plan/
    SKILL.md
  setup
  README.md
```

Skill format (same as nanostack):

```yaml
---
name: audience
description: Research and define target audience for a product or campaign. Triggers on /audience.
---

# /audience — Audience Research

Instructions for the agent...

## Save Artifact

bin/save-artifact.sh audience '<json with phase, summary>'

## Next Step

> Ready for `/content-plan`.
```

### 3. Register custom phases

To save artifacts for your custom phases, add them to `.nanostack/config.json`:

```json
{
  "custom_phases": ["audience", "content-plan", "campaign"]
}
```

Now `bin/save-artifact.sh audience '{...}'` works. Without this, only the 6 core phases (think, plan, review, qa, security, ship) are accepted.

### 4. Use nanostack's infrastructure

Your skills can use all of nanostack's bin/ scripts:

```bash
# Save an artifact for your custom phase
bin/save-artifact.sh audience '{"phase":"audience","summary":{"target":"developers","size":"50K"}}'

# Find an artifact from a previous phase
bin/find-artifact.sh think 2

# Read the project store path
source bin/lib/store-path.sh
echo $NANOSTACK_STORE

# Generate analytics
bin/analytics.sh --json

# Capture a learning
bin/capture-learning.sh "audience research showed X"
```

### 5. Compose with nanostack skills

Your workflow can call nanostack skills at any point:

```
/think → /audience → /content-plan → /nano → build → /review → /ship
```

Skills read each other's artifacts via `bin/find-artifact.sh`. If `/audience` saves an artifact, `/content-plan` can find and read it.

## API Reference

### bin/save-artifact.sh

```bash
bin/save-artifact.sh <phase> <json-string>
```

Saves a JSON artifact to `.nanostack/<phase>/<timestamp>.json`. Validates:
- JSON is parseable
- Has `phase` field matching the argument
- Has `summary` field
- Phase is in core phases or `custom_phases` from config

Automatically injects: `timestamp`, `project` path, `branch`.

### bin/find-artifact.sh

```bash
bin/find-artifact.sh <phase> [max-age-days]
```

Returns path to the most recent artifact for the given phase and current project. Exits 1 if none found. Default max age: 30 days.

### bin/lib/store-path.sh

```bash
source bin/lib/store-path.sh
```

Sets `$NANOSTACK_STORE` to the artifact directory. Priority:
1. `NANOSTACK_STORE` env var (explicit override)
2. `<git-root>/.nanostack` (project-local, default)
3. `$HOME/.nanostack` (fallback if not in a git repo)

### bin/sprint-journal.sh

```bash
bin/sprint-journal.sh [--project <name>]
```

Generates a journal entry from all core phase artifacts. Writes to `.nanostack/know-how/journal/<date>-<project>.md`.

### bin/analytics.sh

```bash
bin/analytics.sh [--month YYYY-MM] [--json] [--obsidian]
```

Usage stats from artifacts. Counts phases, intensity modes, security trends.

### bin/capture-learning.sh

```bash
bin/capture-learning.sh "what you learned"
```

Appends a timestamped learning to `.nanostack/know-how/learnings/ongoing.md`.

### bin/discard-sprint.sh

```bash
bin/discard-sprint.sh [--phase <name>] [--date YYYY-MM-DD] [--dry-run]
```

Removes artifacts from a bad session. Also removes journal entry.

## Artifact Schema

All artifacts share this base structure:

```json
{
  "schema_version": "1",
  "phase": "<your-phase-name>",
  "timestamp": "2026-03-27T14:30:00Z",
  "project": "/absolute/path/to/repo",
  "branch": "feature/auth",
  "summary": {}
}
```

The `summary` field is up to you. Design it for your domain. Other skills can read it via `find-artifact.sh` + `jq`.

Full schema for core phases: [`reference/artifact-schema.md`](reference/artifact-schema.md).

## Examples

### Marketing skill set

```
nanomarketing/
  audience/SKILL.md      → research target audience
  content-plan/SKILL.md  → plan content calendar
  campaign/SKILL.md      → design campaign structure
  measure/SKILL.md       → track campaign metrics
  setup                  → register skills + custom phases
  README.md
```

Config in `.nanostack/config.json`:
```json
{
  "custom_phases": ["audience", "content-plan", "campaign", "measure"]
}
```

### Data science skill set

```
nanodata/
  explore/SKILL.md       → EDA and data profiling
  hypothesis/SKILL.md    → form and test hypotheses
  model/SKILL.md         → train and evaluate models
  validate/SKILL.md      → statistical validation
  setup
  README.md
```

### Design skill set

```
nanodesign/
  research/SKILL.md      → user research and personas
  wireframe/SKILL.md     → low-fi wireframes
  prototype/SKILL.md     → interactive prototypes
  usability/SKILL.md     → usability testing
  setup
  README.md
```
