---
name: nano-doctor
description: Install health check for nanostack. Diagnoses dependencies, permissions, telemetry config, and pre-V5 detection. Triggers on /nano-doctor. Flags - --json, --offline, --fix.
concurrency: read
depends_on: []
summary: "Install health check. Ten checks, exit code maps to severity."
estimated_tokens: 150
---

# /nano-doctor — Install Health Check

You diagnose the local nanostack install. Ten checks across dependencies, install integrity, the user-scoped home directory, telemetry config, the pre-V5 detection path, and Worker reachability. Output names the category, the check, and a one-line detail. No decorative prose.

This is a diagnostic skill, not a fix-everything skill. Mechanical issues (file permissions, missing `chmod +x`) repair with `--fix`. Anything that needs human judgment stays as a warning or failure.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" nano-doctor
unset _P
```

## Process

Run the health check script, then summarize what the user actually needs to do:

```bash
~/.claude/skills/nanostack/bin/nano-doctor.sh
```

Optional flags:

- `--json` — machine-readable output. Use when invoked by another tool or when piping to `jq`.
- `--offline` — skip Worker reachability. Use in air-gapped environments or during CI.
- `--fix` — repair mechanical issues (`chmod 700` on `~/.nanostack/`, `chmod +x` on the sender). Never touches config or data.

## Interpreting the output

The script prints one line per check, grouped by category. Status values:

- `ok  ` — passed, nothing to do.
- `warn` — minor issue. Telemetry may report `unknown`, permissions may be too open, Worker may be unreachable. None of these block `/think`, `/nano`, etc.
- `FAIL` — critical issue. A missing dependency or missing skill file. Usage is impaired.

Exit codes:

| Exit | Meaning |
|------|---------|
| 0 | Everything checks out |
| 1 | Warnings only, skill still works |
| 2 | Critical, needs repair before use |

## When to recommend `--fix`

If the report shows warnings for `home permissions` or `sender_executable`, re-run with `--fix`. For any other warning or failure, surface the detail to the user and let them decide. Do NOT try to fix missing dependencies, missing VERSION files, or misconfigured tiers automatically.

## When to recommend a reinstall

If the skill_dir check fails, the install itself is missing or corrupted. Tell the user:

```sh
npx create-nanostack
```

That reinstalls and preserves the existing `~/.nanostack/` (telemetry config, installation-id, past opt-in choice).

## Local mode

If the user is non-technical (detected via `bin/lib/git-context.sh` `local` mode), do not dump the raw report. Translate the outcome into one sentence:

- All ok: "Nanostack está sano, todo en orden."
- Warnings: "Hay algunos avisos menores. ¿Querés que los repare?" then offer to run with `--fix`.
- Failures: "Hay un problema con la instalación. Lo más probable es que necesites reinstalar con `npx create-nanostack`. ¿Querés que te guíe?"

Never read the internal category names ("install", "detection") to a non-technical user. Those are for the report, not for the conversation.

## Telemetry finalize

Before returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" nano-doctor success
unset _F
```

Outcome stays `success` even if the diagnosis found issues; the skill itself ran, the install is what has the problem. Pass `error` only if the script failed to execute (missing, not readable, etc.).

## Gotchas

- **Do not run `--fix` without reporting what it will change.** The user should see the warnings before they are repaired, not after. Default to read-only; `--fix` is opt-in.
- **Do not treat warn as fail.** A missing VERSION file is not a broken install; it just means events report `unknown`.
- **Do not interpret the output for the user when it is clean.** If exit is 0 and there are no warnings, say "healthy" and stop. No need to recite the ten lines.
