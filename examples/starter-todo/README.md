# Starter TODO

A sandbox for trying nanostack. Tiny TODO app in one HTML file (under 100 lines, zero dependencies, no build step). The point is not the code. It is having a real, harmless project to run a full nanostack sprint on before touching anything you care about.

## How to use this

```bash
git clone https://github.com/garagon/nanostack
cd nanostack/examples/starter-todo
```

Open `index.html` in your browser to see what you are starting with.

If you have not installed nanostack yet:

```bash
npx create-nanostack
```

Then in your agent (Claude Code, Cursor, Codex, OpenCode, Gemini), from inside this directory:

```
/nano-run
```

Answer the questions. Then pick a feature from the list below and try a full sprint.

## Three features to try

Each one is small enough to finish in one sprint. Each one teaches something different about the workflow.

### 1. Persist tasks across reloads

> "Tasks disappear when I refresh the page. Save them so they come back."

Touches: 1 file (`index.html`), localStorage.
What you learn: how `/think` reframes "save them" into the smallest version that works (probably localStorage, not a backend); how `/review` checks scope drift; how `/qa` actually opens the page and checks the behavior.

### 2. Add a "delete" button to each task

> "I can mark tasks done but I cannot remove them. Add a delete button."

Touches: 1 file (`index.html`).
What you learn: how `/nano` plans a tiny change with explicit out-of-scope items; how `/review` catches missing edge cases (what if the list is empty?).

### 3. Filter tasks by status

> "Show me a way to see only tasks that are not done yet."

Touches: 1 file (`index.html`), some UI state.
What you learn: how `/think` may push back ("do you need filters, or do you need to hide done items?"). A good test of whether the agent challenges your framing or just does what you said.

## What to expect

A first sprint on this project should take around 5-10 minutes end to end. You will see the agent:

1. `/think` ask you about the why and the smallest version
2. `/nano` write a plan that lists every file touched
3. Build the change
4. `/review` give you a one-line summary with auto-fixed nits
5. `/security` grade the change (most likely an A, there is no backend)
6. `/qa` open the page and confirm the new behavior works
7. `/ship` wrap it up (or just stop here, since this is a sandbox)

If anything confuses you, see [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md).

## Notes

- This example uses `.nanostack/` for sprint artifacts. That directory is gitignored at the repo root.
- The HTML is intentionally simple. If you want to change the styling or framework as your first feature, that is fine. It teaches you how `/nano` handles bigger refactors.
- Once you are comfortable, delete this directory or just ignore it. It is not a dependency of nanostack itself.
