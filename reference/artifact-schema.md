# Artifact Schema

## Common fields

All artifacts share this base structure:

```json
{
  "schema_version": "1",
  "phase": "<think|plan|review|qa|security|ship>",
  "timestamp": "2026-03-25T14:30:00Z",
  "project": "/absolute/path/to/repo",
  "branch": "feature/auth",
  "mode": "<quick|standard|thorough>",
  "summary": {},
  "findings": [],
  "conflicts": []
}
```

## Context Checkpoint

Every artifact can include a `context_checkpoint` — a self-contained summary that lets the agent reconstruct phase state without replaying the full conversation. This prevents context overflow on long workflows (8+ phases).

```json
{
  "context_checkpoint": {
    "summary": "One-paragraph summary of what this phase discovered or produced.",
    "key_files": ["path/to/file.ts:142", "path/to/other.ts:87"],
    "decisions_made": [
      "Chose approach X over Y because Z"
    ],
    "open_questions": []
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `summary` | string | What this phase found or produced. Should be self-sufficient — readable without prior context. |
| `key_files` | string[] | Files central to this phase's work, with line numbers where relevant. |
| `decisions_made` | string[] | Choices made during this phase, with reasoning. Critical for downstream phases. |
| `open_questions` | string[] | Unresolved items. Empty array if none. |

**When to populate:** At the end of every phase, BEFORE starting the next. The agent writes the checkpoint as part of `save-artifact.sh` output.

**When to read:** Use `bin/restore-context.sh` to read all completed checkpoints at once — produces a condensed summary under 500 tokens.

## Schema per phase

### /think

```json
{
  "phase": "think",
  "summary": {
    "value_proposition": "string",
    "scope_mode": "expand|selective_expand|hold|reduce",
    "target_user": "string",
    "narrowest_wedge": "string",
    "key_risk": "string",
    "premise_validated": true,
    "out_of_scope": ["string"],
    "manual_delivery_test": {
      "possible": true,
      "steps": ["string"]
    },
    "search_summary": {
      "mode": "local_only|private|public",
      "result": "string",
      "existing_solution": "none|partial|covers_80_percent"
    }
  },
  "context_checkpoint": {
    "summary": "string",
    "key_files": ["string"],
    "decisions_made": ["string"],
    "open_questions": ["string"]
  }
}
```

**Required vs optional in `summary`:**
- Required: `value_proposition`, `scope_mode`, `target_user`, `narrowest_wedge`, `key_risk`, `premise_validated`. The autopilot brief gate (`/think --autopilot`) refuses to advance to `/nano` when any of these are missing or empty.
- Optional: `out_of_scope`, `manual_delivery_test`, `search_summary`. Skills downstream of `/think` consume them when present, fall back to safe defaults when absent.

### /nano

```json
{
  "phase": "plan",
  "summary": {
    "goal": "string",
    "scope": "small|medium|large",
    "step_count": 5,
    "planned_files": [
      "src/auth/login.ts",
      "tests/auth/login.test.ts"
    ],
    "risks": ["string"],
    "out_of_scope": ["string"]
  }
}
```

### /review

```json
{
  "phase": "review",
  "summary": {
    "blocking": 0,
    "should_fix": 2,
    "nitpicks": 3,
    "positive": 1
  },
  "scope_drift": {
    "status": "clean|drift_detected|requirements_missing",
    "planned_files": ["string"],
    "actual_files": ["string"],
    "out_of_scope_files": ["string"],
    "missing_files": ["string"]
  },
  "findings": [
    {
      "id": "REV-001",
      "severity": "blocking|should_fix|nitpick|positive",
      "description": "string",
      "file": "string",
      "line": 42
    }
  ],
  "conflicts": []
}
```

### /qa

```json
{
  "phase": "qa",
  "summary": {
    "mode": "browser|api|cli|debug",
    "status": "pass|fail|partial",
    "tests_run": 12,
    "tests_passed": 11,
    "tests_failed": 1,
    "bugs_found": 1,
    "bugs_fixed": 1,
    "wtf_likelihood": 15
  },
  "findings": [
    {
      "id": "QA-001",
      "severity": "critical|high|medium|low",
      "description": "string",
      "reproduce": "string",
      "root_cause": "string",
      "fixed": true
    }
  ]
}
```

### /security

```json
{
  "phase": "security",
  "summary": {
    "critical": 0,
    "high": 1,
    "medium": 2,
    "low": 1,
    "total_findings": 4
  },
  "findings": [
    {
      "id": "SEC-001",
      "severity": "critical|high|medium|low",
      "category": "A01-A10|STRIDE",
      "description": "string",
      "file": "string",
      "line": 42,
      "proof_of_concept": "string",
      "fix": "string",
      "confidence": 8
    }
  ],
  "conflicts": []
}
```

### /ship

```json
{
  "phase": "ship",
  "summary": {
    "pr_number": 42,
    "pr_url": "string",
    "title": "string",
    "status": "created|merged|reverted",
    "ci_passed": true
  }
}
```

## Conflicts schema

Present in review, security, and qa:

```json
{
  "conflicts": [
    {
      "finding_id": "REV-005",
      "conflicts_with": "SEC-003",
      "tension": "complementary|tradeoff|scope|temporal",
      "resolution": "string",
      "precedence": "string"
    }
  ]
}
```
