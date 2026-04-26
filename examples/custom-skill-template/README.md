# Custom Skill Template

A working example you can copy and adapt to build your own nanostack skill. Sister to `examples/starter-todo`, which teaches the sprint flow; this one teaches you how to extend it.

The included example is `/audit-licenses`: a small skill that scans your project's direct dependencies and flags GPL or AGPL licenses. It is not a production license scanner; it is small enough to read end-to-end and shows every pattern a custom skill needs.

## What the example covers

- A complete `SKILL.md` with the frontmatter the agent runtime expects (`name`, `description`, `concurrency`, `summary`, `estimated_tokens`).
- A bash helper at `bin/audit.sh` that does the actual work and returns structured JSON.
- A smoke check at `bin/smoke.sh` you can run after copying the skill into your agent's directory.
- An `agents/openai.yaml` discovery file so OpenAI-compatible agents see the skill.
- Stack detection (npm, pip, go) the same way `/nano` and `/security` detect projects.
- A pattern for saving an artifact via `bin/save-artifact.sh` so other skills (or `/compound`) can read your output later.
- A standardized one-line headline at the close, matching the format the built-in skills use.

## Try the example without installing

From any project with a `package.json`, `requirements.txt`, `pyproject.toml`, or `go.mod`:

```bash
~/.claude/skills/nanostack/examples/custom-skill-template/audit-licenses/bin/audit.sh node
```

Replace `node` with `python` or `go` to match your stack. The output is JSON with a counts object and a flagged list. This path runs the helper directly from the example folder; it does not register the phase or save an artifact.

## Use it from your agent

Copy the skill folder into your agent's skills directory.

For Claude Code:

```bash
cp -r ~/.claude/skills/nanostack/examples/custom-skill-template/audit-licenses ~/.claude/skills/
```

Verify the copy works on its own:

```bash
~/.claude/skills/audit-licenses/bin/smoke.sh
```

Three "ok" lines mean the helper resolves manifests for Node, Python, and Go from a copy that has no link back to this repository.

Register the phase in the project where you want to use it. `save-artifact.sh` and the resolver only accept phases listed in `.nanostack/config.json`:

```bash
mkdir -p .nanostack
if [ -f .nanostack/config.json ]; then
  jq '.custom_phases = ((.custom_phases // []) + ["audit-licenses"] | unique)' \
    .nanostack/config.json > .nanostack/config.json.tmp \
    && mv .nanostack/config.json.tmp .nanostack/config.json
else
  printf '%s\n' '{"custom_phases":["audit-licenses"]}' > .nanostack/config.json
fi
```

Restart your agent. The agent reads `SKILL.md` to learn the trigger (`/audit-licenses`) and the description; OpenAI-compatible agents read `agents/openai.yaml` for the same purpose.

For other agents, follow the install pattern documented in `EXTENDING.md` at the repo root.

## Adapt it to your domain

The example skill is just bash + jq. To build your own, copy `audit-licenses/` to a new directory and edit:

1. **Frontmatter in `SKILL.md`** (`name`, `description`, `concurrency`, `summary`). The `name` is what the user types after `/`. The `description` is what the agent reads to decide when to invoke your skill, so write it as the agent will see it, not as documentation.
2. **The `Process` section in `SKILL.md`**. Describe step by step what the agent should do. Keep it directives, not narrative. Reference your `bin/` scripts with absolute or relative paths.
3. **Your bash helper(s)** under `bin/`. Use the same conventions as the built-in skills: `set -e`, source `lib/store-path.sh` if you need `$NANOSTACK_STORE`, output JSON, exit non-zero on failure.
4. **Save an artifact** when your skill has a result worth keeping. The artifact ends up in `.nanostack/<your-skill-name>/` and is automatically picked up by `/compound`, `bin/find-artifact.sh`, and the conductor.

## What integrates automatically

Once your skill is in place, you get this for free:

- **The artifact store**. Anything you save with `bin/save-artifact.sh <your-skill> '<json>'` lands at `.nanostack/<your-skill>/<timestamp>.json` with project scoping and integrity hash.
- **The audit log**. `bin/lib/audit.sh` will record your skill's lifecycle events alongside the built-in ones at `.nanostack/audit.log`.
- **The conductor**. If you set `concurrency: read` in your frontmatter, `/conductor batch` will schedule your skill in parallel with other read-only phases. Set `write` for skills that mutate files; `exclusive` for skills that need full repo access.
- **The CI lint**. The repo's `.github/workflows/lint.yml` checks every `SKILL.md` for the required `name` and `description` fields and runs `bash -n` on every `*.sh`. If you copy this template you get these checks for free.

## What is NOT included on purpose

- A test suite. The repo's policy is "no tests in repo, tests are local only." Your skill should follow the same rule unless you specifically need CI tests.
- A web UI or background daemon. Skills are CLI-first and stateless between invocations. The artifact store is the only persistent state.
- Node, Python, or Go runtime dependencies. The example uses bash + jq because that is what nanostack itself uses. Pick the language your team already knows; just keep the SKILL.md and the entry-point script working under bash.

## Further reading

- `EXTENDING.md` at the repo root: the full guide to extending nanostack.
- `bin/save-artifact.sh --help`: the artifact contract.
- `bin/find-artifact.sh`: how skills look up upstream artifacts.
- The built-in skills (`think/`, `plan/`, `review/`, etc.) are the canonical reference for advanced patterns.
