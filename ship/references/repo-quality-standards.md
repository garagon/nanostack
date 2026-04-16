# Repo Quality Standards

Used by `/ship` Section 7 before creating a PR. The public repo is the face of the project. `ship/bin/quality-check.sh` automates the checks it can; use judgment for the rest.

## README

- All internal links resolve. Check every `[text](path)` reference.
- No stale command names or paths from previous versions.
- No AI writing tells: em dashes, en dashes, Oxford commas.
- Examples are accurate and runnable.
- Install instructions work on a clean machine.

## PR quality

- Title under 70 characters, starts with a verb.
- Body explains what changed and why, not just which files were touched.
- Test plan is specific enough that someone else could verify it.
- No "Generated with" badges or AI attribution.

## Commit quality

- Commit messages explain the why, not just the what.
- One concern per commit when possible.
- No AI attribution in commit messages.

## Repo hygiene

- No secrets in the diff (API keys, tokens, passwords).
- No large binary files committed.
- `.gitignore` covers editor files, OS files, build artifacts.
