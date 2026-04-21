---
name: compound
description: Document what you learned during this sprint. Reads artifacts, writes structured solutions to know-how/solutions/. Run after /ship or after fixing a significant bug. Triggers on /compound.
concurrency: write
depends_on: [ship]
summary: "Knowledge capture. Documents bugs, patterns, decisions from sprint artifacts."
estimated_tokens: 250
---

# /compound - Knowledge Compounding

After a sprint or a significant fix, extract what you learned into structured, searchable documents. Next time the agent plans or reviews, it finds these automatically.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" compound
unset _P
```

## When to run

- After `/ship` completes a sprint
- After fixing a bug that took significant investigation
- After making an architecture decision worth remembering
- After discovering a pattern that should be reused

## Process

### 1. Read the sprint artifacts

Resolve all sprint phase artifacts in one call:

```bash
~/.claude/skills/nanostack/bin/resolve.sh compound
```

The output is JSON with `upstream_artifacts` containing paths for think, plan, review, security, qa, and ship artifacts (only those that exist within the last 2 days). Read what's available. Focus on:
- `/review` findings that were fixed (these are bugs worth documenting)
- `/security` findings that were resolved (these are patterns worth remembering)
- `/think` scope decisions (these are decisions worth recording)
- `/qa` failures that were debugged (these are bugs with investigation trails)

### 2. Identify what's worth capturing

Not everything needs a solution document. Capture:
- Bugs that took more than a trivial fix (the investigation is the value)
- Patterns you want the agent to follow in future sprints
- Architecture decisions with trade-offs that someone might question later

Skip:
- Typos, formatting, trivial fixes
- Standard library usage (the docs are better)
- Findings that were auto-fixed with no investigation

### 3. Check for existing solutions

Before creating a new document, search for related ones:

```bash
~/.claude/skills/nanostack/bin/find-solution.sh "relevant keywords"
~/.claude/skills/nanostack/bin/find-solution.sh --tag relevant-tag
~/.claude/skills/nanostack/bin/find-solution.sh --file affected/file/path
```

If a closely related solution exists:
- **Update it** if the new information extends or corrects the existing document
- **Create a new one** if it's a different problem that happens to share keywords

Do not create duplicates. One good document beats two partial ones.

**When updating an existing solution, evolve it:**
1. **Rewrite the compiled truth.** Read the current Problem, Solution, and Prevention sections. Do they reflect what you know NOW, or what you knew when the document was created? If the new sprint changed your understanding, rewrite these sections completely — don't append to them. The compiled truth must always reflect the current best understanding, not a history of partial fixes.
2. Increment `applied_count` in the frontmatter
3. Set `validated: true` and `last_validated` to today's date
4. **Adjust confidence** (1-10 scale): if the solution worked perfectly this sprint → set to current + 2 (cap 10). If it worked with adjustments → keep current. If it failed or needed major changes → set to current - 2 (floor 1). Confidence determines search ranking: high-confidence solutions surface first.
5. Append a `### YYYY-MM-DD — Context` entry to the `## History` section at the bottom, documenting what happened in this sprint and what changed

**Compiled truth is rewritten. Timeline is appended.** The sections above History always reflect the latest understanding. The History section is the immutable evidence trail of how that understanding evolved. If old information was wrong, rewrite the compiled truth — don't leave stale text. The History entry records what changed and why.

### 4. Write solution documents

For each significant learning, create a document:

```bash
~/.claude/skills/nanostack/bin/save-solution.sh <type> "<title>" "tag1,tag2,tag3"
```

Types:
- `bug` - a problem you encountered and solved
- `pattern` - a recurring approach worth remembering
- `decision` - an architecture or design choice with rationale

The script creates the file with YAML frontmatter and section templates. Fill in every section. Be specific:

**Good:**
```markdown
## Problem
Stripe webhook endpoint accepted POST without signature verification.
stripe.webhooks.constructEvent() requires the raw request body, not parsed JSON.

## Solution
Use express.raw() middleware on the webhook route before express.json() parses it.
```

**Bad:**
```markdown
## Problem
Webhook was broken.

## Solution
Fixed the webhook handler.
```

The value is in the detail. A future agent reading this needs enough context to apply the solution without re-investigating.

### 5. Update frontmatter

After filling in the body, update the frontmatter:
- `files`: add the actual file paths involved
- `severity`: adjust based on actual impact (critical, high, medium, low)
- `tags`: add any tags that would help future search

### 6. Report

Print a summary of what was captured:

```
Compound: 3 solutions captured

  bug/stripe-webhook-signature.md (high) - Stripe webhook missing signature verification
  pattern/api-error-handling.md (medium) - Structured error responses with codes
  decision/auth-clerk-over-custom.md (medium) - Chose Clerk over custom auth

Total solutions in project: 12
```

After reporting, save the artifact. Run this command now — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh compound '<json with phase, summary including solutions_created, solutions_updated, total_solutions, context_checkpoint including summary, key_files, decisions_made, open_questions>'
```

### 7. Check graduation candidates

After saving solutions, check if any existing solutions now meet graduation criteria:

```bash
~/.claude/skills/nanostack/bin/graduate.sh
```

If candidates exist, report them:

```
N solutions ready to graduate into skill files.
Run `graduate.sh --apply` to promote them, or review with `graduate.sh` (dry-run).
```

Graduation means a proven, validated solution gets baked directly into a SKILL.md file — no more runtime lookup needed. Only solutions with 3+ applications, validated status, and existing referenced files qualify.

### 8. Check stale diarizations

If `.nanostack/know-how/diarizations/` exists, check whether this sprint touched files covered by any existing diarization. If so, the diarization may be stale — suggest re-running it:

```
Diarization for <subject> is N days old and this sprint modified files it covers.
Consider re-running: /investigate --diarize <subject>
```

Then tell the user:

> Knowledge captured. These solutions will be found automatically by /nano during planning and /review during code review.

## Telemetry finalize

Before returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" compound success
unset _F
```

Pass `abort` or `error` instead of `success` if compound did not complete normally.

## Rules

- **One problem per document.** Don't combine unrelated fixes into one solution.
- **Fill every section.** Empty sections are noise. If "What didn't work" is empty, either you fixed it on the first try (rare, skip the document) or you forgot to write it down.
- **Use the exact file paths.** `src/api/webhooks/stripe.ts` is searchable. "The webhook file" is not.
- **Tags are for search, not decoration.** Use terms someone would grep for: `stripe`, `webhooks`, `hmac`, not `payment-processing-integration`.
- **Set severity accurately.** Solutions are ranked by severity when searched. Don't leave everything as medium.
- **Update, don't duplicate.** If ~/.claude/skills/nanostack/bin/find-solution.sh returns a close match, update that document.
- **The Prevention section is the highest-value section.** A bug fix helps once. A prevention rule helps every future sprint.
