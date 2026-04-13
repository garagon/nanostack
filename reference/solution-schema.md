# Solution Document Schema

Solutions persist in `.nanostack/know-how/solutions/` organized by type.

## Directory structure

```
.nanostack/know-how/solutions/
├── bug/           problems encountered and solved
├── pattern/       recurring patterns worth remembering
└── decision/      architecture or design decisions with rationale
```

## YAML frontmatter

All solutions share these fields:

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| type | Yes | `bug`, `pattern`, `decision` | Category of the solution |
| title | Yes | string | Short description, used for search |
| date | Yes | YYYY-MM-DD | When the solution was captured |
| project | Yes | string | Project name (auto-detected) |
| files | No | string[] | File paths involved |
| tags | No | string[] | Keywords for search |
| severity | No | `critical`, `high`, `medium`, `low` | Impact level |
| validated | No | boolean | Whether the solution has been confirmed to work |
| last_validated | No | YYYY-MM-DD | Last date the solution was applied and confirmed |
| applied_count | No | integer | Number of sprints that applied this solution |
| graduated | No | boolean | Whether the solution has been promoted into a SKILL.md file |
| graduated_to | No | string | Target skill file (e.g., `review/SKILL.md`) if graduated |

### Graduation

Solutions with `applied_count >= 3`, `validated: true`, `last_validated` within 60 days, and existing referenced files are eligible for graduation. `bin/graduate.sh` scans solutions and proposes insertions into SKILL.md files' `## Graduated Rules` sections.

Once graduated, a solution is marked `graduated: true` and `graduated_to: <skill>/SKILL.md`. The solution is NOT deleted — it retains the full history. The graduated rule is a compressed version baked into the skill for zero-lookup access.

Caps: review (10 rules), plan (8 rules), security (8 rules).

## Body sections by type

### Bug

```markdown
## Problem
What was wrong. One paragraph.

## Symptoms
How this manifested. What errors, what behavior.

## What didn't work
Approaches tried and discarded, with why they failed.

## Solution
What fixed it. Include code if relevant.

## Why this works
The underlying cause and why the fix addresses it.

## Prevention
How to avoid this class of problem in the future.
```

### Pattern

```markdown
## Context
When this pattern applies.

## Pattern
The pattern itself. What to do.

## When to apply
Specific triggers or conditions.

## Example
Concrete code or configuration example.

## When NOT to apply
Conditions where this pattern would be wrong.
```

### Decision

```markdown
## Context
What prompted this decision.

## Decision
What was decided.

## Rationale
Why this option was chosen over alternatives.

## Alternatives considered
Other options evaluated and why they were rejected.

## Consequences
What this decision means going forward. Trade-offs accepted.
```

## Search

Solutions are searched by `bin/find-solution.sh`:

```bash
# Search by keyword (matches title, tags, body)
bin/find-solution.sh "stripe webhook"

# Filter by type
bin/find-solution.sh "auth" --type bug

# Filter by tag
bin/find-solution.sh --tag security

# Filter by file
bin/find-solution.sh --file src/api/webhooks
```

All query words must match (AND logic). Search is case-insensitive.

## Creating solutions

Solutions are created by `bin/save-solution.sh`:

```bash
bin/save-solution.sh bug "Stripe webhook missing signature" "stripe,webhooks,security"
```

Returns `created:<path>` for new files or `exists:<path>` if a solution with the same title already exists. The agent fills in the body sections after creation.

## Integration with skills

### /compound (writes solutions)
Reads sprint artifacts, identifies solved problems, creates solution documents.

### /nano (reads solutions)
Before planning, searches solutions for past knowledge related to the technologies and files in scope.

### /review (reads solutions)
Before reviewing, searches solutions related to the files changed. Checks if current code follows known resolutions.
