# Session-state contract for skills

This is the read-side contract for `session.json` schema v2 (introduced in Sprint 2 of v1.0). Every skill that runs after `/nano` reads from this file to decide:

- whether to pause for approval
- whether to edit files at all
- how to phrase its final output
- which phase to suggest next

Do not infer these answers from skill prose, command-line arguments, or conversation context. Read them from `session.json`.

## Reading the four fields

Use this snippet near the top of any skill that reads session state. It is safe on v1 sessions: the `// fallback` jq filters provide the spec compatibility defaults.

```bash
SESSION=$NANOSTACK_STORE/session.json
[ -f "$SESSION" ] || SESSION="$HOME/.nanostack/session.json"

PROFILE=$(jq -r '.profile // (if (.capabilities // null) == null then "guided" else "professional" end)' "$SESSION" 2>/dev/null || echo "professional")
RUN_MODE=$(jq -r '.run_mode // "normal"' "$SESSION" 2>/dev/null || echo "normal")
AUTOPILOT=$(jq -r '.autopilot // false' "$SESSION" 2>/dev/null || echo "false")
PLAN_APPROVAL=$(jq -r '.plan_approval // (if .autopilot then "auto" else "manual" end)' "$SESSION" 2>/dev/null || echo "manual")
```

If the session file does not exist, default to `professional` / `normal` / `false` / `manual`.

## What each field decides

| Field | Values | What the skill must do |
|---|---|---|
| `profile` | `guided` \| `professional` | Shapes the final output. Guided uses the four-block format defined in `reference/plain-language-contract.md`; Professional preserves findings/evidence style. |
| `run_mode` | `normal` \| `report_only` | When `report_only`, the skill must NOT edit files, fix issues, commit, push, or call any `--fix` mode. It only reports. |
| `autopilot` | `true` \| `false` | When `true`, do not pause between phases. Show one status line and continue. |
| `plan_approval` | `manual` \| `auto` \| `not_required` | Used by `/nano` to decide whether to wait for plan approval. Other skills usually mirror autopilot. |
| `archetype` (optional, Guided Archetypes v1) | `founder_validation` \| `cli_tooling` \| `api_backend` \| `landing_experience` \| `unknown` \| absent | When set, `/think` may use it as one of the detection signals (priority below explicit flag and below current path). Absence is the default; `/think` then runs its own deterministic detection. The full archetype contract lives in [`think/references/archetypes.md`](../think/references/archetypes.md). |

## Guided final-output blocks

When `PROFILE == "guided"`, the final user-facing output of every Sprint phase (review, security, qa, ship, doctor) follows the four-block skeleton defined in `reference/plain-language-contract.md` (Result / How to try / What was checked / What remains). The plain-language contract is authoritative; this file does not redefine the structure. "Whether it is safe to try" lives inside the Result block, not as a separate block.

The next-action prose comes from `bin/next-step.sh --json | jq -r .user_message`. The script reads `profile` from the session and shapes wording accordingly, so skills do not have to.

## Professional final-output

When `PROFILE == "professional"`, keep the existing findings/evidence format. Use `bin/next-step.sh --json | jq -r .user_message` for the next-step prose so the wording stays consistent across skills.

## Next-step contract

Stop encoding next-step prose in each skill. Call:

```bash
~/.claude/skills/nanostack/bin/next-step.sh --json
```

Read `.user_message` for the next action and `.next_phase` for the phase name. The script reads `session.json` first, falls back to fresh artifacts, and chooses wording based on `profile`. Skills must NOT print their own list of pending phases.

`--json` returns these fields (PR 4 of the 2026-05-10 architecture audit made the lifecycle graph-aware):

| Field | Type | What it carries |
|-------|------|-----------------|
| `profile` | string | `guided` or `professional`, sourced from the session. |
| `next_phase` | string | The single phase the skill should suggest next. For the default sprint this picks the first phase in graph order. For a custom workflow stack this is the next ready phase from the project's `phase_graph`. |
| `pending_phases` | array | Every phase that is ready to run right now (the legacy name). Mirrors `ready_phases` for forward compatibility. |
| `ready_phases` | array | Every phase whose dependencies are met. Use this when the skill wants to surface "you could run any of these in parallel" instead of a single suggestion. |
| `required_before_ship` | array | The set of phases ship depends on (transitively), emitted in the graph's declared node order. For the default sprint it is `["review","security","qa"]`; for a custom graph it reflects the actual chain (for example `["license-audit","privacy-check","release-readiness"]`). Treat the field as a set; consumers that compare the array exactly should sort before comparing. |
| `user_message` | string | The next-action prose shaped by profile. For phases the script does not have specific copy for, it falls back to `"I will run the <phase> step next."` (guided) or `"Run /<phase> next."` (professional) and never exposes phase-graph jargon. |
| `can_ship` | boolean | True when nothing in `required_before_ship` is still pending. |

## Graph-aware session fields

When `session.sh init` runs, it snapshots the active `phase_graph` into `session.json` so a mid-sprint edit to `.nanostack/config.json` cannot change the path under the session. `session.sh phase-complete` reads that snapshot and updates `next_phase` plus `ready_phases` after every phase write.

| Field | Type | Meaning |
|-------|------|---------|
| `phase_graph` | array | The snapshot of `{name, depends_on}` pairs taken at session init. Empty array when the host did not have the phase registry library available (legacy fallback). |
| `next_phase` | string \| null | The first ready phase after the latest `phase-complete`. `compound` after `ship`. `null` when no phase is ready (sprint complete and no custom continuation). |
| `ready_phases` | array | Every phase whose dependencies are satisfied and which is not yet completed or in progress. May contain multiple entries when a graph runs phases in parallel. |

Skills that need fan-out scheduling read `ready_phases`; skills that just want the next single phase read `next_phase`.

## report_only guard

Place this near the top of the skill's process section, before any edit/fix step:

```bash
if [ "$RUN_MODE" = "report_only" ]; then
  # Do not edit files, do not run --fix, do not commit, do not push.
  # Only describe what would change.
  REPORT_ONLY=1
else
  REPORT_ONLY=0
fi
```

Subsequent steps must check `$REPORT_ONLY` before mutating anything. A skill that ignores this flag is a regression: report-only sprints exist so a user can see what the skill would do without committing the agent to action.
