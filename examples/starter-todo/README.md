# Starter TODO

A safe sandbox for trying nanostack. A tiny TODO app in one HTML file (under 100 lines, zero dependencies, no build step). The point is not the code. It is having a real, harmless project to run a full nanostack sprint on before touching anything you care about.

## Who this is for

Someone new to nanostack who wants to feel the workflow without risking real work. No technical background required. If you can open a file in your browser and read instructions, you have enough to use this example.

## What you start with

A working TODO app in a single file (`index.html`). You can add tasks, mark them done. That is all it does. Things it does NOT do yet:

- Tasks disappear when you reload the page.
- There is no way to delete a task once it is added.
- There is no way to filter or search.

These gaps are intentional. They are the seeds for your first feature.

## First sprint

```bash
git clone https://github.com/garagon/nanostack
cd nanostack/examples/starter-todo
```

Open `index.html` in your browser to see what you are starting with.

If you have not installed nanostack yet, install it first:

```bash
npx create-nanostack
```

Then, inside this directory, in your agent (Claude Code, Cursor, Codex, OpenCode, or Gemini):

```
/nano-run
```

Answer the questions. Then pick one of the three feature ideas below and try a full sprint.

## Prompt to try

Pick the prompt that matches what you want to learn. Each fits in one sprint of about 5 to 15 minutes.

**Easiest. Save tasks across reloads.**

```
/think Quiero que esta app me ayude a no perder tareas cuando cierro el navegador. Buscá la versión más chica y segura para probarlo.
```

**Medium. Delete a task.**

```
/think I can mark tasks done but I cannot remove them. Add a way to delete a task. Keep it simple, do not break anything else.
```

**Higher pushback. Filter by status.**

```
/think Show me a way to see only tasks that are not done yet. If you think filters are too much, push back.
```

The third prompt is a good test of whether the agent challenges your framing or just does what you said.

## Expected Nanostack flow

In about five to fifteen minutes you should see the agent:

1. `/think` ask you about the why and the smallest version that delivers value.
2. `/nano` write a short plan that names every file it will touch.
3. Build the change.
4. `/review` give you a short summary with nits the agent already fixed.
5. `/security` rate the change. With no backend you should see grade A.
6. `/qa` open the page and confirm the new behavior actually works.
7. `/ship` close the sprint. Since this is a sandbox, you can also stop here.

The exact level of automatic blocking depends on your agent. On Claude Code, hooks are wired up and can stop unsafe actions. On Cursor, Codex, OpenCode, and Gemini today, nanostack runs as guided instructions the agent reads and follows.

## Success criteria

You succeeded if all of these are true after the sprint:

- The feature you asked for works when you open `index.html`.
- The agent named every file it modified before changing it.
- You see a one-line summary at the end of `/review`, `/security`, and `/qa`.
- Nothing outside `examples/starter-todo/` was touched.
- You can describe what just happened to someone else without reading internal docs.

If any of these is false, the example or the install needs attention. Run `/nano-doctor` and look at TROUBLESHOOTING.

## What this teaches

- How `/think` reframes a vague request into the smallest version that works (often localStorage, not a backend).
- How `/nano` produces a plan with explicit out-of-scope items so you know what was decided NOT to change.
- How `/review` catches edge cases like the empty-list case the user did not mention.
- How `/qa` opens the result and verifies behavior, not just code shape.
- How nanostack stays scoped to one directory and never silently edits the rest of your machine.

## Reset

To go back to the starting state without any commit history or sprint records:

```bash
rm -rf .nanostack/
git checkout -- index.html
```

The `git checkout` restores `index.html` to the version in this repo. The `rm -rf .nanostack/` removes only the sprint artifacts saved in this example, nothing outside it. There is nothing destructive to your wider machine in either step.

If you want to fully forget this example, delete the `examples/starter-todo/` directory. It is not a dependency of nanostack itself.

For setup or environment trouble, see [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md).
