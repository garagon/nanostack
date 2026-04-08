# Spec: Token usage analyzer

**Status:** Proposed
**Date:** 2026-04-08
**Depends on:** nanostack-budget-circuit-telemetry.md (budget.sh, session.sh, analytics.sh)
**Affects:** bin/token-report.sh (new), bin/token-analyzer.py (new), bin/analytics.sh (extend)

---

## Context

Nanostack has budget enforcement (budget.sh) and circuit breakers (circuit.sh), but both rely on the agent self-reporting token counts — which never happens. The `session.json` fields `tokens_input` and `tokens_output` are always 0. analytics.sh has no cost aggregation.

Meanwhile, Claude Code writes every API response to `~/.claude/projects/<project-dir>/<session-uuid>.jsonl` with exact token counts per message. Subagent sessions live in `<session-uuid>/subagents/agent-*.jsonl`. This is ground-truth data that nanostack ignores.

The problem this solves: users burn through subscriptions without knowing which sessions, phases, or subagents consumed the most. Kieran Klaassen's viral post (Apr 6, 2026) showed a recurring script consuming 91% of a Max subscription on a Monday because there was no visibility.

---

## What exists today

| Component | State | Gap |
|-----------|-------|-----|
| `~/.claude/projects/**/*.jsonl` | Claude Code writes these automatically | Nanostack never reads them |
| `budget.sh check --input-tokens N` | Implemented | Requires agent to pass token counts — never happens |
| `session.json budget.tokens_input/output` | Schema exists | Always 0 |
| `analytics.sh --json` | Counts phases per month | No token/cost aggregation |
| `save-artifact.sh --tokens-in --tokens-out` | In spec | 0% implemented |

---

## 1. JSONL reader: `bin/token-report.sh`

### Problem

No visibility into actual token consumption per project, session, or subagent. Users discover overspend only via the Anthropic usage dashboard — after the money is gone.

### Data source

Claude Code session logs at `~/.claude/projects/`. Structure:

```
~/.claude/projects/
  -Users-dev-Documents-project-foo/
    <uuid>.jsonl                    # main session
    <uuid>/subagents/agent-*.jsonl  # subagent sessions
```

Each assistant message in a JSONL contains:

```json
{
  "type": "assistant",
  "message": {
    "model": "claude-opus-4-6",
    "usage": {
      "input_tokens": 3,
      "cache_creation_input_tokens": 13916,
      "cache_read_input_tokens": 11196,
      "output_tokens": 36
    }
  },
  "timestamp": "2026-04-08T03:43:50.659Z",
  "sessionId": "75cfa1d8-...",
  "gitBranch": "perf/token-reduction"
}
```

### Specification

**New script: `bin/token-report.sh`**

Shell wrapper. Delegates to `bin/token-analyzer.py` for JSONL parsing (parsing nested JSON lines across hundreds of files is not practical in bash).

```bash
# Quick summary for current project
bin/token-report.sh
# → Scans JSONL files for the project in $(pwd)

# All projects
bin/token-report.sh --all

# Time filter
bin/token-report.sh --since 7d
bin/token-report.sh --since 2026-04-01

# JSON output (for piping to analytics.sh)
bin/token-report.sh --json

# Top N costliest sessions
bin/token-report.sh --top 10

# Subagent breakdown
bin/token-report.sh --subagents
```

**`bin/token-analyzer.py`** — Python script (no external dependencies beyond stdlib).

Reads `~/.claude/projects/` JSONL files. For each session:

1. Sum `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens` from all `type: "assistant"` lines
2. Extract `model` from first assistant message
3. Extract `gitBranch`, `timestamp` range, `sessionId`
4. Recursively parse subagent JSONL files in `<uuid>/subagents/`
5. Calculate USD cost using same pricing table as `budget.sh`

**Output modes:**

Terminal (default):
```
Token Usage Report — nanogstack (last 7 days)
═══════════════════════════════════════════════

Sessions: 12 | Subagents: 47 | Total: 4,230,000 tokens | Est. cost: $18.45

Top sessions:
  1. [Apr 07] perf/token-reduction  1,200,000 tok  $5.20  (9 subagents)
  2. [Apr 06] feat/conductor         890,000 tok  $3.85  (14 subagents)
  3. [Apr 05] fix/guard-rules         340,000 tok  $1.47  (3 subagents)

Token breakdown:
  Input:          1,890,000  (45%)
  Cache creation:   420,000  (10%)
  Cache read:     1,580,000  (37%)  ← cache efficiency: 79%
  Output:           340,000  ( 8%)

Subagent cost:     $7.20 (39% of total)
```

JSON (`--json`):
```json
{
  "project": "nanogstack",
  "period": {"since": "2026-04-01", "until": "2026-04-08"},
  "sessions": 12,
  "subagent_sessions": 47,
  "tokens": {
    "input": 1890000,
    "cache_creation": 420000,
    "cache_read": 1580000,
    "output": 340000,
    "total": 4230000
  },
  "cost_usd": 18.45,
  "subagent_cost_usd": 7.20,
  "cache_efficiency_pct": 79,
  "top_sessions": [
    {
      "session_id": "75cfa1d8-...",
      "branch": "perf/token-reduction",
      "date": "2026-04-07",
      "tokens_total": 1200000,
      "cost_usd": 5.20,
      "subagent_count": 9,
      "subagent_tokens": 480000,
      "model": "claude-opus-4-6"
    }
  ]
}
```

### Project directory resolution

To find which `~/.claude/projects/` directory corresponds to `$(pwd)`:

```bash
# Claude Code encodes the path: /Users/dev/Documents/project → -Users-dev-Documents-project
CLAUDE_PROJECT_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"
```

This is deterministic — no guessing required.

### Pricing table

Shared with `budget.sh`. Extract to `bin/lib/pricing.sh` so both scripts use the same source:

```bash
# Per 1M tokens: input output
pricing() {
  case "$1" in
    opus-4|opus-4-6)     echo "15.0 75.0" ;;
    sonnet-4|sonnet-4-6) echo "3.0 15.0" ;;
    haiku-4-5)           echo "0.80 4.0" ;;
    gpt-4o)              echo "2.5 10.0" ;;
    gpt-4.1)             echo "2.0 8.0" ;;
    o3)                  echo "2.0 8.0" ;;
    *)                   echo "3.0 15.0" ;;
  esac
}
```

### Cache efficiency metric

```
cache_efficiency = cache_read / (cache_read + cache_creation) * 100
```

High (>70%) = good: context reuse is working.
Low (<40%) = problem: each turn is recreating cache, burning creation tokens unnecessarily.

This metric is unique to nanostack — no other tool surfaces it.

---

## 2. Extend analytics.sh with token aggregation

### Problem

analytics.sh counts phases but can't answer "how much did this month cost?" or "which phase is most expensive?"

### Specification

Add a `--tokens` flag to analytics.sh that calls `bin/token-report.sh --json` and merges the result:

```bash
bin/analytics.sh --json --tokens
```

New fields in JSON output:

```json
{
  "month": "2026-04",
  "sprints": { "think": 5, "plan": 5, "...": "..." },
  "modes": { "quick": 3, "standard": 8, "thorough": 2 },
  "tokens": {
    "total": 4230000,
    "input": 1890000,
    "cache_creation": 420000,
    "cache_read": 1580000,
    "output": 340000,
    "cost_usd": 18.45,
    "cache_efficiency_pct": 79,
    "subagent_pct": 39,
    "avg_per_session": 352500
  }
}
```

Terminal output appends a new section:

```
  Token usage (2026-04)
  ─────────────────────
  total tokens  4,230,000
  est. cost     $18.45
  cache eff.    79%
  subagent %    39%
  avg/session   352,500
```

### Files to modify

- `bin/analytics.sh` — add `--tokens` flag, call token-report.sh, merge output

---

## 3. Backfill session.json from JSONL (optional, on-demand)

### Problem

Historical `session.json` files have `tokens_input: 0`. After implementing the analyzer, we can optionally backfill.

### Specification

```bash
bin/token-report.sh --backfill-session
```

For the current active session in `.nanostack/session.json`:
1. Find the matching JSONL by `session_id` or by timestamp overlap
2. Sum tokens from the JSONL
3. Update `budget.tokens_input`, `budget.tokens_output`, `budget.spent_usd`

This is a one-time reconciliation, not a live feed. The agent doesn't need to self-report anymore — the data is already in the JSONL.

### Matching logic

Session matching between nanostack and Claude Code:

```
nanostack session.json:
  started_at: "2026-04-07T20:30:00Z"
  workspace: "/Users/dev/.../nanogstack"

Claude JSONL:
  timestamp of first message: "2026-04-07T20:30:02Z"
  cwd: "/Users/dev/.../nanogstack"
```

Match by: same project directory + timestamp within 60 seconds of session start.

---

## 4. Anomaly detection

### Problem

A subagent in a loop or a cron-triggered session can silently consume the entire subscription (the Klaassen scenario).

### Specification

`bin/token-report.sh --check` — lightweight check suitable for hooks or cron.

Returns JSON with warnings:

```json
{
  "status": "warning",
  "alerts": [
    {
      "type": "session_outlier",
      "session_id": "abc123",
      "tokens": 2400000,
      "avg_tokens": 350000,
      "ratio": 6.8,
      "message": "Session used 6.8x the average. Check for loops."
    },
    {
      "type": "subagent_heavy",
      "session_id": "abc123",
      "subagent": "agent-a9988e7.jsonl",
      "tokens": 890000,
      "pct_of_session": 72,
      "message": "Single subagent consumed 72% of session tokens."
    },
    {
      "type": "high_frequency",
      "sessions_last_hour": 8,
      "avg_sessions_per_hour": 1.2,
      "message": "8 sessions in the last hour (avg 1.2). Possible automation loop."
    }
  ]
}
```

**Thresholds (configurable via env vars):**

| Alert | Default threshold | Env var |
|-------|-------------------|---------|
| Session outlier | >3x average | `NANO_TOKEN_OUTLIER_RATIO=3` |
| Subagent heavy | >60% of session | `NANO_TOKEN_SUBAGENT_PCT=60` |
| High frequency | >4x avg sessions/hour | `NANO_TOKEN_FREQ_RATIO=4` |

**Integration with circuit.sh:** When `--check` finds anomalies, it can feed into `circuit.sh fail --tag token-anomaly` to trigger the circuit breaker.

---

## 5. Obsidian dashboard extension

### Specification

Extend `analytics.sh --obsidian` to include token data when `--tokens` is also passed:

```markdown
## Token Usage (2026-04)

| Metric | Value |
|--------|-------|
| Total tokens | 4,230,000 |
| Est. cost | $18.45 |
| Cache efficiency | 79% |
| Subagent % | 39% |
| Sessions | 12 |
```

---

## What this does NOT include

| Pattern | Why excluded |
|---------|-------------|
| Real-time token streaming | JSONL is written by Claude Code, not readable mid-turn. Post-hoc analysis only. |
| Per-phase attribution from JSONL | JSONL doesn't know about nanostack phases. Phase attribution stays in session.json via save-artifact.sh. |
| Model routing recommendations | "Switch to sonnet for review" is a workflow change, not a telemetry feature. May add later based on data. |
| Prompt extraction/logging | Privacy concern. Only extract first prompt for session identification, never persist. |
| Cross-machine aggregation | This is local-only. Team analytics would require a different architecture. |

---

## Implementation order

1. **`bin/lib/pricing.sh`** — extract pricing table from budget.sh, shared source
   - Modify budget.sh to source it

2. **`bin/token-analyzer.py`** — core Python script
   - JSONL parsing, token aggregation, cost calculation
   - No external dependencies
   - Test: run against real `~/.claude/projects/` data

3. **`bin/token-report.sh`** — shell wrapper
   - Project resolution, arg parsing, delegates to Python
   - Test: `bin/token-report.sh --json | jq .`

4. **`bin/analytics.sh --tokens`** — extend analytics
   - Calls token-report.sh, merges into output
   - Test: `bin/analytics.sh --json --tokens | jq .tokens`

5. **Anomaly detection (`--check`)** — add to token-report.sh
   - Test: verify outlier detection with synthetic data

6. **Session backfill (`--backfill-session`)** — last, depends on matching logic
   - Test: compare backfilled session.json with manual JSONL inspection

---

## Verification

1. `bin/token-report.sh` outputs valid terminal summary for current project
2. `bin/token-report.sh --json | jq .tokens.total` returns non-zero integer
3. `bin/token-report.sh --all` scans all projects without error
4. `bin/token-report.sh --since 7d` filters correctly
5. `bin/token-report.sh --subagents` shows per-subagent breakdown
6. `bin/token-report.sh --check` returns `"status": "ok"` on normal usage
7. `bin/analytics.sh --json --tokens` merges token data into existing output
8. `bin/analytics.sh --obsidian --tokens` includes token table in dashboard
9. `budget.sh` still works after pricing extraction to lib/pricing.sh
10. `bin/token-report.sh --backfill-session` updates session.json with real token counts
11. Python script has zero external dependencies (stdlib only)
12. No files written outside `.nanostack/` and stdout
