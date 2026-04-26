# Static Landing

A one-page landing for a fictional product called Crumb. One file (`index.html`), zero dependencies, no build step. The point is not the product. It is having a real visual surface to run a full nanostack sprint on without touching any landing that matters.

## Who this is for

A founder validating an idea, or a designer iterating on copy and layout, who wants to feel how nanostack handles taste and persuasion work, not just code.

## What you start with

A working single-page landing for "Crumb, quick notes for people who think out loud":

- A hero with a headline, lede, and a CTA button.
- A "Why Crumb" section with three feature bullets.
- A waitlist section pointing at a `mailto:` link.
- A small footer.

Plain CSS, no framework, no analytics, no images. Renders the same in every modern browser. About 80 lines.

What it does NOT do yet (these are the seeds for your first sprint):

- No social proof: no testimonials, no customer logos, no founder quote.
- No second-look conversion: only one CTA, repeated. No reason to scroll a second time.
- No comparison or pricing: no answer to "how is this different from Notes / Apple Reminders / Notion".

## First sprint

```bash
git clone https://github.com/garagon/nanostack
cd nanostack/examples/static-landing
```

Open `index.html` in your browser to see what you are starting with.

If you have not installed nanostack yet:

```bash
npx create-nanostack
```

Then, inside this directory, in your agent (Claude Code, Cursor, Codex, OpenCode, or Gemini):

```
/nano-run
```

Pick one of the three feature prompts below.

## Prompt to try

Each fits one sprint of about 10 to 15 minutes. Use `/feature` for autopilot or `/think` if you want the agent to challenge scope first.

**Easiest. Sharper hero copy.**

```
/feature Rewrite the hero headline and lede so a stranger lands on this page and understands in five seconds what Crumb is for and why it is different from the notes app on their phone. Keep the layout. One line for the headline, two lines max for the lede.
```

**Medium. Add a testimonials section.**

```
/feature Add a testimonials section between "Why Crumb" and the waitlist. Three short quotes with a name and role. Keep the visual style consistent with the existing feature cards. Do not add images or an external font.
```

**Higher pushback. Pricing.**

```
/think I want to add a pricing section so visitors know what this will cost. Push back if you think a pricing table is wrong for a pre-launch waitlist landing. If you do push back, suggest the smallest version that still answers "is this free, paid, or freemium" without committing to numbers.
```

The third prompt is the interesting one for a founder. There is a real argument that pricing on a pre-launch waitlist hurts conversion more than it helps, and a good `/think` should surface that before `/nano` writes a price table.

## Expected Nanostack flow

In about 10 to 15 minutes you should see:

1. `/think` (or `/feature`'s implicit think) names the smallest version. For copy work it should ask who the visitor is and what they would compare Crumb to.
2. `/nano` writes a plan that lists every file it will touch. For all three feature ideas this should be exactly one file (`index.html`).
3. The agent edits `index.html`. No new files, no `package.json`, no asset folder.
4. `/review` reports on the diff. Look for a one-line summary plus auto-fixes (semantic HTML, missing `alt` attributes if you add images, contrast issues).
5. `/security` rates the change. With no scripts and no form submissions it should land at A.
6. `/qa` opens the page and checks the new section renders correctly across viewport widths.
7. `/ship` closes the sprint.

The exact level of automatic blocking depends on your agent. On Claude Code, hooks can stop unsafe actions before they execute. On Cursor, Codex, OpenCode, and Gemini, nanostack runs as guided instructions the agent reads and follows.

## Success criteria

You succeeded if all of these are true after the sprint:

- The new section renders correctly when you open `index.html` in a browser.
- The page still works on mobile (the `viewport` meta tag is intact and the layout does not break).
- All existing sections (hero, Why Crumb, waitlist, footer) still render and the CTA still goes to the waitlist anchor.
- The plan named every file it touched. There is exactly one (`index.html`).
- No external scripts, no tracking pixels, no `<script>` tag pulling from a CDN snuck in.
- Nothing outside `examples/static-landing/` was touched.
- You can describe the change to a teammate using the agent's review summary, without rereading the diff.

If any of these is false, the example or the install needs attention. Run `/nano-doctor` and check TROUBLESHOOTING.

## What this teaches

- How `/think` reframes a vague visual ask ("make the headline better") into questions about audience, comparison set, and the one thing the visitor must learn first.
- How `/nano` constrains scope to one file and refuses to silently introduce a build step or a font CDN.
- How `/review` catches taste-side regressions: heading hierarchy, contrast, alt text, semantic landmarks, behavior on narrow viewports.
- How `/security` treats a static landing as a real surface (no inline scripts, no third-party trackers) instead of waving it through as "just HTML".
- How `/qa` actually opens the page and confirms the new section renders, not just that the markup is well-formed.
- How nanostack stays inside this directory and never silently rewrites your design system, your tokens file, or any sibling project.

## Reset

To go back to the starting state without any sprint records:

```bash
rm -rf .nanostack/
git checkout -- index.html
```

Each command is scoped to this directory:

- `rm -rf .nanostack/` removes only the sprint records this example produced.
- `git checkout -- index.html` restores the page to the version in this repo.

There is nothing destructive to your wider machine in either step.

If you want to fully forget this example, delete `examples/static-landing/`. It is not a dependency of nanostack itself.

For setup or environment trouble, see [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md).
