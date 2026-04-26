# /nano-run onboarding contract

`/nano-run` is the first product surface a user sees after installing nanostack. This file is the contract the skill follows so a non-technical founder, an experienced engineer, and a legacy-install maintainer all land on a useful screen within one conversation.

This document is paired with three references the skill also reads:

- [`reference/session-state-contract.md`](../../reference/session-state-contract.md): the v2 session fields (`profile`, `run_mode`, `autopilot`, `plan_approval`, `host`).
- [`reference/plain-language-contract.md`](../../reference/plain-language-contract.md): banned terms and the four-block Guided skeleton.
- [`reference/artifact-schema.md`](../../reference/artifact-schema.md): the `setup` phase schema saved at the end of a successful run.

## What `/nano-run` must do

1. Read session state. Default to `profile=guided` when no session exists. Onboarding is the first screen; when in doubt, explain simply.
2. Detect host, project root, and stack files. Only ask what cannot be detected.
3. Read host capabilities from `adapters/<host>.json`. Do not infer from host name; do not hardcode promises.
4. If `run_mode == report_only`, do not mutate. Print what would change and stop.
5. Otherwise: run setup scripts, write a setup artifact (see schema), end with one next action.
6. If a legacy `.claude/settings.json` is detected, recommend `bin/init-project.sh --repair`. Never run `--migrate-permissions` silently.

## Profile behavior

### Guided

Output follows the four-block skeleton (`Result` / `How to try` / `What was checked` / `What remains`) per `reference/plain-language-contract.md`. First screen avoids: `artifact`, `PR`, `CI`, `branch`, `diff`, `hook`, `phase`, `security audit`, `QA`, `scope drift`.

Default for `/nano-run`: when there is no project stack and `profile == guided`, the recommended first run is the sandbox at `examples/starter-todo`. Do not force; offer.

### Professional

Output names exact files, commands, host, adapter capability levels, repair status, next command. Reads like a setup report a senior engineer can paste into an issue.

## Output examples

### Guided success (no project)

```
Ready to try safely.

How to try:
1. Open examples/starter-todo and run /think "add due dates to tasks".

What was checked:
- I found your agent and checked which safety checks it supports.
- I checked whether this folder already looks like an app.
- I set the first run to plain-language guidance.

What remains:
- I did not change a real product yet.
- Some safety checks depend on your agent. I will say when something is guided instead of blocked.
```

### Guided existing project

```
Ready to use in this project.

How to try:
1. Tell me the smallest change you want and start with /think.

What was checked:
- I found this project and its main tools.
- I checked which safety checks your agent supports.
- I saved the setup record locally.

What remains:
- I did not build or change the app yet.
- If you want a safer first run, use the starter example before touching this project.
```

### Guided needs repair

```
Setup needs one repair.

How to try:
1. Let me update the safety checks and keep a backup.

What was checked:
- I found an older Nanostack setup.
- Some safety checks are missing.
- Your current settings will be backed up before changes.

What remains:
- I will not remove broad permissions unless you explicitly approve that migration.
```

### Professional success

```
Nanostack setup complete.

Host: codex
Profile: professional
Project mode: git
Project root: /path/to/repo
Capabilities:
- Bash guard: instructions_only
- Write/Edit guard: instructions_only
- Phase gate: instructions_only

Files:
- .nanostack/config.json: exists
- .nanostack/stack.json: created
- .nanostack/setup/latest.json: created

Next:
Run /think "describe the change" or try examples/starter-todo first.
```

### Report-only

```
Report-only setup preview.

I did not change files.

Would configure:
- .nanostack/config.json
- .nanostack/stack.json
- project safety settings where supported

Next:
Run /nano-run in normal mode when you want me to apply this.
```

## Behavioral rules

1. **Detect before asking.** Inspect `git rev-parse`, `package.json`, `go.mod`, `pyproject.toml`, `requirements.txt`, `Dockerfile`, `.nanostack/config.json`, `.nanostack/stack.json`, `.claude/settings.json`. Only ask what cannot be detected.
2. **One decision per prompt.** Multi-question forms and "pick from this list of slash commands" prompts are not allowed. Ask "Sandbox first or this project?", "Plain language or technical?", "Repair the older setup with a backup?" one at a time.
3. **Sandbox first for Guided + no project.** Default recommendation is `examples/starter-todo`. When a project exists, offer the sandbox but do not force.
4. **No hidden mutation in report_only.** No `bin/init-stack.sh`, no `bin/init-project.sh`, no `.gitignore` write, no `.claude/settings.json` change, no setup-artifact write.
5. **Legacy repair is explicit.** May recommend `bin/init-project.sh --repair`. Must NOT silently run `--migrate-permissions`.
6. **Setup artifact is written after successful mutation.** If the run partially fails, write status `partial` (not `ready`) so doctor and support know.
7. **End with one next action.** No long menus. Pick exactly one based on state:
   - guided + no project → "Try examples/starter-todo."
   - guided + project → "Start /think with the smallest change."
   - professional + project → `/think "<change>"` or `/feature "<change>"`.
   - needs_repair → "Run repair first."
   - report_only → "Re-run in normal mode when ready."

## Capability honesty

`/nano-run` must read the five capability fields per host from `adapters/<host>.json`:

- `bash_guard`
- `write_guard`
- `phase_gate`
- `skill_discovery`
- `verification.method`

For Guided output, the only thing that goes on the first screen is whether something is `enforced` or `instructions_only`. Concrete level values (L0-L3) live in Professional output and `/nano-doctor`.

If `host == "unknown"` or the adapter file is missing:

- All capability fields → `unknown`.
- First screen says: "I can still guide the workflow, but I could not verify hard safety checks for this agent."
- Recommend `/nano-doctor` for a deeper check.
- Use Guided language unless user explicitly chose Professional.

## Forbidden claims

The following phrases must never appear in `/nano-run` output, in any profile, regardless of host:

- "always blocks"
- "guaranteed blocks"
- "all agents enforce"
- "hard-blocks on every agent"

CI greps for these in `start/SKILL.md`.

## Where this lives in the lifecycle

`/nano-run` is the only skill that:

- Runs before any session exists.
- May write `.nanostack/config.json` and `.nanostack/stack.json`.
- May call `bin/init-project.sh` (with or without `--repair`).

After `/nano-run` completes, the user enters the canonical sprint loop: `/think → /nano → build → /review → /security → /qa → /ship`. Subsequent runs of `/nano-run` on the same project either confirm that everything is set, or recommend a repair.
