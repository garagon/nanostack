# CLI Notes

A tiny bash CLI for taking notes. One file (`notes.sh`), one storage backend (a text file), three commands. The point is not the CLI. It is having a real, harmless command-line tool to run a full nanostack sprint on without touching any project that matters.

## Who this is for

A technical user comfortable with a shell. You know what `chmod +x` does, you can read a 60-line bash script, and you want to feel how nanostack handles a CLI feature ask without inventing complexity.

## What you start with

A working CLI with three commands:

| Command | What it does |
|---|---|
| `notes.sh add "text"` | Append a timestamped note (UTC) to `notes.txt` |
| `notes.sh list` | Print every note in the order it was written |
| `notes.sh count` | Print how many notes exist |

What it does NOT do yet (these are the seeds for your first sprint):

- No way to filter or search notes by keyword.
- No way to print notes in reverse chronological order (newest first).
- No way to delete or edit a single note.

The script is under 80 lines. Read it before running.

## First sprint

```bash
git clone https://github.com/garagon/nanostack
cd nanostack/examples/cli-notes
chmod +x notes.sh
```

Try the starting state to confirm everything works:

```bash
./notes.sh add "buy milk"
./notes.sh add "call mom"
./notes.sh list
./notes.sh count
```

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

Each prompt fits one sprint of about 5 to 15 minutes. They are ordered by difficulty. Use `/feature` for a fast-path autopilot run, or `/think` if you want the agent to challenge scope first.

**Easiest. Reverse chronological list.**

```
/feature Add a `--list` flag (or `notes.sh list --reverse`) that prints saved notes in reverse chronological order, newest first. Keep storage format unchanged.
```

**Medium. Search by keyword.**

```
/feature Add a `notes.sh search "<term>"` command that prints every note whose text contains the term, case-insensitive. The original `list` command must keep working.
```

**Higher pushback. Delete a note.**

```
/think I want to delete a single note. Push back if you think this is more complex than it sounds. Find the smallest version that does not corrupt the file or accidentally erase too much.
```

Delete is the interesting one. There is no obvious primary key, ordering matters, and a naive implementation can clobber the wrong line. A good `/think` will surface those before `/nano` writes any code.

## Expected Nanostack flow

In about 5 to 15 minutes you should see:

1. `/think` (or `/feature`'s implicit think) names the smallest version. For the search feature it should ask whether case-insensitive is required and whether multi-word matches are in scope.
2. `/nano` writes a plan that lists every file it will touch. For all three feature ideas this should be exactly one file (`notes.sh`).
3. The agent edits `notes.sh`. No new files unless the plan said otherwise.
4. `/review` reports on the diff. Look for a one-line summary plus any auto-fixed items (formatting, exit codes, missing quotes).
5. `/security` rates the change. With no network and no shell injection surface it should land at A.
6. `/qa` actually runs the script with sample input and confirms the new behavior works AND the existing commands still pass.
7. `/ship` closes the sprint.

The exact level of automatic blocking depends on your agent. On Claude Code, hooks can stop unsafe actions before they execute. On Cursor, Codex, OpenCode, and Gemini, nanostack runs as guided instructions the agent reads and follows.

## Success criteria

You succeeded if all of these are true after the sprint:

- The new behavior works when you run the modified `notes.sh` directly.
- The original three commands (`add`, `list`, `count`) still work.
- `bash -n notes.sh` passes (script is syntactically clean).
- The plan named every file it touched. There is exactly one (`notes.sh`).
- `notes.txt` was NOT modified except by the `add` calls you ran intentionally.
- Nothing outside `examples/cli-notes/` was touched.
- You can describe the change to a teammate using the agent's review summary, without rereading the diff.

If any of these is false, the example or the install needs attention. Run `/nano-doctor` and check TROUBLESHOOTING.

## What this teaches

- How `/think` reframes a vague CLI request ("delete a note") into a smaller, safer first version (delete by line number, with a confirmation prompt).
- How `/nano` constrains scope to one file and produces a plan that survives the diff later.
- How `/review` catches CLI-specific edge cases: missing quotes, exit codes, behavior on empty input, behavior when `notes.txt` does not exist.
- How `/qa` exercises a CLI with real arguments instead of "looks correct on read".
- How nanostack stays inside this directory and never silently rewrites your shell config or other tools.

## Reset

To go back to the starting state without any sprint records:

```bash
rm -f notes.txt
rm -rf .nanostack/
git checkout -- notes.sh
```

Each command is scoped to this directory:

- `rm -f notes.txt` removes only the local notes file.
- `rm -rf .nanostack/` removes only the sprint records this example produced.
- `git checkout -- notes.sh` restores the script to the version in this repo.

There is nothing destructive to your wider machine in any of these steps.

If you want to fully forget this example, delete `examples/cli-notes/`. It is not a dependency of nanostack itself.

For setup or environment trouble, see [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md).
