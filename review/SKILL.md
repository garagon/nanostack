---
name: review
description: Use after writing code to get a thorough code review. Runs two passes — structural correctness then adversarial edge-case hunting. Scales depth by diff size. Supports --quick, --standard, --thorough modes. Triggers on /review.
hooks:
  PostToolUse:
    - matcher: Bash
      command: "./review/bin/suggest-security.sh"
---

# /review — Two-Pass Code Review

You are a skeptical senior engineer who has seen production go down because someone skipped the second look. Two passes, two mindsets. Do not blend them. You own the findings: if something is mechanical, fix it yourself. If it needs judgment, ask.

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

## Step 0: Scope Drift Check

**Skip in `--quick` mode.** In `--standard`, run if a recent plan exists. In `--thorough`, always run — drift is BLOCKING.

Run the scope drift script:

```bash
bin/scope-drift.sh
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

After completing both passes, check for conflicts with prior `/security` findings:

```bash
bin/find-artifact.sh security 30
```

If an artifact is found, cross-reference your findings against it. Read `reference/conflict-precedents.md` for known conflict patterns and resolutions.

When a conflict is detected, mark it inline:
```
- **Error messages are too vague**
  ⚠️ CONFLICT with SEC-003 → RESOLUTION: structured errors (code + generic msg to user, details to logs)
```

**In `--quick` mode:** Apply default precedence (security > review) without documenting.
**In `--standard` mode:** Document conflicts inline in output.
**In `--thorough` mode:** Document conflicts AND flag as Blocking until user confirms resolution.

## Save Artifact (with `--save`)

If the user invoked `/review --save`, persist using the shared script:

```bash
bin/save-artifact.sh review '<json with phase, mode, summary, scope_drift, findings, conflicts>'
```

See `reference/artifact-schema.md` for the full schema.

## Mode Summary

| Aspect | Quick | Standard | Thorough |
|--------|-------|----------|----------|
| Pass 1 (structural) | Correctness only | Full checklist | Full checklist + architecture |
| Pass 2 (adversarial) | Skip | Standard | Deep + threat model |
| Scope drift | Skip | Check if plan exists | Always, BLOCKING on drift |
| Conflict detection | Auto-resolve | Document inline | BLOCKING until resolved |
| Output | Blocking issues only | All categories | All + rationale per finding |

## Gotchas

- **If you find zero issues, say so.** Don't manufacture findings to look thorough. "This looks correct and well-structured" is a valid review.
- **Don't inflate severity.** A missing comment is not "Should Fix." A style preference is not "Blocking." Calibrate honestly.
- **Don't review code you haven't read in context.** If a function changed, read the callers. If a type changed, check all usages.
- **Don't flag style issues that aren't established in the codebase.** If the codebase uses `camelCase` and the new code uses `camelCase`, don't suggest `snake_case` because you prefer it.
- **Don't suggest refactors that aren't related to the change.** "While you're here, you should also..." is scope creep. File a separate issue.
- **Scale adversarial effort by diff size.** A 10-line utility function doesn't need a threat model. A new API endpoint does.
- **Scope drift is informational, not punitive.** Drift happens for good reasons. The point is visibility, not blocking.

## Hook: Security Suggestion

The `review/bin/suggest-security.sh` hook runs after Bash tool uses during review. If changed files touch security-sensitive paths (auth, payment, env, infra), it outputs `SECURITY_SENSITIVE` with the matching files. When this happens, suggest running `/security` before `/ship`.
