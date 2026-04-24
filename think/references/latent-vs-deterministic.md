# Latent vs Deterministic: A Reliability Lens

A heuristic for knowing when to trust the model and when to build infrastructure. Use it during `/think` to surface hidden reliability risks, and during `/nano` to decide which steps need a deterministic guard.

Adapted from Garry Tan's "How to really stop your agents from making the same mistakes" (April 2026). Gratitude to the gstack community for naming the distinction.

---

## The two kinds of knowledge

**Latent knowledge** lives in the LLM's weights and in the prompt. It is probabilistic. The model might remember, might forget, might hallucinate. It works most of the time and fails in ways that are hard to reproduce.

**Deterministic knowledge** lives in scripts, tests, hooks, linters, types, and CI checks. It either runs correctly or fails loudly with a diff you can read. The same inputs always produce the same result.

A prompt instruction is latent. A pre-commit hook is deterministic. Both can encode "don't commit secrets," but only one will still be enforcing that rule next Tuesday at 3am when the model is tired.

---

## Why the distinction matters

The natural instinct when an agent makes a mistake is to fix the prompt: "be more careful about X," "remember to Y." That adds latent knowledge. It feels like progress because the next run is usually better. But the mistake has not been eliminated. It has been pushed into a probability tail that will surface again when the context shifts.

Each time the same mistake surfaces, the right question is not "how do I word this better?" It is **"can this rule be moved out of the prompt and into infrastructure?"**

---

## Concrete examples

| Rule | Latent version | Deterministic version |
|------|----------------|-----------------------|
| Don't commit secrets | "You must never commit API keys" in CLAUDE.md | Pre-commit hook greps for `sk-proj-`, `AKIA`, `ghp_` patterns |
| Tests must pass | "Run tests before marking the task done" | CI required check; `/ship` aborts if tests fail |
| Use `$HOME` not `/Users/dev` | "Paths must be portable" in every skill | Lint job greps for `/Users/` and fails the PR |
| No em dashes in public copy | "Write without em dashes" in voice guide | CI job that greps the em-dash character in README and blog posts |
| Schema fields are frozen | "Only use v1 fields" in telemetry docs | `jq -e` assertion in the Worker that rejects extra keys |
| Attribution when adapting | "Remember to credit sources" | SKILL.md frontmatter field + lint check that it exists |

Every row on the right started as a row on the left that failed.

---

## When latent is fine

Not everything needs deterministic enforcement. The cost of building a check is real, and over-indexing on infrastructure slows the team down.

Latent is the right call when:

- The decision is a **taste call** (which button style looks professional, which word sounds sharper).
- The rule is **context-dependent** and varies by situation (how terse should this copy be... depends on audience).
- The consequence of failure is **cheap and visible** (the output looks wrong, you notice, you fix it).
- You are in **exploratory mode** and rules are still forming.

## When deterministic is required

Build infrastructure when:

- Failure is **invisible or delayed**: the mistake ships to users and you only learn about it from a support ticket. The PR #124 pre-V5 bug is the archetype: silently broken for days, zero signal.
- Failure has a **security or trust cost**: a secret leaks, a privacy promise is broken, a payment is double-charged.
- The same mistake has happened **twice**: once is a one-off, twice is a pattern, three times is a missing tool.
- The rule is **objective** and can be encoded as a grep, a type check, or an assertion.

---

## Applying the lens in `/think`

During Phase 5 (Risk analysis), sort risks into the two buckets:

- **Latent risks** are assumptions that only hold if the model is careful. Flag them. Any mitigation that reads "the team will remember to X" or "we will document Y" is latent and decays.
- **Deterministic risks** have a test, a check, or a hook that would catch the failure before it reaches users. Prefer these.

Red flag: if every mitigation in the plan is a reminder or a doc, the risk section is theater. Something must graduate to infrastructure, or the risk is real.

## Applying the lens in `/nano`

During planning, classify each step:

- **Deterministic step**: has a verification command (a test that passes, a script that returns 0, a visible output change). Example: "create `VERSION` file with content `0.5.0`, verify `cat VERSION` returns the string."
- **Latent step**: relies on the model doing the right thing without a checkable output. Example: "update the copy to feel sharper."

Latent steps are fine for taste work. But if a latent step gates correctness ("write the function to handle edge case X"), it needs a deterministic partner: a test that proves X is handled. Otherwise the step is a wish.

---

## The graduation pattern

When a latent rule fails and the cost justifies the investment, graduate it:

1. **First failure**: tighten the prompt. Add an example. Still latent.
2. **Second failure**: tighten again, add a structured checklist, maybe a counter-example. Still latent, slightly better.
3. **Third failure**: stop tightening. Build the check. Move the rule from prompt to infrastructure.

The graduation step should feel like pulling teeth. If it feels easy, you are probably building infrastructure for a rule that is not actually failing often enough to justify it.

---

## Quick self-check

Ask before trusting a rule:

- Can a developer see this rule is being followed without reading the prompt? If no, it is latent.
- Would a fresh clone of the repo still enforce this rule tomorrow, with a different model? If no, it is latent.
- Does failure leave a trace (a failing CI check, a visible diff, a rejected commit)? If no, it is latent and failures will be invisible.

Three nos means the rule is pure prompt engineering. That is fine for taste, risky for safety.
