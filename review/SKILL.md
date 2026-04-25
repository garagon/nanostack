---
name: review
description: Use after writing code to get a thorough code review. Runs two passes — structural correctness then adversarial edge-case hunting. Scales depth by diff size. Supports --quick, --standard, --thorough modes. Triggers on /review.
concurrency: read
depends_on: [build]
summary: "Two-pass code review. Structural correctness then adversarial edge-case hunting. Scope drift detection."
estimated_tokens: 400
hooks:
  PostToolUse:
    - matcher: Bash
      command: "./review/bin/suggest-security.sh"
---

# /review — Two-Pass Code Review

You are a skeptical senior engineer who has seen production go down because someone skipped the second look. Two passes, two mindsets. Do not blend them. You own the findings: if something is mechanical, fix it yourself. If it needs judgment, ask.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" review
unset _P
```

## Intensity Mode

If the user specifies a mode flag, use it. Otherwise, check `bin/init-config.sh` for `preferences.default_intensity`. If no config, **suggest** a mode based on the diff:

| Mode | Flag | When to use | Confidence gate |
|------|------|-------------|-----------------|
| **Quick** | `--quick` | Trivial changes: typos, config, docs, < 50 lines in non-code files | 9/10 — only report the obvious |
| **Standard** | (default) | Normal changes: features, bug fixes, 50-500 lines | 7/10 — report anything reasonable |
| **Thorough** | `--thorough` | Critical changes: auth, payments, infra, 500+ lines, or touches security-sensitive paths | 3/10 — flag anything suspicious |

Auto-suggest logic (recommend, don't enforce):
- Diff < 50 lines AND only `.md`/`.txt`/`.yml`/`.json` → suggest `--quick`
- Diff 50-500 lines OR code changes → `--standard` (default)
- Diff > 500 lines OR touches `auth`/`payment`/`security`/`infra`/`.env`/`Dockerfile` → suggest `--thorough`

## Setup

Calibrate depth by diff size: **Small** (< 100 lines, quick pass) / **Medium** (100-500, full two-pass) / **Large** (500+, full + architecture).

## Local Mode

Run `source bin/lib/git-context.sh && detect_git_mode`. If `local` (no git):
- **File source:** use `context_checkpoint.key_files` from the plan artifact instead of git diff. If no plan artifact, list files in the project directory.
- **Skip:** scope drift check (no diff to compare), PR preview.
- **Language:** replace all jargon with plain terms. "Revisé N archivos. Encontré X cosas:" instead of "Diff: N files, X findings." Replace "nit" → "detalle menor", "auto-fix" → "ya lo arreglé", "blocking" → "hay que arreglar esto", "finding" → "cosa". Explain each issue in plain language — what's wrong, why it matters, and whether you already fixed it.
- **Next steps:** do NOT list slash commands. Instead: "¿Querés que revise la seguridad antes de darlo por terminado?"
- **Everything else stays the same:** two passes (structural + adversarial), severity levels, auto-fix vs ask.

## Step 0: Resolve Context

Load plan artifact, matched solutions, conflict precedents, and diarizations in one call:

```bash
~/.claude/skills/nanostack/bin/resolve.sh review --diff
```

The output is JSON with `upstream_artifacts` (plan path), `solutions` (ranked by file overlap with current diff), `conflict_precedents` (path to precedents doc), `diarizations` (matching module briefs), and `config`.

From the plan artifact (if present), read these fields:
- **`planned_files[]`** → used by scope drift check (below)
- **`risks[]`** → create a risk checklist. For each risk, actively probe the code for that specific failure mode during your adversarial pass. These risks were identified during planning and should be verified.
- **`out_of_scope[]`** → verify none of these were implemented. If the code touches something explicitly marked out of scope, flag it as scope creep.

From solutions: read the summaries first, then load only those relevant to the current review. If past solutions exist, check whether the current code follows the documented resolutions. If it contradicts a past solution, flag it.

From diarizations: if a module brief exists for files in the diff, read it for recurring issues and unresolved tensions. Focus your adversarial pass on what the diarization flags.

## Graduated Rules

<!-- Auto-maintained by bin/graduate.sh. Do not edit manually. -->
<!-- Each rule was promoted from a solution with 3+ applications and validation. -->
<!-- END GRADUATED RULES -->

Check these rules during your structural pass. Each one represents a proven pattern from past sprints.

## Step 0.5: Scope Drift Check

Always run if a recent plan artifact exists. In `--quick` mode, drift is informational. In `--standard`, drift is informational. In `--thorough`, drift is BLOCKING.

Run the scope drift script:

```bash
~/.claude/skills/nanostack/bin/scope-drift.sh
```

The script returns JSON with `status` (clean / drift_detected / requirements_missing), `out_of_scope_files`, and `missing_files`. Config/lock files are automatically exempt.

- `--thorough`: drift is **Blocking** — ask user to confirm scope change before proceeding
- `--standard`: drift is **Informational** — note it and continue

## Pass 1: Structural Review

For each changed file, evaluate:

- **Correctness:** Does the code do what it claims? Are there off-by-one errors, nil dereferences, race conditions, missing error handling at system boundaries?
- **Consistency:** Does it follow the patterns already established in this codebase? Check naming, file organization, error handling style.
- **Completeness:** Are there missing edge cases? What happens with empty input, nil, zero, max values?
- **Tests:** Do the tests actually test the behavior change? Are they testing implementation details instead of behavior?

Read `review/checklist.md` for the detailed checklist. Use it as a reference, not a script — skip items that don't apply.

## Pass 2: Adversarial Review

Now forget everything you just read. Approach the code as if you are trying to break it.

- **What input would crash this?** Think about malicious input, not just malformed input.
- **What happens under load?** Concurrent access, large payloads, slow dependencies.
- **What happens when dependencies fail?** Network errors, timeouts, partial responses.
- **What state can this leave behind if it fails halfway?** Partial writes, leaked resources, inconsistent caches.
- **What will confuse the next developer?** Implicit assumptions, magic numbers, non-obvious control flow.
- **Security surface:** SQL injection, command injection, path traversal, XSS, SSRF, secrets in code. See `/security` for a full audit.

## Output Format

Classify every finding as AUTO-FIX or ASK:

**AUTO-FIX** (mechanical, high confidence, no judgment needed): dead code, missing error return, off-by-one, stale imports, typos in strings. Fix it, report what you did.

**ASK** (needs judgment, design decision, or user context): race conditions, API contract changes, removing functionality, security tradeoffs. Show the problem, recommend a fix, wait for approval.

Open with a summary line:
```
Review: 5 findings (2 auto-fixed, 2 ask, 1 nit). 3 things done well.
```

Then group by severity: **Blocking** (must fix), **Should Fix** (tech debt, confusion), **Nitpicks** (prefix "nit:"), **What's Good** (always include, be specific about what the code does right).

## Conflict Detection

After completing both passes, check for conflicts with prior `/security` findings. The resolver output from Step 0 includes `conflict_precedents` (path to the precedents doc). If a security artifact exists from a prior sprint (check `.nanostack/security/`), cross-reference your findings against it.

When a conflict is detected, mark it inline:
```
- **Error messages are too vague**
  ⚠️ CONFLICT with SEC-003 → RESOLUTION: structured errors (code + generic msg to user, details to logs)
```

**In `--quick` mode:** Apply default precedence (security > review) without documenting.
**In `--standard` mode:** Document conflicts inline in output.
**In `--thorough` mode:** Document conflicts AND flag as Blocking until user confirms resolution.

After completing both passes and conflict detection, save the artifact. Run this command now — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh --from-session review 'N findings (X blocking). Scope drift: none/detected. Conflicts: none/N.'
```

Or pass full JSON for richer detail:
```bash
~/.claude/skills/nanostack/bin/save-artifact.sh review '<json with phase, mode, summary, scope_drift, findings, conflicts, context_checkpoint>'
```

## Mode Summary

| Aspect | Quick | Standard | Thorough |
|--------|-------|----------|----------|
| Pass 1 (structural) | Correctness only | Full checklist | Full checklist + architecture |
| Pass 2 (adversarial) | Skip | Standard | Deep + threat model |
| Scope drift | Informational | Informational | BLOCKING on drift |
| Conflict detection | Auto-resolve | Document inline | BLOCKING until resolved |
| Output | Blocking issues only | All categories | All + rationale per finding |

## Session state

Read `profile`, `run_mode`, `autopilot`, and `plan_approval` per `reference/session-state-contract.md`. When `run_mode == report_only`, do not apply any fix or write any file as part of review; only report what would change.

## Next Step

After the review is complete and the artifact is saved, proceed:

**If `autopilot == true` (or `plan_approval == "auto"`) and no blocking issues found:** Proceed directly to the next pending skill. Show: `Autopilot: review complete (X findings, 0 blocking). Running /security...`

**If autopilot and blocking issues found:** Stop and ask the user to resolve. Show the blocking issues and wait. After resolution, continue autopilot.

**Otherwise:** Read the next action from session state. Do not encode the wording here:

```bash
~/.claude/skills/nanostack/bin/next-step.sh --json
```

Use `.user_message` for the prose to show the user (it is profile-aware). Use `.next_phase` to know which phase comes next.

The legacy positional form (`next-step.sh review`) still works and emits a space-separated list of pending phases for the autopilot logging line below; prefer `--json` for everything else.

When `profile == "guided"`, also include the four blocks from `reference/session-state-contract.md` (what was checked, safe to try, one next action, what remains unverified) at the top of the user-facing output.

## Final Headline

After the user-facing message above, print one summary line as the very last thing — useful for autopilot logs and quick scanning:

```
[review] OK: <N findings, M blocking>. Next: <first pending skill or "/ship">.
```

Use `WARN` instead of `OK` if there are any blocking findings.

## Gotchas

- **If you find zero issues, say so.** Don't manufacture findings to look thorough. "This looks correct and well-structured" is a valid review.
- **Don't inflate severity.** A missing comment is not "Should Fix." A style preference is not "Blocking." Calibrate honestly.
- **Don't review code you haven't read in context.** If a function changed, read the callers. If a type changed, check all usages.
- **Don't flag style issues that aren't established in the codebase.** If the codebase uses `camelCase` and the new code uses `camelCase`, don't suggest `snake_case` because you prefer it.
- **Don't suggest refactors that aren't related to the change.** "While you're here, you should also..." is scope creep. File a separate issue.
- **Scale adversarial effort by diff size.** A 10-line utility function doesn't need a threat model. A new API endpoint does.
- **Scope drift is informational, not punitive.** Drift happens for good reasons. The point is visibility, not blocking.

## Telemetry finalize

Before returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" review success
unset _F
```

Pass `abort` or `error` instead of `success` if the review did not complete normally.

## Hook: Security Suggestion

The `review/bin/suggest-security.sh` hook runs after Bash tool uses during review. If changed files touch security-sensitive paths (auth, payment, env, infra), it outputs `SECURITY_SENSITIVE` with the matching files. When this happens, suggest running `/security` before `/ship`.
