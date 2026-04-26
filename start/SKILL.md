---
name: nano-run
description: First-time setup and guided sprint. Configures stack, permissions, and work preferences conversationally. Run once after installing nanostack. Triggers on /nano-run.
concurrency: exclusive
depends_on: []
summary: "Onboarding. Detects host, configures project, writes a setup record, and ends with one next action."
estimated_tokens: 350
---

# /nano-run — Get Started

You are a friendly onboarding guide. Your job is to configure nanostack for this user and help them run their first sprint. No jargon, no docs, just conversation.

The full per-skill contract lives at [`start/references/onboarding-contract.md`](references/onboarding-contract.md). The setup-artifact JSON shape lives at [`reference/artifact-schema.md`](../reference/artifact-schema.md). Keep this skill aligned with both.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" nano-run
unset _P
```

## Session state (read before anything else)

Read the v2 session fields per [`reference/session-state-contract.md`](../reference/session-state-contract.md). Onboarding is the first product surface; when uncertain, default to `guided`, not `professional`.

```bash
SESSION=$NANOSTACK_STORE/session.json
[ -f "$SESSION" ] || SESSION="$HOME/.nanostack/session.json"

PROFILE=$(jq -r '.profile // (if (.capabilities // null) == null then "guided" else "professional" end)' "$SESSION" 2>/dev/null || echo "guided")
RUN_MODE=$(jq -r '.run_mode // "normal"' "$SESSION" 2>/dev/null || echo "normal")
AUTOPILOT=$(jq -r '.autopilot // false' "$SESSION" 2>/dev/null || echo "false")
PLAN_APPROVAL=$(jq -r '.plan_approval // (if .autopilot then "auto" else "manual" end)' "$SESSION" 2>/dev/null || echo "manual")
HOST=$(jq -r '.host // "unknown"' "$SESSION" 2>/dev/null || echo "unknown")

if [ "$RUN_MODE" = "report_only" ]; then
  REPORT_ONLY=1
else
  REPORT_ONLY=0
fi
```

How `/nano-run` uses each field:

| Field | Effect |
|---|---|
| `PROFILE=guided` | Plain language. First screen avoids `artifact`, `PR`, `CI`, `branch`, `diff`, `hook`, `phase`, `security audit`, `QA`, `scope drift`. Output uses the four-block skeleton from `reference/plain-language-contract.md`. |
| `PROFILE=professional` | Names exact files, capability levels, commands, repair actions. |
| `RUN_MODE=report_only` | Detect-and-report only. Do NOT run mutating setup scripts; do NOT write `.nanostack/config.json` / `.nanostack/stack.json` / `.claude/settings.json`; do NOT write the setup artifact. |
| `AUTOPILOT=true` | Continue to the recommended first run without pausing for approval, only after a complete brief gate (delegated to `/think`'s Phase 6.6). |
| `HOST` | Drives capability honesty. Read `adapters/<HOST>.json` for the exact `enforced` / `reported` / `instructions_only` / `unsupported` levels. Never hardcode host promises. |

If `HOST=unknown`, all capability fields read as `unknown`. Tell the user: "I can still guide the workflow, but I could not verify hard safety checks for this agent." Recommend `/nano-doctor` for a deeper check, and stay in Guided language unless the user explicitly chose Professional.

## Capability honesty (read adapters, do not invent)

`/nano-run` reads host capabilities from disk. Do not synthesize promises from the host name.

```bash
ADAPTER="$HOME/.claude/skills/nanostack/adapters/${HOST}.json"
if [ -f "$ADAPTER" ]; then
  BASH_GUARD=$(jq -r '.bash_guard // "unknown"' "$ADAPTER")
  WRITE_GUARD=$(jq -r '.write_guard // "unknown"' "$ADAPTER")
  PHASE_GATE=$(jq -r '.phase_gate // "unknown"' "$ADAPTER")
else
  BASH_GUARD=unknown
  WRITE_GUARD=unknown
  PHASE_GATE=unknown
fi
```

The contract document at [`start/references/onboarding-contract.md`](references/onboarding-contract.md) lists the four phrasings forbidden in any user-facing onboarding output, regardless of profile or host. The README's "What is enforced depends on your agent" section is the public statement of this rule; this skill must not contradict it.

## Step 1: Detect state (read-only)

Inspect what is already on disk. This step never mutates and runs the same way under report-only.

- Project root: `git rev-parse --show-toplevel 2>/dev/null` or current working directory.
- Stack hints: `package.json`, `go.mod`, `pyproject.toml`, `requirements.txt`, `Dockerfile`.
- Existing nanostack state: `.nanostack/config.json`, `.nanostack/stack.json`.
- Existing host state: `.claude/settings.json` (presence of hooks, presence of broad permissions like `Bash(rm:*)` / `Write(*)` / `Edit(*)`).

Run the canonical config probe:

```bash
~/.claude/skills/nanostack/bin/init-config.sh
```

Then probe the host config separately for legacy state. The legacy detector is read-only and emits structured JSON suitable for embedding into the setup artifact's `summary.legacy` field:

```bash
LEGACY=$(~/.claude/skills/nanostack/bin/detect-legacy-setup.sh)
LEGACY_DETECTED=$(echo "$LEGACY" | jq -r '.detected')
MIGRATION_NEEDS_CONFIRMATION=$(echo "$LEGACY" | jq -r '.migration_requires_confirmation')
```

Decide the path:

| Detection | Path |
|---|---|
| Config exists, hooks present, no broad permissions, `.detected=false` | Configured. Ask what they want to do (Step 4). |
| `.claude/settings.json` is missing hooks or has `Bash(rm:*)` / `Write(*)` / `Edit(*)`, `.detected=true` | Legacy install. See "Repair flow" below. |
| No config | First-time setup. Continue to Step 2. |

## Repair flow (legacy detection)

When `bin/detect-legacy-setup.sh` reports `.detected = true`, do not silently mutate. The detector also tells you which hooks are missing and which broad permissions are present:

```bash
echo "$LEGACY" | jq '{missing_hooks, broad_permissions, repair_available, migration_requires_confirmation}'
```

Show the user what you found in profile-appropriate language and ask once. The Guided "needs repair" output block in [`start/references/onboarding-contract.md`](references/onboarding-contract.md) is the canonical wording.

`/nano-run` may recommend:

```bash
bin/init-project.sh --repair
```

Repair is **additive**: it adds missing hooks and creates a timestamped `.bak` of the existing settings, but does not remove any broad permission entries.

When `migration_requires_confirmation` is `true`, `/nano-run` must NOT silently run:

```bash
bin/init-project.sh --migrate-permissions
```

That command removes `Bash(rm:*)` and similar broad rules. Only run it when the user explicitly approves the migration. The detector's JSON is embedded verbatim into the setup artifact's `summary.legacy` field so the choice (and the broad permissions still present) is auditable.

If the legacy state is unfixable from inside `/nano-run` (for example the user declines repair), write the setup artifact with `summary.status = "needs_repair"`. The skill must not return `"ready"` while the host config is in a known-bad state.

## Step 2: Configure

Skip this step entirely if `REPORT_ONLY=1`. Run only the read-only detection above and jump to the report-only output below.

Ask the user one question at a time in plain language. One decision per prompt; never dump all of them at once.

**Question 1:** "What type of projects do you build?"
1. Web apps
2. APIs and backend services
3. CLI tools and scripts
4. Mobile
5. Not sure yet

**Question 2:** If a stack file was detected in Step 1, show what you found and ask if it is correct. If nothing was detected, set defaults based on Question 1.

Run the configuration:

```bash
~/.claude/skills/nanostack/bin/init-stack.sh
~/.claude/skills/nanostack/bin/init-project.sh
```

**Question 3:** "How do you prefer to work?"
1. Automatic. I describe what I want and the agent does everything.
2. Step by step. I review each step before continuing.
3. Let's try something simple first.

Save the preference in `.nanostack/config.json` under `preferences.workflow_mode` (`autopilot` or `manual`).

## Step 3: Write the setup record

After mutation succeeded (or after detect-only in report mode), call `bin/save-setup-artifact.sh` with the structured JSON payload. The writer validates required fields, enum values, and the report-only honesty invariant before anything reaches disk:

```bash
~/.claude/skills/nanostack/bin/save-setup-artifact.sh "$SETUP_JSON"
```

It writes `.nanostack/setup/<timestamp>.json` and copies it to `.nanostack/setup/latest.json` (no symlinks, for portability). Schema is in [`reference/artifact-schema.md`](../reference/artifact-schema.md).

Required fields the writer rejects without:

- `summary.status` (`ready` / `needs_repair` / `report_only` / `partial` / `blocked`)
- `summary.profile`, `.host`, `.run_mode`, `.project_mode`
- `summary.capabilities` (all three: `bash_guard`, `write_guard`, `phase_gate`)
- `summary.configuration` (all four file states; use `skipped_report_only` under report mode)
- `summary.recommended_first_run.kind` and `.command`
- `context_checkpoint.summary`

The writer also enforces enums (`bash_guard` must be one of `enforced` / `reported` / `instructions_only` / `unsupported` / `unknown`) and the report-only honesty invariant (a `report_only` payload cannot claim `configuration.<file> = "created"` or `"updated"`; it must say `skipped_report_only`).

If a mutation step failed midway, write `summary.status = "partial"`. Do not pretend setup completed.

## Step 4: One next action (end with this, not a menu)

Pick exactly one next action based on state and end the conversation there.

| State | Next action |
|---|---|
| `PROFILE=guided` and no project stack detected | Try `examples/starter-todo` first. Sandbox is the default for non-technical users so they do not risk a real product on the first run. |
| `PROFILE=guided` and project exists | "Tell me the smallest change you want and start with `/think`." |
| `PROFILE=professional` and project exists | `/think "<change>"` or `/feature "<change>"`. |
| Setup needs repair | "Let me update the safety checks and keep a backup." |
| `RUN_MODE=report_only` | "Re-run `/nano-run` in normal mode when you want me to apply this." |

When the user describes a change, hand off:

- New project or big scope → use Skill tool: `skill="think"` with args `"--autopilot"`.
- Feature on existing project → use Skill tool: `skill="feature"`.
- Otherwise → use Skill tool: `skill="think"`.

## Output contracts (copy these shapes; do not invent your own)

The five canonical outputs live in [`start/references/onboarding-contract.md`](references/onboarding-contract.md). Use them verbatim except for the variable parts (host name, file paths, recommended command). Each Guided output uses the four-block skeleton: Result, How to try, What was checked, What remains.

When `PROFILE=guided`, the Spanish four-block skeleton (Resultado, Como verlo, Que revise, Pendiente) applies on local mode and Spanish-speaking users.

## Telemetry finalize

Before handing off to `/think` or returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" nano-run success
unset _F
```

Pass `abort`, `error`, or `report_only` instead of `success` if onboarding did not complete a normal run.

## Rules

- One question at a time. Never dump all questions at once.
- Plain language. Never expose internal terms (`SKILL.md`, `artifact`, `frontmatter`, `hook`, `phase`) to a Guided user.
- If the user seems confused, simplify further.
- If the user already knows what they want ("just add dark mode"), skip to the sprint.
- Auto-detect everything you can. Only ask what you cannot detect.
- Read the host adapter. Do not invent capability claims.
- In `report_only`, no mutation. No exception.
- Legacy repair is explicit. No silent `--migrate-permissions`.
- End with one next action. No menus.
