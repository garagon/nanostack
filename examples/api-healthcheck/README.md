# API Healthcheck

A minimal HTTP server with one endpoint. One file (`server.js`), zero dependencies, no build step. The point is not the server. It is having a real HTTP surface to run a full nanostack sprint on without touching any backend that matters.

## Who this is for

A backend developer comfortable with Node and curl. You can read `http.createServer`, you understand status codes, and you want to feel how nanostack handles an API feature ask on a server you can run in one command.

## What you start with

A working server with one endpoint:

| Method | Path | Response |
|---|---|---|
| `GET` | `/health` | `200` with `{"status":"ok","ts":"...","started_at":"..."}` |
| `GET` | anything else | `404` with `{"error":"not_found"}` |
| any other method | any path | `405` with `{"error":"method_not_allowed"}` |

Storage: none. State: only `STARTED_AT` (the time the process began). The server uses Node's stdlib `http` module and gracefully shuts down on `SIGINT` / `SIGTERM`.

What it does NOT do yet (these are the seeds for your first sprint):

- No `/version` endpoint reporting the current build.
- No request log: there is no record of who hit which endpoint when.
- No readiness probe (`/readyz`) separate from liveness (`/health`).

## First sprint

```bash
git clone https://github.com/garagon/nanostack
cd nanostack/examples/api-healthcheck
```

Verify the starting state works on its own:

```bash
node server.js &
SRV_PID=$!
sleep 1
curl -s http://localhost:3000/health
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/missing
kill "$SRV_PID"
```

You should see a JSON body for `/health` and `404` for the unknown path.

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

**Easiest. Add a `/version` endpoint.**

```
/feature Add a GET /version endpoint that returns {"version":"0.1.0","name":"api-healthcheck"} as JSON. Source the version from a constant near the top of server.js for now. Wrong methods should still return 405.
```

**Medium. Add a request log.**

```
/feature Log every request to stdout as one line per request: ISO timestamp, method, path, status, duration in milliseconds. Format is up to you, but it must be single-line and grep-friendly. Do not write to disk or add a dependency.
```

**Higher pushback. Separate readiness from liveness.**

```
/think I want a /readyz endpoint that returns 503 until the server has been up for some time, and 200 after. The point is to model a slow-starting service. Push back on what "some time" should be (env var? hardcoded? based on a real signal?). Find the smallest version that does not lie to a real load balancer.
```

The third one is interesting: there is no obvious correct answer, and a naive "wait 5 seconds" will draw a real critique from `/think`.

## Expected Nanostack flow

In about 10 to 15 minutes you should see:

1. `/think` (or `/feature`'s implicit think) names the smallest version. For the request-log feature it should ask whether structured (JSON) or plain text is required, and what happens for bodies that are too large to log.
2. `/nano` writes a plan that lists every file it will touch. For all three feature ideas this should be exactly one file (`server.js`).
3. The agent edits `server.js`. No new files, no `package.json` (this example is intentionally dependency-free).
4. `/review` reports on the diff. Look for a one-line summary plus auto-fixes (formatting, missing `Content-Type`, status-code consistency).
5. `/security` rates the change. With no auth surface and no user input parsing it should land near A. The request-log feature is the one most likely to draw a finding (be careful what you log: do not log full request bodies or auth headers).
6. `/qa` actually starts the server, hits the new endpoint with `curl`, and confirms the new behavior works AND the existing `/health` and 404/405 paths still pass.
7. `/ship` closes the sprint.

The exact level of automatic blocking depends on your agent. On Claude Code, hooks can stop unsafe actions before they execute. On Cursor, Codex, OpenCode, and Gemini, nanostack runs as guided instructions the agent reads and follows.

## Success criteria

You succeeded if all of these are true after the sprint:

- The new endpoint responds as the plan said it would.
- `GET /health` still returns `200` with the original JSON shape.
- Unknown paths still return `404`. Wrong methods still return `405`.
- `node --check server.js` passes (no syntax regression).
- The plan named every file it touched. There is exactly one (`server.js`).
- The server still shuts down cleanly on Ctrl-C.
- Nothing outside `examples/api-healthcheck/` was touched.
- You can describe the change to a teammate using the agent's review summary, without rereading the diff.

If any of these is false, the example or the install needs attention. Run `/nano-doctor` and check TROUBLESHOOTING.

## What this teaches

- How `/think` reframes a vague API ask ("add a version endpoint") into questions about source of truth (env var, hardcoded, package.json).
- How `/nano` constrains scope to one file and refuses to silently introduce a build step or a dependency.
- How `/review` catches API-specific edge cases: missing `Content-Type`, status-code consistency, behavior when the body is empty, behavior under wrong methods.
- How `/security` treats request logging as a real risk surface (logs can leak headers, tokens, full URLs) and asks what gets redacted.
- How `/qa` exercises an HTTP server with real `curl` calls and verifies behavior, not just code shape.
- How nanostack stays inside this directory and never silently rewrites your shell config, your `~/.npmrc`, or any sibling project.

## Reset

To go back to the starting state without any sprint records:

```bash
rm -rf .nanostack/
git checkout -- server.js
```

Each command is scoped to this directory:

- `rm -rf .nanostack/` removes only the sprint records this example produced.
- `git checkout -- server.js` restores the script to the version in this repo.

There is nothing destructive to your wider machine in either step. If a server is still running from an earlier session, find and stop it explicitly:

```bash
lsof -i :3000          # find the PID listening on the port
kill <pid>             # stop it
```

If you want to fully forget this example, delete `examples/api-healthcheck/`. It is not a dependency of nanostack itself.

For setup or environment trouble, see [`../../TROUBLESHOOTING.md`](../../TROUBLESHOOTING.md).
