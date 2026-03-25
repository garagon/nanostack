---
name: plan
description: Use when starting non-trivial work (touching 3+ files, new features, refactors, bug investigations). Produces a scoped, actionable implementation plan before any code is written. Triggers on /plan.
---

# /plan — Implementation Planning

You turn validated ideas into executable steps. Every file gets named. Every step gets a verification. Every unknown gets surfaced. The plan is a contract: if it says 4 files, the PR should touch 4 files.

## Process

### 1. Understand the Request

- Check git history for recent changes in the affected area — someone may have already started this work or made decisions you need to respect.
- If the request is ambiguous, ask clarifying questions using `AskUserQuestion` before proceeding. Do not guess scope.

### 2. Evaluate Scope

Classify the work:

| Scope | Criteria | Plan depth |
|-------|----------|------------|
| **Small** | 1-3 files, single concern, clear path | Bullet-point plan, skip risk analysis |
| **Medium** | 4-10 files, multiple concerns, some unknowns | Full plan with risks and alternatives |
| **Large** | 10+ files, cross-cutting, architectural impact | Full plan + phased execution + checkpoints |

For **small** scope: produce a brief plan and move on. Do not over-plan trivial work.

### 3. Write the Plan

Use the template at `plan/templates/plan-template.md` as your output structure. Fill in every section that applies to the scope level.

Key requirements:
- **Every file you will touch must be listed** — no surprises during implementation
- **Order of operations matters** — list steps in the sequence you will execute them
- **Each step must be independently verifiable** — how will you know it worked?
- **Identify what you do NOT know** — unknowns are more valuable than knowns in a plan

### 4. Architecture Checkpoint (Medium/Large scope only)

Before presenting, validate the plan against these engineering concerns:

- **Data flow:** Can you trace data from input to storage to output? If not, there's a hidden dependency.
- **Failure modes:** What happens when each external call fails? (DB down, API timeout, disk full). If the plan doesn't address this, it's incomplete.
- **Scaling bottleneck:** Is there a single point that won't handle 10x load? (synchronous loop, unbatched DB queries, in-memory state). Name it.
- **Test matrix:** For each step, what's the minimum test that proves it works? If you can't name it, the step is too vague.
- **Rollback:** Can you undo each step independently? If not, mark which steps are one-way doors.

Skip this for Small scope — it's overkill for a 3-file change.

### 5. Product Standards (if the plan includes user-facing output)

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

If none of these apply (pure backend, CLI, library), skip this section.

### 6. Present and Confirm

Present the plan to the user. Wait for explicit approval before executing. If the user modifies the plan, update it before proceeding.

### 7. Save Artifact (with `--save`)

If the user invoked `/plan --save`, persist the plan for scope drift detection and trend tracking:

```bash
bin/save-artifact.sh plan '<json with phase, summary including planned_files array>'
```

The `planned_files` list is critical — `/review` uses it for scope drift detection via `bin/scope-drift.sh`. See `reference/artifact-schema.md` for the full schema.

**Always suggest `--save` for Medium and Large scope plans.** Small scope plans rarely need scope tracking.

## Gotchas

- **Don't plan in a vacuum.** The #1 failure mode is planning without reading the code first.
- **Don't split what should be atomic.** If two changes must land together to avoid breaking the system, they are one step, not two.
- **Don't plan tests separately from implementation.** Each step should include its verification. "Write tests" as a standalone step at the end means you planned the implementation without thinking about testability.
- **Don't list alternatives you've already rejected.** If you evaluated three approaches and chose one, state the choice and one sentence on why. Don't write a comparison essay.
- **Scope creep in plans is real.** If you notice yourself adding steps that weren't in the original request, stop and check with the user.
- **Time estimates are noise.** Do not include time estimates. Focus on what needs to happen, not how long it might take.
- **Raw CSS is not a plan.** If the product has a UI and the plan says "add styles" without specifying a component library, the plan is incomplete. The default is shadcn/ui + Tailwind. Deviate only with reason.
