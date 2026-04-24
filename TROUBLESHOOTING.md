# Troubleshooting

Common problems and how to resolve them, organized by what you actually see.

If your symptom is not here, open an issue: https://github.com/garagon/nanostack/issues

## Contents

- [Slash commands do not appear in my agent](#slash-commands-do-not-appear-in-my-agent)
- [Command not found: jq](#command-not-found-jq)
- [The phase gate blocked my git commit](#the-phase-gate-blocked-my-git-commit)
- [/qa says the port is in use](#qa-says-the-port-is-in-use)
- [I am on Windows](#i-am-on-windows)
- [I started a sprint and got stuck halfway](#i-started-a-sprint-and-got-stuck-halfway)
- [Skill name conflicts with another set (gstack, superpowers)](#skill-name-conflicts-with-another-set-gstack-superpowers)
- [Cannot install or upgrade behind a corporate proxy](#cannot-install-or-upgrade-behind-a-corporate-proxy)
- [The agent runs the same skill twice in autopilot](#the-agent-runs-the-same-skill-twice-in-autopilot)
- [The telemetry opt-in prompt never appears on a fresh install](#the-telemetry-opt-in-prompt-never-appears-on-a-fresh-install)

---

## Slash commands do not appear in my agent

You ran `setup` (or `npx create-nanostack`) and the script printed `nanostack ready`, but typing `/think` or `/nano-help` does not work.

**1. Did you restart your agent after install?**

| Agent | Action |
|-------|--------|
| Claude Code | Ready immediately. No restart needed. |
| Cursor | Close and reopen Cursor. |
| Codex | Run `codex` in a new terminal. |
| OpenCode | Restart your OpenCode session. |
| Gemini CLI | Run `gemini` in a new terminal. |

**2. Did the install actually finish?**

```bash
cat ~/.nanostack/setup.json
```

You should see your agent in the `agents` array. If the file does not exist, the install did not complete. Re-run setup.

**3. Are the skill files where the agent expects them?**

```bash
# Claude Code
ls ~/.claude/skills/

# Codex / OpenCode
ls ~/.agents/skills/

# Cursor
ls .cursor/rules/
```

If the directory is empty or `nanostack` is missing, re-run setup.

**4. Skill name conflict?**

If you have other skill sets installed (gstack, superpowers, etc.), names may collide. See [Skill name conflicts](#skill-name-conflicts-with-another-set-gstack-superpowers) below.

---

## Command not found: jq

`jq` is required by most nanostack scripts. Without it you will see:

```
ERROR: nanostack requires the following commands but they were not found: jq
```

**Install:**

| Platform | Command |
|----------|---------|
| macOS | `brew install jq` |
| Debian / Ubuntu | `sudo apt install jq` |
| RHEL / Fedora | `sudo dnf install jq` |
| Arch | `sudo pacman -S jq` |
| Windows (Git Bash) | `choco install jq` (run as admin) |

**After install, verify:**

```bash
jq --version
```

If the version prints but nanostack scripts still report jq missing, your shell is finding a different PATH than nanostack's scripts. Try:

```bash
which jq
```

If the path is unusual (e.g., `/opt/homebrew/bin/jq` on macOS but your scripts use `/usr/local/bin`), open a new terminal so the new PATH is loaded.

**Bypass for offline test environments only:**

```bash
NANOSTACK_SKIP_PREFLIGHT=1 ./your-command
```

Skipping is not recommended in normal use. Scripts will fail later in less obvious ways.

---

## The phase gate blocked my git commit

You tried to `git commit` and saw:

```
BLOCKED [PHASE-GATE] Sprint phases incomplete: review, security, qa
```

**Why:** when a sprint is active in this project, nanostack blocks commits until `/review`, `/security`, and `/qa` have been run with fresh artifacts. This prevents shipping unreviewed code by accident.

**Resolve:** complete the missing phases:

```
/review
/security
/qa
```

After each one finishes successfully, retry your commit.

**Bypass for non-sprint commits:**

If this commit is unrelated to the active sprint (e.g., fixing a typo in unrelated docs), bypass the gate:

```bash
NANOSTACK_SKIP_GATE=1 git commit -m "your message"
```

Use sparingly. The gate exists for a reason.

**End the sprint entirely** if it was abandoned:

```bash
~/.claude/skills/nanostack/bin/session.sh archive
```

---

## /qa says the port is in use

`/qa` browser tests need to start a local server. If the port is taken:

```
Error: listen EADDRINUSE: address already in use :::3000
```

**Find what is using the port:**

```bash
lsof -ti:3000
```

This prints the PID. Confirm it is something you can stop (a leftover dev server, not your production proxy).

**Stop it:**

```bash
kill $(lsof -ti:3000)
```

**Or use a different port** for /qa by setting the env var your project uses (`PORT=3001 npm start`, etc.) before invoking /qa.

---

## I am on Windows

nanostack is shell-based and needs a POSIX environment.

**Recommended:** install [Git for Windows](https://git-scm.com/downloads/win). It includes Git Bash, which Claude Code and most other agents use internally for shell commands. With Git Bash, the setup script and all `bin/*.sh` scripts work without changes.

**Alternative:** WSL (Windows Subsystem for Linux). Install your favorite distro from the Microsoft Store, then install nanostack inside WSL.

**Cannot use either?** Use the npm install path:

```bash
npx create-nanostack
```

This handles install via Node and avoids most shell-specific issues. You will lose access to a few advanced bin scripts that require bash directly, but the core sprint flow (`/think` through `/ship`) works.

---

## I started a sprint and got stuck halfway

A `/think` or `/nano` ran, but you closed the terminal or the agent crashed before finishing.

**Resume from where you left off:**

```bash
~/.claude/skills/nanostack/bin/session.sh resume
```

This prints the last session state. If the session can be resumed, the agent picks up from the last completed phase.

**Discard the bad sprint** and start fresh:

```bash
~/.claude/skills/nanostack/bin/discard-sprint.sh             # discard today
~/.claude/skills/nanostack/bin/discard-sprint.sh --dry-run   # preview first
```

**Archive the current session** without discarding artifacts:

```bash
~/.claude/skills/nanostack/bin/session.sh archive
```

The session moves to `.nanostack/sessions/` and a fresh session can start.

---

## Skill name conflicts with another set (gstack, superpowers)

Both nanostack and gstack ship a `/review`, `/security`, etc. The agent loads whichever it finds first.

**See current names:**

```bash
~/.claude/skills/nanostack/setup --list
```

**Rename the conflicting nanostack skills:**

```bash
~/.claude/skills/nanostack/setup --rename "review=nano-review,security=nano-security"
```

Renames persist between updates. Restore originals with `--rename reset`.

The gstack/superpowers commands are not modified. Only nanostack's are renamed.

---

## Cannot install or upgrade behind a corporate proxy

`npx create-nanostack` or `git clone` fails to reach GitHub or npm.

**1. Check your proxy is set:**

```bash
echo $HTTPS_PROXY $HTTP_PROXY
```

If empty, set them per your IT policy.

**2. Configure git** (one time):

```bash
git config --global http.proxy http://proxy.example.com:8080
git config --global https.proxy http://proxy.example.com:8080
```

**3. Configure npm** (for `npx create-nanostack`):

```bash
npm config set proxy http://proxy.example.com:8080
npm config set https-proxy http://proxy.example.com:8080
```

**4. Last resort:** download the release tarball from https://github.com/garagon/nanostack/releases on a machine with internet, transfer it, extract to `~/.claude/skills/nanostack`, then run `./setup`.

---

## The agent runs the same skill twice in autopilot

Autopilot ran `/review`, then ran `/review` again. This usually means the first run did not save its artifact.

**Check what the sprint thinks happened:**

```bash
~/.claude/skills/nanostack/bin/session.sh status
```

If a phase shows `in_progress` but you saw it report success, the artifact save was probably skipped. Check the audit log:

```bash
tail -20 .nanostack/audit.log
```

Look for `phase_complete` events. If the second-to-last review has no `phase_complete`, the agent forgot to call `save-artifact.sh`. Re-run the phase manually:

```bash
~/.claude/skills/nanostack/bin/save-artifact.sh --from-session review 'manual save: <summary>'
```

Then continue the sprint.

If this keeps happening across sprints, file an issue with the audit log excerpt. It is a bug in the skill, not in your project.

---

## The telemetry opt-in prompt never appears on a fresh install

You installed nanostack and ran `/think` on a fresh machine, but the opt-in prompt (community / anonymous / off) never showed up. You want to know which branch of the detection logic fired.

Set `NANOSTACK_DEBUG=1` and run any skill. One line is printed to stderr explaining which decision was taken and why.

```sh
NANOSTACK_DEBUG=1 /think "test"
# [telemetry:prompt] skip=0 reason=fresh-install caller-should-prompt=yes
# or
# [telemetry:prompt] skip=1 reason=marker-present path=~/.nanostack/.telemetry-prompted
# or
# [telemetry:prompt] skip=1 reason=pre-v5 home=~/.nanostack
```

Three possible outcomes:

- `skip=0 reason=fresh-install`: detection worked, the prompt should appear on the next skill run. If it still does not, check that the skill you ran actually calls the prompt (today only `/think` does).
- `skip=1 reason=marker-present`: the marker file `~/.nanostack/.telemetry-prompted` already exists, so you were prompted in a prior run. Delete the marker and re-run if you want to see the prompt again.
- `skip=1 reason=pre-v5`: detection thinks you had a nanostack install from before April 2026. Contents of `~/.nanostack/` include at least one entry whose mtime predates the V5 merge. Confirm by running `ls -la ~/.nanostack/` and checking dates. If the classification is wrong (files were touched by a backup or restore that reset mtimes), delete the marker and re-run.

The debug flag never sends anything over the network, and it is silent by default. Your production installs stay quiet.

---

## Still stuck?

- Search existing issues: https://github.com/garagon/nanostack/issues
- Open a new issue with: your agent (Claude Code, Cursor, etc.), your OS, the exact command you ran, the full output, and what you expected to happen.
- For security vulnerabilities, see [SECURITY.md](SECURITY.md) instead.
