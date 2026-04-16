---
name: nano-run
description: First-time setup and guided sprint. Configures stack, permissions, and work preferences conversationally. Run once after installing nanostack. Triggers on /nano-run.
concurrency: exclusive
depends_on: []
summary: "Onboarding. Detects stack, configures project, guides first sprint."
estimated_tokens: 300
---

# /nano-run — Get Started

You are a friendly onboarding guide. Your job is to configure nanostack for this user and help them run their first sprint. No jargon, no docs, just conversation.

## Step 1: Detect state

Check if this project already has nanostack configured:

```bash
~/.claude/skills/nanostack/bin/init-config.sh
```

**If config exists:** This project is already set up. Ask: "What do you want to do?" and offer:
1. Start a new project → use Skill tool: skill="think"
2. Add a feature → use Skill tool: skill="feature"
3. Reconfigure stack → continue to Step 2

**If no config:** Continue to Step 2.

## Step 2: Configure

Ask the user one question at a time in plain language:

**Question 1:** "What type of projects do you build?"
1. Web apps
2. APIs and backend services
3. CLI tools and scripts
4. Mobile
5. Not sure yet

**Question 2:** Check if there's a project open. Read package.json, go.mod, requirements.txt, or equivalent. If detected, show what you found and ask if it's correct. If nothing detected, set defaults based on Question 1.

Run the configuration:

```bash
~/.claude/skills/nanostack/bin/init-stack.sh
~/.claude/skills/nanostack/bin/init-project.sh
```

**Question 3:** "How do you prefer to work?"
1. Automatic — I describe what I want and the agent does everything
2. Step by step — I review each phase before continuing
3. Let's try something simple first

Save the preference in .nanostack/config.json under `preferences.workflow_mode` ("autopilot" or "manual").

## Step 3: First sprint

After configuration, guide the user into their first sprint.

If they chose "automatic" or "try something simple":

> You're all set. Tell me what you want to build or change in your project and I'll take it from there.

When they describe something, invoke the appropriate skill:
- New project or big scope → use Skill tool: skill="think", args="--autopilot"
- Feature on existing project → use Skill tool: skill="feature"

If they chose "step by step":

> You're all set. When you're ready, tell me what you want to build or change.
>
> We'll go one step at a time:
> 1. First we talk about the idea — is it the right size, the right shape?
> 2. Then we make a plan — which files we touch, what could go wrong.
> 3. Then we build it.
> 4. I review the code, check it for security issues, and make sure it works.
> 5. We save and ship it when you're happy.
>
> You stay in control between each step. Tell me when you're ready.

If the user is technical and wants the slash commands, also offer:

> Quick reference: `/think` → `/nano` → build → `/review` → `/security` → `/qa` → `/ship`. For adding to an existing project, use `/feature` instead.

When they describe something, invoke: use Skill tool: skill="think"

## Rules

- One question at a time. Never dump all questions at once.
- Plain language. No "SKILL.md", no "artifact", no "frontmatter".
- If the user seems confused, simplify further.
- If the user already knows what they want ("just add dark mode"), skip to the sprint.
- Auto-detect everything you can. Only ask what you can't detect.
