---
name: qa
description: Use to verify that code works correctly — browser-based testing with Playwright, CLI testing, API testing, or root-cause debugging. Supports --quick, --standard, --thorough modes. Triggers on /qa.
---

# /qa — Quality Assurance & Debugging

You test like a real user and fix like an engineer. Click everything, fill every form, check every state. When you find a bug, you own it: fix it with an atomic commit, re-verify, and move on. If a fix touches more than it should, stop and report instead.

## Intensity Mode

If the user specifies a mode flag, use it. Otherwise, check `bin/init-config.sh` for `preferences.default_intensity`.

| Mode | Flag | Scope | Bug fix limit |
|------|------|-------|---------------|
| **Quick** | `--quick` | Happy path only, screenshots on failure only | Max 3 fixes |
| **Standard** | (default) | Happy path + error states + empty states | Max 10 fixes |
| **Thorough** | `--thorough` | Happy + error + edge + load + regression tests | Max 20 fixes |
| **Report only** | `--report-only` | Same scope as standard, but NO fixes | 0 — findings only |

`--report-only` can combine with any intensity: `/qa --thorough --report-only` scans everything but touches nothing. Use when you want a bug inventory without code changes.

### WTF-Likelihood Heuristic (all modes)

Track your "WTF likelihood" — the probability that further fixes will introduce regressions:

```
Start at 0%
Each revert:                  +15%
Each fix touching >3 files:   +5%
After fix 10:                 +1% per additional fix
Touching unrelated files:     +20%
If WTF > 20%: STOP immediately — report remaining bugs without fixing
Hard cap per mode: quick=3, standard=10, thorough=20
```

This prevents the agent from over-fixing and making things worse. When you hit the WTF threshold, clearly state: "Stopping fixes — WTF likelihood at X%. Remaining bugs listed below for manual triage."

## Mode Selection

Determine the testing mode from context:

| Mode | When | Approach |
|------|------|----------|
| **Browser QA** | Web application, UI changes | Playwright-based browser testing |
| **API QA** | Backend endpoints, services | curl/httpie-based request testing |
| **CLI QA** | Command-line tools | Direct execution with assertions |
| **Debug** | Known bug, error report, failing test | Root-cause investigation |

## Browser QA

Use Playwright directly — do not install a custom browser daemon. Use `qa/bin/screenshot.sh` for named screenshots. Store results in `qa/results/`.

**Coverage order:** critical path first → error states → empty states → loading states.

### Visual QA (Browser QA only)

After functional tests pass, take screenshots of every key state and analyze the UI visually. This is not optional for web apps. A feature that works but looks broken is broken.

**Take screenshots of:**
- Home/landing page
- Main feature in empty state (no data)
- Main feature with data (after adding items)
- Forms (before and after filling)
- Error states
- Mobile viewport (375px width)

**Analyze each screenshot for:**

1. **Layout**: Are elements aligned? Is spacing consistent? Are cards/sections balanced or does one side look crushed?
2. **Visual hierarchy**: Can the user tell what's most important? Are headings, buttons and actions clearly differentiated?
3. **Component quality**: Does it look like shadcn/ui or like raw HTML with borders? Are buttons, inputs, cards using proper component styling?
4. **Typography**: Is text readable? Are font sizes proportional? Is there enough contrast?
5. **Empty states**: Do empty states guide the user ("Add your first expense") or just show blank space?
6. **Responsive**: Does the layout work at mobile width or does it break/overflow?
7. **Dark mode**: If dark mode is enabled, are there contrast issues, invisible borders, or text that blends into the background?

**Cross-reference against `/nano-plan` product standards.** If the plan said "shadcn/ui + Tailwind" and the output looks like raw HTML with inline styles, that's a finding.

**Report visual findings as QA findings:**
```
- **UX/UI:** Layout imbalance on group page — members card 30% width, expenses 70%
  - **Severity:** should_fix
  - **Screenshot:** qa/results/group-page.png
  - **Fix:** Balance grid columns, make cards equal width
```

Visual findings are should_fix by default. Blocking only if the UI is unusable (overlapping elements, invisible text, broken layout at common viewport sizes).

## Debug Mode

When investigating a bug:

### 1. Reproduce
Before debugging, reproduce the issue. If you cannot reproduce it, say so — don't guess.

### 2. Isolate
Narrow the scope:
- Which commit introduced the bug? Use `git bisect` if the issue is recent.
- Which file? Use error traces, logs, and breakpoints.
- Which function? Read the code path from entry point to failure.

### 3. Root Cause
Find the actual cause, not just the symptom:
- "The API returns 500" is a symptom
- "The handler doesn't check for nil user before accessing user.email" is a root cause

### 4. Fix and Verify
- Fix the root cause, not the symptom
- Write a test that fails before the fix and passes after
- Check for the same pattern elsewhere in the codebase

## Output Format

Open with a summary line:
```
QA: 12 tests, 11 passed, 1 failed. 1 bug found, 1 fixed. WTF: 0%.
```

Then the full report:
```
## QA Results

**Target:** {{what was tested}}
**Mode:** {{Browser / API / CLI / Debug}}
**Status:** {{PASS / FAIL / PARTIAL}}

### Tests Run
1. ✅ {{test description}}
2. ❌ {{test description}} (expected: X, got: Y)

### Bugs Found
- **{{severity}}:** {{description}}
  - **Reproduce:** {{steps}}
  - **Root cause:** {{why it happens}}
  - **Fix:** {{what you changed, with commit hash}}

### What's Working
- {{2-3 specific things that work well. Not filler.}}

### Screenshots
- `qa/results/{{name}}.png` — {{description}}
```

Report progress as you go. After each test group (happy path, error states, edge cases), output results immediately. Don't wait until the end to dump everything.

## Save Artifact

Always persist the QA results after completing the run:

```bash
bin/save-artifact.sh qa '<json with phase, mode, summary including wtf_likelihood, findings>'
```

See `reference/artifact-schema.md` for the full schema. The user can disable auto-saving by setting `auto_save: false` in `.nanostack/config.json`.

## Mode Summary

| Aspect | Quick | Standard | Thorough |
|--------|-------|----------|----------|
| Test scope | Happy path only | Happy + error + empty | Happy + error + edge + load |
| Screenshots | On failure only | Key checkpoints | Every state |
| Visual QA | Skip | Main states + mobile | Every state + mobile + dark mode |
| Bug fix limit | 3 | 10 | 20 |
| Regression tests | Skip | If fixing a bug | Full regression suite |
| WTF threshold | 20% | 20% | 20% |

## Next Step

After QA is complete and the artifact is saved:

**If AUTOPILOT is active and tests pass:** Proceed to `/ship`. Show: `Autopilot: qa passed (X tests, 0 failed). Running /ship...`

**If AUTOPILOT is active but tests fail:** Stop and ask the user. Show failures and wait.

**Otherwise:** Tell the user:
> QA complete. Remaining steps:
> - `/review` to run code review (if not done yet)
> - `/security` to audit for vulnerabilities (if not done yet)
> - `/ship` to create the PR (after review, security and qa pass)

## Gotchas

- **Don't test in production.** Always verify you're hitting a local/staging environment.
- **Don't write Playwright tests that depend on specific CSS selectors.** Use `data-testid`, `role`, `text content`, or accessibility tree selectors. CSS classes change; test IDs don't.
- **Don't skip error states.** The happy path working proves very little. Error handling is where most bugs hide.
- **Don't confuse "no errors" with "working."** A page that renders without errors but shows the wrong data is still broken. Assert content, not just absence of errors.
- **Screenshots are evidence.** When a visual test passes, capture a screenshot anyway. When it fails, the screenshot is your debug tool.
- **If the test environment is flaky, say so.** Don't retry silently hoping it passes. Flakiness is a finding.
- **Respect the WTF heuristic.** When it says stop, stop. Listing remaining bugs is more valuable than introducing regressions.
