# Nanostack Examples

A library of small, real projects for trying nanostack without touching your own work. Each one is a sandbox: clone, run a single sprint in 5 to 15 minutes, then keep using it or delete it.

The goal is not perfect apps. It is showing the full workflow end to end: idea, `/think`, `/nano`, build, `/review`, `/security`, `/qa`, `/ship`.

## Pick an example

| Example | Who it is for | Stack | Time | First command |
|---|---|---|---|---|
| [starter-todo](starter-todo/) | New users, non-technical | One HTML file, zero dependencies | 5 to 10 minutes | `/nano-run` then `/think` |
| cli-notes (coming) | Technical users learning the CLI archetype | Bash script | 5 to 10 minutes | `/feature` |
| api-healthcheck (coming) | Backend developers | Node HTTP server | 10 to 15 minutes | `/feature` |
| static-landing (coming) | Founders and designers validating a visual demo | Static HTML | 5 to 15 minutes | `/think` |

If you are new and unsure, start with `starter-todo`. It is intentionally the smallest case: a TODO app that fits in one HTML file with three feature ideas already written for you.

## Honesty per agent

The exact level of automatic blocking inside a sprint depends on your agent. The honesty rule from the v0.8 release still applies:

| Agent | Bash guard | Write/Edit guard | Phase gate |
|---|---|---|---|
| Claude Code | Hooks block unsafe actions before they run. | Hooks block writes to protected paths. | `git commit` blocks until `/review`, `/security`, `/qa` produce fresh records. |
| Cursor, Codex, OpenCode, Gemini | The same workflow runs as instructions the agent reads. There is no pre-action hook today on these hosts. | Same. | Same. |

These examples work on every supported agent. The difference shows up in WHERE the safety lives: in a hook (Claude) or in the agent following the guidance (others). Run `/nano-doctor` after install to see the actual level for your environment.

## Each example follows the same shape

Every example README has the same eight sections so they are easy to scan:

1. **Who this is for**
2. **What you start with**
3. **First sprint**
4. **Prompt to try** (a literal prompt you can copy)
5. **Expected Nanostack flow**
6. **Success criteria**
7. **What this teaches**
8. **Reset**

If something feels off, that contract is broken. Open an issue or look at the `examples-library` lint job in `.github/workflows/lint.yml` for the rule it should have caught.

## Where to next

After running through one example end to end, the natural next moves are:

- Try a second example with a different stack.
- Use `/feature` on a project you actually care about.
- Read the [main README](../README.md) for the full picture, or [TROUBLESHOOTING](../TROUBLESHOOTING.md) ([Spanish version](../TROUBLESHOOTING.es.md)) when something gets in the way.
