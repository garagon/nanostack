---
name: privacy-check
description: Use to detect personal-data collection signals (email forms, payment fields, telemetry libraries) before shipping. Surfaces missing privacy notes. Not a legal review. Triggers on /privacy-check.
concurrency: read
depends_on: [build]
summary: "Release hygiene check for personal-data collection and privacy notes, part of the compliance-release stack."
estimated_tokens: 220
---

# /privacy-check — Release Privacy Hygiene

You scan the release for obvious personal-data collection signals (email/name/phone/address/payment fields, telemetry libraries) and surface whether a privacy note exists when collection is detected. The output feeds `/release-readiness`, which gates `/ship`.

**This is not a legal review.** It does not certify GDPR or CCPA compliance. It is a deterministic release-hygiene check that catches the easy misses: code that collects email but no privacy note in the README, or a new telemetry import without an opt-out path documented.

This is the `privacy-check` skill from the compliance-release stack. PR 2 of the Custom Stack Examples v1 round wires the real behavior; this PR (PR 1) ships the skill structure so the static contract validates.

## Process

### 0. Resolve paths (host-agnostic)

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/privacy-check}"
```

### 1. Run the check

```bash
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/privacy-check}"
"$SKILL_DIR/bin/check.sh"
```

The helper scans the project's source for:
- Personal-data fields: `email`, `name`, `phone`, `address`, `payment`, `token`, `api_key`, file uploads.
- Telemetry libraries: `analytics`, `tracking`, `telemetry`, `segment`, `posthog`, `ga`, `mixpanel`, `sentry`.
- A privacy note: `PRIVACY.md`, a "Privacy" or "Data" section in `README.md`, or `TELEMETRY.md` for telemetry-only cases.
- Env templates: `.env.example`, `.env.sample`, `.env.template` (allowed by guard) for keys that hint at collection.

The helper **does not read** `.env`, `.env.local`, `.env.production`, or any credential JSON. The bash guard already blocks those.

### 2. Save the artifact

```bash
NANOSTACK_ROOT="${NANOSTACK_ROOT:-$HOME/.claude/skills/nanostack}"
"$NANOSTACK_ROOT/bin/save-artifact.sh" privacy-check \
  '{"phase":"privacy-check","summary":{"status":"WARN","headline":"...","signals":[...],"missing":["privacy_note"],"next_action":"..."},"context_checkpoint":{"summary":"Privacy check completed."}}'
```

Status rules:
- `OK` — no collection signals detected, or signals are documented in a privacy note.
- `WARN` — collection signals detected but no privacy note found, or telemetry without an opt-out path documented.
- `BLOCKED` — reserved for clearly unsafe patterns (e.g., a credential file added to source). The composer escalates this in `/release-readiness`.

### 3. Headline

```
[privacy-check] WARN: email collection detected, no privacy note.
```

## Gotchas

- This skill does not interpret intent. A test fixture that mentions `email` will be flagged the same way real code does. The user decides whether the signal is real.
- "Privacy note" is a structural check, not a quality check. The skill confirms a note exists; it does not validate the note's content. That's a human review.
- The helper never edits files, never writes to the network, never opens `.env` or credential files. Read-only by design.
