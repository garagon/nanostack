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

## Process

### 1. Understand the Request

- **Read the /think artifact** if one exists for this project:
  ```bash
  ~/.claude/skills/nanostack/bin/find-artifact.sh think 2
  ```
  If found, extract and use:
  - `key_risk` → add to your Risks section. This was already validated by /think.
  - `narrowest_wedge` → this is the scope constraint. Don't plan beyond it.
  - `out_of_scope` items from /think → pre-populate your Out of Scope section.
  - `scope_mode` → if /think said "reduce," plan the smallest version. If "expand," plan bigger.
  - `premise_validated` → if false, flag it. Don't plan for an unvalidated premise.

- Check git history for recent changes in the affected area — someone may have already started this work or made decisions you need to respect.
- Search past solutions: run `~/.claude/skills/nanostack/bin/find-solution.sh` with keywords related to the technologies and files in scope. The output shows ranked summaries with title, severity, tags and files. Read the summaries first, then load only the solutions relevant to the current task. Past mistakes and patterns should inform the current sprint.
- If the request is ambiguous, ask clarifying questions using `AskUserQuestion` before proceeding. Do not guess scope.
- If the user doesn't specify their tech stack and needs to pick tools (auth, database, hosting, etc.), check for overrides first, then fall back to defaults:
  1. Read `.nanostack/stack.json` if it exists (project-level preferences)
  2. Read `~/.nanostack/stack.json` if it exists (user-level preferences)
  3. Read `plan/references/stack-defaults.md` for anything not covered above
  4. If the project already has a stack (check package.json, go.mod, requirements.txt), use what's there regardless of any config.
  Suggest, don't impose. The user always has the final say.
- **Always use the latest stable version** of every dependency. Don't rely on versions from training data.

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
- **Rollback:** Can you undo each step independently? If not, mark which steps are one-way doors.

Skip this for Small scope — it's overkill for a 3-file change.

### 6. Product Standards (if the plan includes user-facing output)

If the plan produces anything a user will see or interact with, apply these standards. They are not optional. A product built with an AI agent should look and feel better than one built without it.

**UI/Frontend:**
- Use a component library. Default: shadcn/ui + Tailwind. Not raw CSS, not Bootstrap, not Material UI from 2019. The bar is professional SaaS quality.
- Dark mode support from day one. Not as a follow-up. It takes 5 minutes more with Tailwind.
- Mobile responsive. If it doesn't work on a phone, half the users can't use it.
- No AI slop: no purple gradients, no centered-everything landing pages, no generic hero copy, no Inter font as the only choice. If it looks like every other AI-generated site, it's wrong.

**SEO (if web-facing):**
- Semantic HTML. `<main>`, `<article>`, `<nav>`, `<h1>` hierarchy. Not a div soup.
- Meta tags: title, description, og:image, og:title, og:description. Every page.
- Performance: images optimized, no layout shift, Core Web Vitals passing.
- Sitemap and robots.txt if the site has more than one page.

**LLM SEO (if the product should be discoverable by AI):**
- Structured data (JSON-LD) for the content type: Product, Article, FAQ, HowTo, SoftwareApplication.
- `llms.txt` at the root describing what the site/product does in plain language.
- Clean, descriptive URLs. `/pricing` not `/page?id=3`.
- Content that answers questions directly in the first paragraph. LLMs extract from the top, not the bottom.

**CLI/TUI (if the plan produces a command-line tool):**
- Use a TUI framework. Default by language:
  - **Go:** [Bubble Tea](https://github.com/charmbracelet/bubbletea) + [Lip Gloss](https://github.com/charmbracelet/lipgloss) for interactive TUIs. [Cobra](https://github.com/spf13/cobra) for command structure. [Glamour](https://github.com/charmbracelet/glamour) for markdown rendering.
  - **Python:** [Rich](https://github.com/Textualize/rich) for output formatting. [Textual](https://github.com/Textualize/textual) for interactive TUIs. [Click](https://github.com/pallets/click) or [Typer](https://github.com/tiangolo/typer) for command structure.
  - **Node/TypeScript:** [Ink](https://github.com/vadimdemedes/ink) for interactive TUIs. [Commander](https://github.com/tj/commander.js) for command structure. [Chalk](https://github.com/chalk/chalk) for colors.
  - **Rust:** [Ratatui](https://github.com/ratatui-org/ratatui) for interactive TUIs. [Clap](https://github.com/clap-rs/clap) for command structure.
- Color output by default. Respect `NO_COLOR` env var and `--no-color` flag.
- Structured output: support `--json` flag for machine-readable output. Human-readable is default.
- Progress indicators for operations that take more than 1 second (spinners, progress bars).
- Error messages must be actionable: what went wrong, why, and what the user should do. Not stack traces.
- Exit codes: 0 for success, 1 for user error, 2 for system error. Consistent across all subcommands.
- Help text: every command and flag has a description. `--help` works on every subcommand.
- No wall of text output. Use tables, columns, indentation and color to make output scannable.
- Version flag: `--version` prints version and exits.

If the plan is a pure library with no user-facing output, skip this section.

### 7. Present and Confirm

Present the plan to the user. Wait for explicit approval before executing. If the user modifies the plan, update it before proceeding.

After the user approves, do these two steps in order:

**Step 1: Save the artifact.** Run this command now — do not skip it:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh plan '<json with phase, summary including planned_files array, context_checkpoint including summary, key_files, decisions_made, open_questions>'
```

The `planned_files` list is critical — `/review` uses it for scope drift detection.

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

## Gotchas

- **Don't plan in a vacuum.** The #1 failure mode is planning without reading the code first.
- **Don't split what should be atomic.** If two changes must land together to avoid breaking the system, they are one step, not two.
- **Don't plan tests separately from implementation.** Each step should include its verification. "Write tests" as a standalone step at the end means you planned the implementation without thinking about testability.
- **Don't list alternatives you've already rejected.** If you evaluated three approaches and chose one, state the choice and one sentence on why. Don't write a comparison essay.
- **Scope creep in plans is real.** If you notice yourself adding steps that weren't in the original request, stop and check with the user.
- **Time estimates are noise.** Do not include time estimates. Focus on what needs to happen, not how long it might take.
- **Raw CSS is not a plan.** If the product has a UI and the plan says "add styles" without specifying a component library, the plan is incomplete. The default is shadcn/ui + Tailwind. Deviate only with reason.
