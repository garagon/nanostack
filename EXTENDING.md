# Extending Nanostack

Add your own skills that plug into nanostack's workflow. Your skills save artifacts, read what other skills produced, and compose with /think, /review and /ship.

## Configure your stack

nanostack has opinionated defaults for new projects (Next.js, Supabase, Drizzle, etc.). You can override any of them with your own preferences.

### Auto-detect from your project

```bash
bin/init-stack.sh
```

Reads package.json, go.mod, requirements.txt and generates `.nanostack/stack.json` with your detected stack. If nothing is detected, creates a template to edit.

### Global preferences (all projects)

```bash
bin/init-stack.sh --global
```

Saves to `~/.nanostack/stack.json`. Applies to every project where you don't have a project-level config.

### Manual config

Create `.nanostack/stack.json` in your project:

```json
{
  "web": {
    "framework": "Django",
    "auth": "django-allauth",
    "database": "PostgreSQL",
    "orm": "Django ORM",
    "hosting": "Railway",
    "css": "Tailwind + daisyUI"
  }
}
```

Only include categories you want to override. Everything else uses nanostack defaults.

### Priority order

1. `.nanostack/stack.json` (project) - highest
2. `~/.nanostack/stack.json` (user)
3. `plan/references/stack-defaults.md` (nanostack defaults) - fallback

If the project already has dependencies (package.json, go.mod, etc.), /nano uses the existing stack regardless of any config.

## Example: build a /deploy skill in 5 minutes

Let's create a skill that verifies a deploy after /ship creates the PR.

### 1. Create the skill file

```bash
mkdir -p ~/.claude/skills/nanostack/deploy
```

Create `deploy/SKILL.md`:

```yaml
---
name: deploy
description: Verify deploy health after shipping. Checks endpoint status, response times and error rates. Triggers on /deploy.
---

# /deploy - Post-deploy verification

After /ship creates the PR and it gets merged, verify the deploy is healthy.

## Process

### 1. Read the ship artifact

Find what was shipped:

bin/find-artifact.sh ship 2

Extract: PR number, branch, deploy URL (if available).

### 2. Health check

Run basic verification:

- Hit the main endpoint, confirm 200 status
- Check response time is under 500ms
- Look for error spikes in the last 5 minutes (if monitoring URL is available)

### 3. Report

Print a summary:

Deployed: PR #123
Endpoint: https://app.example.com
Status: 200 OK (142ms)
Errors: none detected

If anything fails, suggest rollback steps.

## Save Artifact

bin/save-artifact.sh deploy '<json with phase, summary including pr_number, endpoint, status_code, response_ms, errors>'

## Next Step

> Deploy verified. If issues appear later, run /deploy again to recheck.
```

### 2. Register the custom phase

So artifacts can be saved, add your phase to the project config:

```bash
# Create or update .nanostack/config.json in your project
cat > .nanostack/config.json << 'EOF'
{
  "custom_phases": ["deploy"]
}
EOF
```

### 3. Use it

```
You:    /ship
Agent:  PR #42 created. CI passed.

You:    /deploy
Agent:  Reading ship artifact... PR #42, branch feat/new-feature.
        Checking https://app.example.com...
        Status: 200 OK (142ms). No errors detected.
        Deploy healthy.
```

That's it. Your skill reads what /ship produced and acts on it. The artifact it saves can be read by future skills or included in the sprint journal.

## How it works

### Artifacts

Every skill saves a JSON file to `.nanostack/<phase>/<timestamp>.json`. This is how skills communicate:

```
/think  saves →  .nanostack/think/20260329-140000.json
/nano   saves →  .nanostack/plan/20260329-143000.json
/review saves →  .nanostack/review/20260329-150000.json
/deploy saves →  .nanostack/deploy/20260329-160000.json  ← your custom skill
```

### Reading other skills

Use `bin/find-artifact.sh` to read what another skill produced:

```bash
# Find the most recent ship artifact (max 2 days old)
bin/find-artifact.sh ship 2

# Find the most recent review artifact (max 30 days old)
bin/find-artifact.sh review 30
```

Returns the file path. Read it with `jq`:

```bash
ARTIFACT=$(bin/find-artifact.sh ship 2)
PR_NUMBER=$(jq -r '.summary.pr_number' "$ARTIFACT")
```

### Saving artifacts

Use `bin/save-artifact.sh` to persist your skill's output:

```bash
bin/save-artifact.sh deploy '{"phase":"deploy","summary":{"pr_number":42,"status":"healthy","response_ms":142}}'
```

The script automatically adds: timestamp, project path, git branch.

### The flow

```
Your skill reads artifacts    →    Does its work    →    Saves its own artifact
     (find-artifact.sh)                                    (save-artifact.sh)
```

Any skill can read any other skill's artifact. This is how nanostack skills cross-reference: /review reads /security findings, /security reads /review findings. Your skills work the same way.

## Composing with nanostack

Your skills don't replace nanostack's workflow. They extend it. Common patterns:

### Before the sprint

Your skill runs before /think to gather context:

```
/research-market → /think → /nano → build → /review → /ship
```

Example: a `/research-market` skill that pulls competitor data. /think reads the research artifact to make better scope decisions.

### During the sprint

Your skill slots into the middle:

```
/think → /nano → build → /review → /your-skill → /ship
```

Example: a `/compliance` skill that checks regulatory requirements after review but before shipping.

### After the sprint

Your skill runs after /ship:

```
/think → /nano → build → /review → /ship → /deploy → /monitor
```

Example: the /deploy skill above, or a `/monitor` skill that watches error rates for 24 hours.

### Parallel with nanostack

Your skill runs alongside /review, /qa and /security:

```
/think → /nano → build ─┬─ /review
                        ├─ /qa
                        ├─ /security
                        └─ /your-skill   ← runs in parallel
                        └─ /ship
```

Example: a `/performance` skill that runs load tests while review and security run their checks.

## Examples by domain

### Marketing

```
marketing/
  audience/SKILL.md       → research target audience
  content-plan/SKILL.md   → plan content calendar
  campaign/SKILL.md       → design campaign structure
```

Config: `{"custom_phases": ["audience", "content-plan", "campaign"]}`

Workflow: `/think → /audience → /content-plan → /nano → build → /review → /ship`

/audience saves audience research. /content-plan reads it and creates a content calendar. /nano plans the implementation. Standard nanostack skills handle the rest.

### DevOps

```
devops/
  deploy/SKILL.md         → post-deploy verification
  monitor/SKILL.md        → watch error rates after deploy
  rollback/SKILL.md       → automated rollback on failure
```

Config: `{"custom_phases": ["deploy", "monitor", "rollback"]}`

Workflow: `/ship → /deploy → /monitor`

/deploy reads the ship artifact, checks endpoint health. /monitor watches for 24 hours. /rollback triggers if error rates spike.

### Data Science

```
data/
  explore/SKILL.md        → EDA and data profiling
  hypothesis/SKILL.md     → form and test hypotheses
  model/SKILL.md          → train and evaluate models
  validate/SKILL.md       → statistical validation
```

Config: `{"custom_phases": ["explore", "hypothesis", "model", "validate"]}`

Workflow: `/think → /explore → /hypothesis → /model → /validate → /review → /ship`

Each skill saves its findings. /validate reads what /model produced and runs statistical tests. /review checks the code quality of the pipeline.

### Design

```
design/
  research/SKILL.md       → user research and personas
  wireframe/SKILL.md      → low-fi wireframes
  prototype/SKILL.md      → interactive prototypes
  usability/SKILL.md      → usability testing
```

Config: `{"custom_phases": ["research", "wireframe", "prototype", "usability"]}`

Workflow: `/think → /research → /wireframe → /prototype → /usability → /nano → build → /review → /ship`

/think challenges the design brief. /research produces user personas. Each subsequent skill reads the previous one's artifact.

## SKILL.md format

Every skill needs a `SKILL.md` with this structure:

```yaml
---
name: my-skill
description: One line. When to use it. Triggers on /my-skill.
---

# /my-skill - Short title

What this skill does in one paragraph.

## Process

### 1. First step
What to do.

### 2. Second step
What to do next.

## Save Artifact

bin/save-artifact.sh my-skill '<json>'

## Next Step

> What to run next.
```

The `name` field is the slash command. The `description` is what the agent reads to decide when to trigger the skill.

## API Reference

### bin/save-artifact.sh

```bash
bin/save-artifact.sh <phase> '<json>'
```

Saves to `.nanostack/<phase>/<timestamp>.json`. Validates JSON, checks phase is registered (core or custom). Adds timestamp, project, branch automatically.

### bin/find-artifact.sh

```bash
bin/find-artifact.sh <phase> [max-age-days]
```

Returns path to the most recent artifact for the phase. Default max age: 30 days. Exits 1 if not found.

### bin/sprint-journal.sh

```bash
bin/sprint-journal.sh
```

Reads all phase artifacts from today and writes a journal entry to `.nanostack/know-how/journal/`. Works with custom phases.

### bin/analytics.sh

```bash
bin/analytics.sh [--month YYYY-MM] [--json] [--obsidian]
```

Usage stats from all artifacts including custom phases.

### bin/capture-learning.sh

```bash
bin/capture-learning.sh "what you learned"
```

Appends to `.nanostack/know-how/learnings/ongoing.md`.

### bin/discard-sprint.sh

```bash
bin/discard-sprint.sh [--phase <name>] [--date YYYY-MM-DD] [--dry-run]
```

Removes artifacts from a bad session. Works with custom phases.

### .nanostack/config.json

```json
{
  "custom_phases": ["deploy", "monitor", "rollback"]
}
```

Register custom phases so `save-artifact.sh` accepts them. Without this, only the 6 core phases are accepted (think, plan, review, qa, security, ship).
