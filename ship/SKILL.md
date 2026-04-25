---
name: ship
description: Use when code is ready to ship — creates PRs, merges, deploys, and verifies. Handles the full PR-to-production pipeline. Triggers on /ship.
concurrency: exclusive
depends_on: [review, qa, security]
summary: "Release pipeline. PR creation, CI monitoring, post-deploy verification, rollback plan."
estimated_tokens: 350
hooks:
  PreToolUse:
    - matcher: Bash
      command: "./ship/bin/pre-ship-check.sh"
---

# /ship — Ship to Production

You get code from "done" to "verified in production" in one pass. You own the full pipeline: pre-flight, PR, CI, deploy, verification. If something breaks after merge, you rollback first and debug second.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" ship
unset _P
```

## Local Mode

Run `source bin/lib/git-context.sh && detect_git_mode`.

**If `local` (no git repo):** Skip the entire PR/CI/deploy flow below. Instead:
1. Run `ship/bin/quality-check.sh` (already works without git).
2. Verify files from the plan exist and are non-empty.
3. Detect project type and show the result immediately:
   - HTML → run `open index.html` (or the main HTML file) so the user sees it instantly. Then say "Se abrió en tu navegador."
   - Python → "Corré: python3 main.py"
   - Node → "Corré: npm start y abrí localhost:3000"
   - Other → "Tu proyecto está en [ruta completa]"
4. If the user wants to publish: suggest drag-and-drop hosting (Netlify, Vercel). Walk through it step by step.
5. Save artifact and run compound as normal.
Never mention PR, CI, branch, merge, deploy, rollback, or slash commands. Output: "Listo. Para verlo: [comando]."

**If `local-git` (git, no remote):** Run pre-ship check and quality check. Skip PR/CI/deploy. Suggest `git tag` for versioning. Output: "Listo. Commit: [hash]."

**If `full`:** Continue with the normal process below.

## Process

### 1. Pre-flight Check

Run both checks before proceeding:

```bash
ship/bin/pre-ship-check.sh    # uncommitted changes, missing tests, staged secrets, branch check
ship/bin/quality-check.sh     # broken README links, stale references, writing quality, secrets in diff
```

If either reports errors, fix them before proceeding. Warnings are informational but should be reviewed.

**Resolve context and verify review findings were resolved:**

```bash
~/.claude/skills/nanostack/bin/resolve.sh ship
```

The output is JSON with `upstream_artifacts` (review, security, qa paths). If a review artifact exists, read it and check that all **blocking** findings have been addressed. For each blocking finding, verify the code at the reported file and line no longer has the issue. If a blocking finding is still present, do NOT proceed. Flag it.

Then verify:

```bash
# Are there uncommitted changes?
git status

# Do tests pass?
# (use the project's test command — check package.json, Makefile, etc.)

# Is the branch up to date with the target?
git fetch origin && git log --oneline HEAD..origin/main | head -5
```

If tests fail, fix them first. Do not ship broken code with a "will fix later" comment.

If the branch is behind, rebase or merge:
```bash
git rebase origin/main  # preferred for clean history
# or
git merge origin/main   # if rebase would be messy
```

### 2. PR Preview (mandatory stop)

Before creating the PR, show the user a full preview. This is a mandatory stop because after creation it's public.

```
## PR Preview

**Title:** {{title}}
**Branch:** {{branch}} → {{base}}
**Files changed:** {{count}}

### Summary
{{1-3 bullets of what changed and why}}

### Changes
{{file list with one-line description each}}

### Test plan
{{how to verify}}
```

Wait for user approval. Only proceed after explicit confirmation. If the user adjusts something, update the preview and ask again.

### 3. Create PR

After approval, use the template at `ship/templates/pr-template.md` for the PR body.

```bash
gh pr create \
  --title "{{concise title, under 70 chars}}" \
  --body "$(cat <<'EOF'
{{filled PR template}}
EOF
)"
```

**PR title rules:**
- Under 70 characters
- Start with a verb: Add, Fix, Update, Remove, Refactor
- Describe the what, not the how
- No ticket numbers in the title (put them in the body)

**PR body rules:**
- Summary: 1-3 bullet points of what changed and why
- Test plan: how to verify this works
- Link to related issues/tickets

### 4. Monitor CI

After creating the PR, check CI status:

```bash
gh pr checks <number> --watch
```

If CI fails:
- Read the failure log: `gh pr checks <number> --fail-only`
- Fix the issue and push
- Do not retry without understanding the failure
- If a test is genuinely flaky (not caused by your change), note it in the PR

### 5. Post-Merge Verification

After the PR is merged:

```bash
# Verify merge completed
gh pr view <number> --json state,mergedAt

# Check deploy pipeline
gh run list --limit 3
```

If the project has a staging/production URL, run a **post-deploy checklist:**

1. **Smoke test:** Does the changed feature work? (manual or `/qa --quick` against prod URL)
2. **Error check:** `gh run view --log-failed` — any new errors in the deploy?
3. **Side effects:** Did anything else break? Check the pages/endpoints adjacent to your change.
4. **Metrics:** If monitoring exists (Grafana, Datadog, CloudWatch), check error rate and latency for 5 minutes post-deploy. Any spike > 2x baseline → investigate before moving on.

If any check fails: **stop and rollback** before debugging. A broken prod is worse than a reverted feature.

### 6. Rollback Plan

If something goes wrong after deploy:

```bash
# Quick rollback: revert the merge commit
git revert <merge-commit-sha> --mainline 1
gh pr create --title "Revert: {{original PR title}}" --body "Reverting due to {{reason}}"
```

Document what went wrong for the team.

### 7. Repo Quality Standards

Before creating the PR, verify the standards in `ship/references/repo-quality-standards.md` (README links, PR/commit quality, repo hygiene). The public repo is the face of the project. `ship/bin/quality-check.sh` automates the checks it can; use judgment for the rest.

After shipping, do these steps in order:

**Step 1: Save the artifact.** Run this command now — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh --from-session ship 'PR #N: title. Status: merged/open. CI: passed/failed.'
~/.claude/skills/nanostack/bin/sprint-journal.sh
```

Or pass full JSON for richer detail:
```bash
~/.claude/skills/nanostack/bin/save-artifact.sh ship '<json with phase, summary including pr_number, pr_url, title, status, ci_passed, context_checkpoint>'
~/.claude/skills/nanostack/bin/sprint-journal.sh
```

**Step 2: Proof block.** Before "How to see the result", emit a proof block summarizing what was verified during the sprint. Read it from session phase_log:

```bash
SESSION=$NANOSTACK_STORE/session.json
[ -f "$SESSION" ] || SESSION="$HOME/.nanostack/session.json"
jq -r '
  ([.phase_log[]? | select(.phase == "review"   and .status == "completed")] | length) as $rev   |
  ([.phase_log[]? | select(.phase == "security" and .status == "completed")] | length) as $sec   |
  ([.phase_log[]? | select(.phase == "qa"       and .status == "completed")] | length) as $qa    |
  "Reviewed: \(if $rev   > 0 then "yes" else "no" end)\n" +
  "Security checked: \(if $sec > 0 then "yes" else "no" end)\n" +
  "QA checked: \(if $qa  > 0 then "yes" else "no" end)"
' "$SESSION" 2>/dev/null
```

If a phase says `no`, list it under "Not verified" so the user sees what was skipped instead of inferring it from absence.

**Step 3: How to see the result.**

Read `profile` from session per `reference/session-state-contract.md`. The branch differs by profile:

**If `profile == "guided"` (or no git remote, even when professional):** Skip the deployment menu and focus on how to try the result locally. Tell the user where the entry point is and the exact command to run, then list anything that is not yet verified (e.g. "I did not deploy this to the internet"). One next action only.

**If `profile == "professional"` and `autopilot == true`:** Skip this question. Go directly to Next Step (compound + sprint summary). The user will decide how to run it after the sprint closes.

**Otherwise (professional, manual)**, ask:
> How do you want to see it?
> 1. Local — I'll start the server and show you how to open it
> 2. Production — I'll guide you through deploying to the internet
> 3. I'm done — just the commit

**If Local (option 1):**
- HTML files: "Open `index.html` in your browser"
- Web apps: start the server (`npm start`, `node src/server.js`, etc.) and tell the user the URL
- CLI tools: show the command to run it
- Never auto-open URLs or execute `open` commands. Show the path and let the user decide.

**If Production (option 2):**
Detect project type, recommend ONE provider (Next.js→Vercel, Node→Railway, Static→Cloudflare Pages, Python→Railway, Go→Fly.io). Walk through: account, connect repo, env vars, push. Mention domain (~$10/yr), SSL (automatic), monitoring (Sentry free + UptimeRobot free). Show monthly cost.

**If Done (option 3):** Skip to next features.

## Output Format

Close with a summary:
```
Ship: PR #N created. CI passed.
Tests: X → Y (+N new). No regressions.
```

Include before/after test counts when tests were added. Quantify the improvement.

## Gotchas

- **Run tests before creating PR.** CI is slower than catching it locally.
- **One PR = one concern.** Split unrelated changes.
- **Check existing PRs before creating yours.** Search first.
- **Read CONTRIBUTING.md.** Every project has different rules.

## Telemetry finalize

Before handing off to compound or the user:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" ship success
unset _F
```

Pass `abort` or `error` instead of `success` if ship did not complete normally.

## Next Step

After shipping, two things happen in order:

**First: capture learnings.** Run compound immediately:

```
Use Skill tool: skill="compound"
```

Do not ask. Do not skip. Compound reads the sprint artifacts and saves solutions for future sprints.

**Then: close the sprint.** This is the last thing the user sees. Make it count.

**1. What was built.** Summarize what the user now has in plain language. Not phase names or artifact counts. What does the thing DO, where is it, and how to use it.

**2. How to use it.** Show the exact command or URL to try it right now.

**3. What could come next.** Suggest 2-3 concrete extensions as `/feature` commands the user can run immediately.

Example:

> Sprint complete. You have a JSON validator CLI.
>
> Try it: `node src/index.js test.json`
>
> Ideas for the next feature:
> - `/feature Add --format flag to pretty-print valid JSON`
> - `/feature Add directory mode: jsonlint schemas/*.json`
> - `/feature Add --fix mode that auto-corrects trailing commas`
