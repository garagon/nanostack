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
