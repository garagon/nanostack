---
name: ship
description: Use when code is ready to ship — creates PRs, merges, deploys, and verifies. Handles the full PR-to-production pipeline. Triggers on /ship.
hooks:
  PreToolUse:
    - matcher: Bash
      command: "./ship/bin/pre-ship-check.sh"
---

# /ship — Ship to Production

You get code from "done" to "verified in production" in one pass. You own the full pipeline: pre-flight, PR, CI, deploy, verification. If something breaks after merge, you rollback first and debug second.

## Process

### 1. Pre-flight Check

Run both checks before proceeding:

```bash
ship/bin/pre-ship-check.sh    # uncommitted changes, missing tests, staged secrets, branch check
ship/bin/quality-check.sh     # broken README links, stale references, writing quality, secrets in diff
```

If either reports errors, fix them before proceeding. Warnings are informational but should be reviewed.

**Verify review findings were resolved:**

```bash
bin/find-artifact.sh review 2
```

If a review artifact exists, check that all **blocking** findings have been addressed. For each blocking finding, verify the code at the reported file and line no longer has the issue. If a blocking finding is still present, do NOT proceed. Flag it.

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

Before creating the PR, verify these standards. The public repo is the face of the project.

**README:**
- All internal links resolve (check every `[text](path)` reference)
- No stale command names or paths from previous versions
- No AI writing tells: em dashes, en dashes, Oxford commas
- Examples are accurate and runnable
- Install instructions work on a clean machine

**PR quality:**
- Title under 70 characters, starts with a verb
- Body explains what changed and why, not just what files were touched
- Test plan is specific enough that someone else could verify it
- No "Generated with" badges or AI attribution

**Commit quality:**
- Commit messages explain the why, not just the what
- One concern per commit when possible
- No AI attribution in commit messages

**Repo hygiene:**
- No secrets in the diff (API keys, tokens, passwords)
- No large binary files committed
- .gitignore covers editor files, OS files, build artifacts

`ship/bin/quality-check.sh` automates the checks it can. Use your judgment for the rest.

## Save Artifact and Generate Sprint Journal

After shipping, persist the result and generate the sprint journal:

```bash
bin/save-artifact.sh ship '<json with phase, summary including pr_number, pr_url, title, status, ci_passed>'
bin/sprint-journal.sh
```

The sprint journal reads all phase artifacts (think, plan, review, qa, security, ship) and writes a single entry to `.nanostack/know-how/journal/`. This happens automatically on every successful ship.

The user can disable auto-saving by setting `auto_save: false` in `.nanostack/config.json`.

## Output

After shipping, close with a summary:
```
Ship: PR #42 created. CI passed. Deployed. Smoke test clean.
Tests: 42 → 51 (+9 new). No regressions.
Journal: .nanostack/know-how/journal/2026-03-25-myproject.md
```

Include before/after test counts when tests were added during the sprint. Quantify the improvement.

## Gotchas

- **Don't create a PR without running tests locally.** CI catching your bugs is slower than you catching them.
- **Don't force-push to a branch with open review comments.** It destroys the review context. Push new commits instead.
- **Don't merge your own PR without review** unless it's a trivial fix (typo, config) and the team norm allows it.
- **Don't deploy on Friday afternoons.** Unless you want to debug on Saturday morning. If the user insists, note the risk.
- **One PR = one concern.** If your PR does two unrelated things, split it. The review will be faster and the rollback will be cleaner.
- **Draft PRs are useful.** If the code isn't ready for review but you want CI to run, create a draft: `gh pr create --draft`

## Anti-patterns (from real usage)

These were discovered from shipping real PRs:

- **Creating PRs without checking existing work.** Submitted a PR to FastAPI without realizing 8 other PRs existed for the same issue, including one the maintainer preferred. Always search first.
- **Skipping PR Preview.** A PR went out with "Fixes #4060" as the only body text. The project required What/Why/Before-After/Tests/AI disclosure. PR Preview catches this.
- **Pushing directly to main.** Every change should go through a PR regardless of size. Clean history, reviewable changes.
- **Not reading CONTRIBUTING.md.** Every project has different rules. Some require video evidence, some require specific naming conventions, some have line limits. Read the rules before writing the PR.
- **CI checks that only maintainers resolve.** Label checks, CLA checks, approval gates. These will fail on your PR and there's nothing you can do. Know which checks you own and which you don't.

## Next Step

After shipping, the sprint is complete. Tell the user:

> Sprint complete. PR created. Journal generated at .nanostack/know-how/journal/.
>
> Run `bin/analytics.sh` to see trends across sprints.
