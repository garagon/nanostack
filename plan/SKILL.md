---
name: nano
description: Use when starting non-trivial work (touching 3+ files, new features, refactors, bug investigations). Produces a scoped, actionable implementation plan before any code is written. Triggers on /nano.
concurrency: read
depends_on: [think]
summary: "Implementation planning. Scopes work, names every file, produces ordered steps with verification."
estimated_tokens: 400
---

# /nano — Implementation Planning

You turn validated ideas into executable steps. Every file gets named. Every step gets a verification. Every unknown gets surfaced. The plan is a contract: if it says 4 files, the PR should touch 4 files.

## Telemetry preamble

Defensive telemetry init. No-op if telemetry is disabled via `NANOSTACK_NO_TELEMETRY=1`, `~/.nanostack/.telemetry-disabled`, or if the helpers are removed.

```bash
_P="$HOME/.claude/skills/nanostack/bin/lib/skill-preamble.sh"
[ -f "$_P" ] && . "$_P" nano
unset _P
```

## Session

If no active session exists, initialize one:

```bash
~/.claude/skills/nanostack/bin/session.sh status
```

If the output shows `"active":false`, create a session:

```bash
~/.claude/skills/nanostack/bin/session.sh init development
```

Then run `session.sh phase-start plan`.

**AUTOPILOT detection.** This skill checks "if AUTOPILOT is active" in several places below. Treat it as active when ANY of the following is true:

1. The caller (e.g. `/think --autopilot`, `/feature`) said so in context.
2. `session.json` reports it. Verify with:
   ```bash
   jq -r '.autopilot // false' .nanostack/session.json 2>/dev/null
   ```
   `true` means autopilot. Anything else means manual.

If neither is true, behave as manual: present the plan and wait for explicit approval.

**Local mode:** Run `source bin/lib/git-context.sh && detect_git_mode`. If result is `local`, adapt language: "implementation plan" → "paso a paso", "files to modify" → "archivos que vamos a crear", "architecture checkpoint" → skip (overkill for non-technical users). Present the plan as a simple numbered list of what you'll build, not a spec document. Same rigor, accessible words. In the "Next Step" section, do NOT list slash commands (/review, /security, /qa, /ship). Instead say: "Cuando termine, reviso la calidad y te aviso si hay algo que ajustar."

## Process

### 1. Understand the Request

- **Resolve context** — load upstream artifacts and past solutions in one call:
  ```bash
  ~/.claude/skills/nanostack/bin/resolve.sh plan
  ```
  The output is JSON with `upstream_artifacts` (think artifact path if recent), `solutions` (ranked matches), `config`, and `sprint_metrics` (git stats + cycle time from last sprint). Use what's relevant:
  - If a think artifact exists, read it and extract: `key_risk` → add to Risks. `narrowest_wedge` (starting point) → scope constraint. `out_of_scope` → pre-populate Out of Scope. `scope_mode` → if "reduce," plan smallest version. `premise_validated` → if false, flag it.
  - If solutions are returned, read the summaries first, then load only those relevant to the current task. Past mistakes and patterns should inform the sprint.
  - If `sprint_metrics` is present, use it for scope calibration: last sprint's lines changed and file count help estimate whether the current task is Small, Medium, or Large relative to recent work.

  **If think artifact is missing but /think ran** (you can see a Think Summary in the conversation above), recover it now:
  ```bash
  ~/.claude/skills/nanostack/bin/save-artifact.sh --from-session think 'Value prop: <from summary>. Scope: <from summary>. Wedge: <from summary>. Risk: <from summary>. Premise: <from summary>.'
  ```
  This saves the think output retroactively so /review can check scope drift and the sprint journal is complete.

- Check git history for recent changes in the affected area — someone may have already started this work or made decisions you need to respect.
- If the affected modules are known, check for diarizations (structured module briefs from past sprints) in `.nanostack/know-how/diarizations/`. If a diarization exists for a module in scope, read it for recurring issues, known risks, and unresolved tensions. These should inform your risk assessment.
- If the request is ambiguous, ask clarifying questions using `AskUserQuestion` before proceeding. Do not guess scope.
- If the user doesn't specify their tech stack and needs to pick tools (auth, database, hosting, etc.), check for overrides first, then fall back to defaults:
  1. Read `.nanostack/stack.json` if it exists (project-level preferences)
  2. Read `~/.nanostack/stack.json` if it exists (user-level preferences)
  3. Read `plan/references/stack-defaults.md` for anything not covered above
  4. If the project already has a stack (check package.json, go.mod, requirements.txt), use what's there regardless of any config.
  Suggest, don't impose. The user always has the final say.
- **Always use the latest stable version** of every dependency. Don't rely on versions from training data.

## Graduated Rules

<!-- Auto-maintained by bin/graduate.sh. Do not edit manually. -->
<!-- Each rule was promoted from a solution with 3+ applications and validation. -->
<!-- END GRADUATED RULES -->

Apply these constraints during planning. Each one represents a proven pattern or decision from past sprints.

### 2. Evaluate Scope

Classify the work:

| Scope | Criteria | Output |
|-------|----------|--------|
| **Small** | 1-3 files, single concern, clear path | Implementation steps only |
| **Medium** | 4-10 files, multiple concerns, some unknowns | Product spec + implementation steps + risks |
| **Large** | 10+ files, cross-cutting, architectural impact | Product spec + technical spec + implementation steps + phased execution |

For **small** scope: produce a brief plan and move on. Do not over-plan trivial work.

### 3. Specs (Medium/Large scope only)

Before writing implementation steps, produce the specs that define what you're building. Skip this for Small scope.

**Medium scope: Product Spec only.**
Use `plan/templates/product-spec.md`. Cover: problem, solution, user stories, acceptance criteria, user flow, edge cases, out of scope. Keep it to 1-2 pages. This is what the team reads to understand what "done" looks like.

**Large scope: Product Spec + Technical Spec.**
Also use `plan/templates/technical-spec.md`. Cover: architecture, data model, API contracts, integrations, technical decisions, security considerations, migration/rollback. This is what the team reads to understand how the system works.

Present the specs to the user before writing implementation steps. Specs are the contract. If the spec is wrong, the plan will be wrong and the code will be wrong. Get alignment here.

### 4. Write the Implementation Plan

Use the template at `plan/templates/plan-template.md` as your output structure. Fill in every section that applies to the scope level.

Key requirements:
- **Every file you will touch must be listed** — no surprises during implementation
- **Order of operations matters** — list steps in the sequence you will execute them
- **Each step must be independently verifiable** — how will you know it worked?
- **Identify what you do NOT know** — unknowns are more valuable than knowns in a plan

### 5. Architecture Checkpoint (Medium/Large scope only)

Before presenting, validate the plan against these engineering concerns:

- **Data flow:** Can you trace data from input to storage to output? If not, there's a hidden dependency.
- **Failure modes:** What happens when each external call fails? (DB down, API timeout, disk full). If the plan doesn't address this, it's incomplete.
- **Scaling bottleneck:** Is there a single point that won't handle 10x load? (synchronous loop, unbatched DB queries, in-memory state). Name it.
- **Test matrix:** For each step, what's the minimum test that proves it works? If you can't name it, the step is too vague.
- **Latent vs deterministic steps:** Classify each step. A deterministic step has a verification command that returns 0. A latent step relies on the model doing the right thing without a check. Latent is fine for taste work; for anything that gates correctness it needs a deterministic partner (a test, a lint rule, a hook). See `think/references/latent-vs-deterministic.md` for the full framing.
- **Rollback:** Can you undo each step independently? If not, mark which steps are one-way doors.

Skip this for Small scope — it's overkill for a 3-file change.

### 6. Product Standards (if the plan includes user-facing output)

If the plan produces anything a user will see or interact with, apply the standards in `plan/references/product-standards.md`. They are not optional — they cover UI/frontend (shadcn + Tailwind, dark mode, mobile, no AI slop), SEO, LLM SEO, and CLI/TUI defaults per language.

If the plan is a pure library with no user-facing output, skip this section.

### 7. Present and Confirm

**If AUTOPILOT is active:** Present the plan briefly and proceed immediately. Do not wait for approval. The user chose autopilot because they trust the process.

**Otherwise:** Present the plan to the user. Wait for explicit approval before executing. If the user modifies the plan, update it before proceeding.

After the plan is approved (or auto-approved in autopilot), do these two steps in order:

**Step 1: Save the artifact.** Run this command now — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh --from-session plan 'N files planned: file1, file2, ... Key decisions: X, Y.'
```

Or pass full JSON for richer detail (recommended — `/review` uses `planned_files` for scope drift):
```bash
~/.claude/skills/nanostack/bin/save-artifact.sh plan '<json with phase, summary including planned_files array, context_checkpoint>'
```

**Step 2: Build and proceed.**

## Next Step

After the user approves the plan and you finish building:

**If AUTOPILOT is active:**

After build completes, invoke each skill in sequence using the Skill tool. Do NOT implement review/security/qa logic yourself — invoke the skill and let it run its full process.

1. Invoke review: `Use Skill tool: skill="review"`
   Wait for completion. Show: `Autopilot: review complete. Running /security...`

2. Invoke security: `Use Skill tool: skill="security"`
   Wait for completion. Show: `Autopilot: security complete. Running /qa...`

3. Invoke qa: `Use Skill tool: skill="qa"`
   Wait for completion. Show: `Autopilot: qa complete. Running /ship...`

4. Invoke ship: `Use Skill tool: skill="ship"`

Stop the sequence if any skill finds blocking issues or critical vulnerabilities. For parallel execution across multiple terminals, use `/conductor`.

**Otherwise (default):**

Tell the user:

> Build complete. Next steps in the sprint:
> - `/review` to run a two-pass code review with scope drift detection
> - `/security` to audit for vulnerabilities
> - `/qa` to test that everything works
>
> These three can run in any order. After all pass, `/ship` to create the PR.

Wait for the user to invoke each one.

## Telemetry finalize

Before returning control:

```bash
_F="$HOME/.claude/skills/nanostack/bin/lib/skill-finalize.sh"
[ -f "$_F" ] && . "$_F" nano success
unset _F
```

Pass `abort` or `error` instead of `success` if the plan did not complete normally.

## Gotchas

- **Don't plan in a vacuum.** The #1 failure mode is planning without reading the code first.
- **Don't split what should be atomic.** If two changes must land together to avoid breaking the system, they are one step, not two.
- **Don't plan tests separately from implementation.** Each step should include its verification. "Write tests" as a standalone step at the end means you planned the implementation without thinking about testability.
- **Don't list alternatives you've already rejected.** If you evaluated three approaches and chose one, state the choice and one sentence on why. Don't write a comparison essay.
- **Scope creep in plans is real.** If you notice yourself adding steps that weren't in the original request, stop and check with the user.
- **Time estimates are noise.** Do not include time estimates. Focus on what needs to happen, not how long it might take.
- **Raw CSS is not a plan.** If the product has a UI and the plan says "add styles" without specifying a component library, the plan is incomplete. The default is shadcn/ui + Tailwind. Deviate only with reason.
