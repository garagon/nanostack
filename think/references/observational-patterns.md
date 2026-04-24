# Observational Patterns: A Coach's Lens

Optional section of the Think Summary. When a user pattern is strong enough to be worth naming, add a "What I noticed" block at the end of the brief. When it is not strong enough, omit the section entirely. Silence beats a forced observation.

## Trigger rule

Add an observation ONLY when one of the four patterns below fired AND you can quote or paraphrase a specific moment from the conversation. If you cannot point to the moment, the signal is not strong enough. Target: fewer than 30% of sessions should include this section.

---

## Pattern 1: Jump-to-solution

**Signal.** The user described implementation details (tech stack, architecture, file layout) before the problem and the target user were clear.

**Trigger example:**

> "I want to build a React app with Supabase for auth and Stripe for payments. It's a marketplace for indie hackers."

Tech stack appeared before any user pain or demand evidence was offered.

**Observation to write.** Name the moment, then give the redirect.

> You described the stack before the user. In the three turns that followed, the target stayed abstract ("indie hackers" is a role, not a person). Worth naming five specific people who would buy this before picking Supabase vs Firebase.

**False positive.** The user described the stack because you asked "what's your current stack?" Only count this pattern when the tech-first framing was unprompted.

---

## Pattern 2: Scope drift

**Signal.** Scope expanded meaningfully during the session. The user added features, widened the target audience, or pushed the "starting point" outward across multiple turns.

**Trigger example:**

> Turn 1: "A CLI to validate JSON."
> Turn 3: "Actually, also YAML and TOML."
> Turn 5: "A web UI too, for non-devs."

**Observation to write.** Quote the progression, then give the redirect.

> Scope grew from "JSON CLI" to "multi-format validator with web UI" in three turns. Past sprints in this project show scope growth during `/think` correlates with scope drift during `/nano`. Consider picking one format to ship and queuing the others as `/feature` commands.

**False positive.** The user narrowed scope across the session. That is the opposite pattern and is healthy. Do not fire.

---

## Pattern 3: Strong pain observation

**Signal.** The user named a specific painful moment with concrete detail: a specific day, a specific failure, a specific cost in hours or money.

**Trigger example:**

> "Last Tuesday I spent four hours debugging a typo because no one caught it in review."

**Observation to write.** Surface the moment as the north star.

> The Tuesday story is the sharpest signal of the session. The product's job is to prevent four-hour debug sessions for typos. If the plan does not do that specifically, it is solving a different problem.

**False positive.** Vague frustration ("it's annoying", "it's kind of painful"). The pain must be anchored to a specific moment. Abstract pain is not actionable.

---

## Pattern 4: Surprising synthesis

**Signal.** The user connected two domains in a way that is non-obvious AND changes how the product would be built, not just how it is described.

**Trigger example:**

> "What if we treat a failing test like a compiler error, not a runtime error? The fix is the test."

**Observation to write.** Name the reframe, pull its consequence.

> Treating a failing test as a compiler error is a real reframe. It suggests the tool should block commit, not warn post-hoc. That is a different UX than most test runners. Worth naming this choice in the spec before it disappears.

**False positive.** Shallow analogies ("it's like Uber for X"). A real synthesis changes implementation; an analogy just decorates the pitch. Only fire when the connection has a build consequence.

---

## Rules for writing observations

- **Quote the moment.** "You said X" beats "You seem to...". Anchor every observation to a specific turn.
- **Make it actionable.** End with a concrete next move: "Name five specific people", "Pick one format", "Name this in the spec".
- **Honest, not harsh.** Tone is a senior engineer noticing, not a drill sergeant correcting. The user decides what to do.
- **Cap at three.** More than three observations is noise. Pick the sharpest and move on.
- **When in doubt, omit.** A missed observation is cheap. A forced one trains the user to tune the block out.

## When to skip the section entirely

- The conversation was short (fewer than four user turns). Too little signal.
- The user answered crisply and converged fast. Nothing to name.
- No pattern above fired with specific evidence.
- The active preset declares it skips observational feedback (for example, `eng` skips because the pressure test is the feedback).

---

## Local mode

If local mode is active (no git repo, non-technical user), render observations in the user's conversational Spanish and drop jargon. The pattern still applies; only the voice changes.

> En los últimos tres mensajes agrandaste de "CLI para JSON" a "validador de todo con interfaz web". Cuando pasa eso en `/nano` el proyecto suele pararse. ¿Empezás por un formato y dejás los otros para después?

Same observation, softer delivery. Do not name the pattern by its English label in local mode.
