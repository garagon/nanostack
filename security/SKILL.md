---
name: security
description: Use before shipping to production. Performs OWASP Top 10 audit and STRIDE threat modeling against the codebase. Supports --quick, --standard, --thorough modes. Also use when the user asks to check security, audit code, or review for vulnerabilities. Triggers on /security.
concurrency: read
depends_on: [build]
summary: "Security audit. OWASP A01-A10, STRIDE threat modeling, secrets scan, dependency audit."
estimated_tokens: 450
---

# /security — Security Audit

You think like an attacker but report like a defender. The real attack surface is rarely the code you wrote. It is the secrets in git history, the dependency you forgot to update, the CI pipeline that leaks tokens, and the AI endpoint without rate limiting. Start there, not at the application logic.

## Intensity Mode

| Mode | Flag | Scope | Confidence gate |
|------|------|-------|-----------------|
| **Quick** | `--quick` | OWASP A01-A03 (top 3) + secrets scan + dependency check | 9/10 — only verified findings |
| **Standard** | (default) | Full OWASP A01-A10 + STRIDE per component + dependencies | 7/10 — report anything with evidence |
| **Thorough** | `--thorough` | Full OWASP + STRIDE + variant analysis + conflict detection + LLM security check | 3/10 — flag tentative findings marked as TENTATIVE |

Auto-suggest:
- Pre-commit on small changes → suggest `--quick`
- Pre-ship standard feature → `--standard` (default)
- Pre-ship auth/payment/infra, or first audit of a codebase → suggest `--thorough`

**Thorough-only features:**
- **Variant analysis:** When a finding is VERIFIED, search the entire codebase for the same pattern. One confirmed SQL injection means there may be more.
- **Conflict detection:** Cross-reference with `/review` artifacts in `.nanostack/review/` for contradictions.
- **TENTATIVE findings:** Below confidence gate but worth noting. Mark as `TENTATIVE: <description>`.

## Setup (first run per project)

**Read the plan artifact** if one exists:

```bash
~/.claude/skills/nanostack/bin/find-artifact.sh plan 2
```

If found:
- **`planned_files[]`** → focus your audit on these files and their dependencies. Deeper analysis on fewer files is better than shallow analysis on everything.
- **`risks[]`** → treat each planned risk as a security hypothesis to verify. If the plan says "AWS SDK version compatibility" is a risk, check for insecure SDK usage patterns.

Then read project config: `bin/init-config.sh`. Use `detected` to scope which checks to run (skip Python checks in a Go project). Use `preferences.conflict_precedence` for cross-skill conflicts.

Then check if `security/config.json` exists. If not, ask the user to classify the project:

```
What type of project is this?
1. Public-facing (users/customers on the internet)
2. Internal (employees/team only, no public access)
3. Compliance-driven (fintech, health, regulated)
4. Library/SDK (consumed by other developers)
```

Store the answer:

```json
// security/config.json
{
  "project_type": "public_facing",
  "conflict_precedence": "security > review > qa",
  "configured_at": "2026-03-25"
}
```

This determines:
- **Conflict precedence:** public_facing → security wins. internal → review wins. compliance → security wins hard.
- **Default intensity:** public_facing/compliance → suggest `--thorough` on first audit. internal/library → `--standard`.
- **OWASP priority:** public_facing → A01, A03, A07 first. internal → A02, A05, A09 first.

If config already exists, read it and skip setup.

## Process

### 1. Detect Stack

Auto-detect everything. Do NOT ask the user.

- `package.json` → Node.js (check for next, express, fastify, hono)
- `requirements.txt` / `pyproject.toml` → Python (flask, django, fastapi)
- `go.mod` → Go (gin, echo, chi)
- Database deps: prisma, drizzle, mongoose, sqlalchemy, gorm
- BaaS: supabase, firebase, convex
- Auth: next-auth, clerk, passport, lucia, jwt
- AI/LLM: openai, anthropic, langchain, vercel ai sdk
- Payments: stripe, paddle
- Infra: `Dockerfile`, `docker-compose.yml`, `.github/workflows/`

Report one-line: `Detected: Next.js 14 + Prisma + Stripe, Docker, GitHub Actions`

### 2. Scan

**CORE (always run):** secrets, injection, auth, config, dependencies, data-exposure.

**CONDITIONAL (only if detected):** AI/LLM endpoints, payment webhook verification, Docker misconfig, CI/CD pipeline security, file upload handling.

For extended check patterns, reference the OWASP checklist at `security/references/owasp-checklist.md`.

Read `security/references/owasp-checklist.md` for the OWASP A01-A10 framework.

#### Secrets Scan (CRITICAL — always first)

Search for hardcoded credentials using regex patterns:

| Pattern | What |
|---------|------|
| `AKIA[0-9A-Z]{16}` | AWS access key |
| `sk_live_[a-zA-Z0-9]{24,}` | Stripe live key |
| `sk-proj-[a-zA-Z0-9\-_]{20,}` | OpenAI project key |
| `sk-ant-[a-zA-Z0-9\-_]{80,}` | Anthropic key |
| `ghp_[a-zA-Z0-9]{36}` | GitHub PAT |
| `-----BEGIN (RSA\|EC\|OPENSSH) PRIVATE KEY` | Private key in code |
| `(postgres\|mysql\|mongodb\+srv):\/\/[^:\s]+:[^@\s]+@` | DB connection string with password |

**Context rules:** In `*.test.*`, `*.example`, `README*`, or values containing `xxx`, `TODO`, `placeholder` → downgrade to INFO.

**Git history check (mandatory):**
```bash
git log --all --oneline -- '.env' '.env.local' '*.pem' '*.key' 2>/dev/null | head -10
```
If results: secrets may be in history even if currently gitignored. **CRITICAL** — credentials must be rotated.

**IMPORTANT: Credential redaction.** When reporting secrets, NEVER show the full value. First 4 chars + `****` (e.g., `sk-pr****`).

#### CI/CD Pipeline Security (if `.github/workflows/` exists)

| Check | What to look for |
|-------|-----------------|
| Unpinned actions | `uses: action@main` instead of `uses: action@sha256` |
| `pull_request_target` | Runs with write access on fork PRs — code injection vector |
| Secrets in logs | `echo ${{ secrets.* }}` or debug mode exposing secrets |
| Overpermissioned `GITHUB_TOKEN` | `permissions: write-all` when only `contents: read` needed |

#### AI/LLM Security (if AI deps detected)

| Check | What to look for |
|-------|-----------------|
| API keys in client bundle | `NEXT_PUBLIC_OPENAI`, `NEXT_PUBLIC_ANTHROPIC` |
| Prompt injection | User input interpolated into system prompts (`prompt + req.body`) |
| Missing rate limiting | AI endpoints without rate limiter — attacker runs up your bill |
| Unsanitized LLM output | LLM response rendered as HTML without escaping |

### 3. False Positive/Negative Awareness

**False positives (skip):** `.env.example`, `sk_test_` keys, UUIDs, React default output, `eval()` in build configs, `0.0.0.0` in Docker, SQL in migrations.

**False negatives (don't miss):** Auth on route but not on query (IDOR), secrets in git history, rate limiting on login but not password reset, SSRF via URL params to `169.254.169.254`, `dangerouslySetInnerHTML` without DOMPurify.

### 4. STRIDE per component

Spoofing (impersonation?), Tampering (data integrity?), Repudiation (audit trail?), Info Disclosure (leaks?), DoS (overwhelm?), Elevation (privilege escalation?).

### 4. Produce Report

Report findings progressively. Don't wait until the end. As each phase completes, output its findings immediately so the user sees work happening.

Open with a summary line:
```
Security: CRITICAL (0) HIGH (1) MEDIUM (2) LOW (1) = 4 findings. Score: B
```

Scoring: A = 0 critical, 0 high, ≤3 medium. B = 0 critical, 1-2 high. C = 3+ high. D = 1-2 critical. F = 3+ critical.

Use `security/templates/security-report.md` for the full structure. Every finding must include:
- **What** the vulnerability is (specific, not vague)
- **Where** it exists (file path and line number)
- **How** to exploit it (proof of concept or clear scenario)
- **Fix** with actual code, before and after (not "consider sanitizing input")
- **Severity** using the classification below

Always close with **What's solid**: 2-3 specific things the codebase does well on security. Not filler. If the auth is well implemented, say so and say why.

## Severity Classification

Severity: Critical (RCE, unauth admin, hardcoded creds), High (stored XSS, IDOR, privilege escalation), Medium (CSRF, info disclosure, missing rate limit), Low (headers, verbose errors, outdated non-vulnerable deps).

## Conflict Detection

Always check for conflicts with prior `/review` findings if a review artifact exists:

```bash
~/.claude/skills/nanostack/bin/find-artifact.sh review 30
```

Read `reference/conflict-precedents.md` for known conflict patterns. When detected, mark inline:
```
### SEC-005: Excessive error detail
**Conflicts with:** REV-003 → RESOLUTION: structured errors (code + generic msg to user, details to logs)
```

In `--quick` mode, apply default precedence (security > review) without documenting.
In `--standard` mode, document conflicts inline.
In `--thorough` mode, document conflicts AND flag as BLOCKING until user confirms.

After completing the audit and conflict detection, save the artifact. Run this command now — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh --from-session security 'N findings (X critical). OWASP: covered A01-A10. Conflicts: none/N.'
```

Or pass full JSON for richer detail:
```bash
~/.claude/skills/nanostack/bin/save-artifact.sh security '<json with phase, mode, summary, findings, conflicts, context_checkpoint>'
```

## Mode Summary

| Aspect | Quick | Standard | Thorough |
|--------|-------|----------|----------|
| OWASP scope | A01-A03 only | Full A01-A10 | Full + variant analysis |
| STRIDE | Skip | Per component | Per component + attack trees |
| Dependencies | `npm audit` only | Full scan | Full + license check |
| Conflict detection | Auto-resolve | Document inline | BLOCKING until resolved |
| Tentative findings | Skip | Skip | Report as TENTATIVE |
| Confidence gate | 9/10 | 7/10 | 3/10 |

## Next Step

After the security audit is complete and the artifact is saved:

**If AUTOPILOT is active and no critical/high findings:** Proceed to next pending skill (`/qa` or `/ship`). Show: `Autopilot: security grade X (0 critical, 0 high). Running /qa...`

**If AUTOPILOT is active but critical or high findings found:** Stop and ask the user to review. Show the findings and wait. After resolution, continue autopilot.

**Otherwise:** Tell the user:
> Security audit complete. Remaining steps:
> - `/review` to run code review (if not done yet)
> - `/qa` to test that everything works (if not done yet)
> - `/ship` to create the PR (after review, security and qa pass)

## After Fixes

When the model or user fixes security findings, do NOT re-run the full audit. Instead:

- **CRITICAL/HIGH fixes:** Re-audit only the affected files and the specific vulnerability class. Verify the fix resolves the finding. Save a new artifact.
- **MEDIUM/LOW fixes:** Verify the specific fix by reading the changed code. No re-audit needed. Do not save a new artifact — the original audit with the fix note is sufficient.

Re-running the full OWASP scan after fixing a missing Content-Type header wastes time and tokens. Target the verification.

## Gotchas

- **Zero findings is valid.** Don't manufacture findings.
- **Don't inflate severity.** Calibrate to actual exploitability.
- **Show evidence.** Input path, sink, missing sanitization. Not "could be vulnerable."
- **Run dependency scanning.** `npm audit`, `pip audit`, `go vuln check`.
- **Auth ≠ authz.** Logged in ≠ has permission.
- **Check git history for secrets.** `git log -p --all -S 'password\|secret\|key\|token'`
- **Variant analysis in `--thorough`.** One finding = search for the pattern elsewhere.

