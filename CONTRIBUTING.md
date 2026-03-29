# Contributing to Nanostack

Contributions are welcome. Here's how to get started.

## Setup

```bash
git clone https://github.com/garagon/nanostack.git ~/.claude/skills/nanostack
cd ~/.claude/skills/nanostack && ./setup
```

No build step. No dependencies. Skills use symlinks and take effect immediately.

## Project Structure

```
think/         /think skill (product thinking, forcing questions)
plan/          /nano skill (planning, specs by scope)
review/        /review skill (two-pass code review, scope drift)
qa/            /qa skill (browser, API, CLI testing)
security/      /security skill (OWASP, STRIDE, variant analysis)
ship/          /ship skill (PR, CI, deploy, sprint journal)
guard/         /guard skill (command blocking, safer alternatives)
conductor/     /conductor skill (parallel agent orchestration)
bin/           Shared scripts (artifacts, analytics, journal)
reference/     Conflict precedents, artifact schema
```

Each skill is a directory with a `SKILL.md` that contains the agent instructions.

## What You Can Contribute

- **New skills**: Add a domain-specific skill that composes with the existing workflow
- **Skill improvements**: Better instructions, edge cases, examples
- **Guard rules**: New block/warn rules in `guard/rules.json`
- **Bug fixes**: Anything broken in the bin/ scripts
- **Documentation**: README, EXTENDING.md, examples

## Adding a Skill

1. Create a directory with a `SKILL.md`:
   ```
   my-skill/
     SKILL.md
   ```

2. Follow the frontmatter format:
   ```yaml
   ---
   name: my-skill
   description: What it does. When to use it. Triggers on /my-skill.
   ---
   ```

3. Use `bin/save-artifact.sh` to persist output
4. Use `bin/find-artifact.sh` to read other skills' output
5. Include a "Next Step" section pointing to the next skill in the workflow

## Adding Guard Rules

Edit `guard/rules.json`. Each rule needs:

```json
{
  "id": "G-100",
  "pattern": "your-regex-pattern",
  "category": "category-name",
  "description": "What this blocks and why",
  "alternative": "Safer way to do the same thing"
}
```

Test your pattern before submitting.

## Pull Request Process

1. Branch from `main`
2. Keep changes focused (one skill or one fix per PR)
3. Test that setup still works: `./setup --help`
4. Test affected bin/ scripts if you changed them
5. Submit a PR with a clear description

### PR Checklist

- [ ] setup runs without errors
- [ ] SKILL.md follows existing format
- [ ] No hardcoded paths or usernames
- [ ] No secrets or credentials in any file

## Code Style

- Shell scripts: POSIX-compatible where possible, bash when needed
- SKILL.md: clear, direct instructions. No filler.
- Avoid AI slop in documentation (no "leverage", "utilize", "robust", "cutting-edge")

## Reporting Issues

- [Bug reports](https://github.com/garagon/nanostack/issues/new?template=bug_report.yml)
- [Feature requests](https://github.com/garagon/nanostack/issues/new?template=feature_request.yml)
- Security vulnerabilities: see [SECURITY.md](SECURITY.md)
